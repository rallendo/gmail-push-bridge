import Foundation
import Network

enum IMAPClientEvent: Sendable {
    case stateChanged(IMAPConnectionState)
    case inboxCountUpdated(Int)
    case newMailDetected(existsCount: Int)
    case log(String)
}

enum IMAPConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case authenticating
    case selectingMailbox(String)
    case idling(mailbox: String, existsCount: Int)
    case reconnecting(attempt: Int, delaySeconds: Int)
    case authFailed(String)
    case error(String)

    var summaryText: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting to Gmail IMAP…"
        case .authenticating:
            return "Authenticating…"
        case .selectingMailbox(let box):
            return "Selecting \(box)…"
        case .idling(let box, let count):
            return "Connected • IDLE on \(box) (\(count) msgs)"
        case .reconnecting(let attempt, let delay):
            return "Reconnecting (#\(attempt) in \(delay)s)…"
        case .authFailed(let reason):
            return "Auth Failed: \(reason)"
        case .error(let reason):
            return "Error: \(reason)"
        }
    }

    var isIdling: Bool {
        if case .idling = self { return true }
        return false
    }
}

struct IMAPConfiguration: Sendable {
    let host: String
    let port: UInt16
    let email: String
    let appPassword: String
    let mailbox: String
    let idleRenewalMinutes: Int
}

final class IMAPIdleClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.gmailpushbridge.imap", qos: .utility)
    private let eventHandler: @Sendable (IMAPClientEvent) -> Void

    private enum ProtocolStep {
        case idle
        case awaitingGreeting
        case loggingIn(tag: String)
        case selecting(tag: String)
        case enteringIdle(tag: String)
        case idling(tag: String)
        case exitingIdle(tag: String)
    }

    private var config: IMAPConfiguration?
    private var connection: NWConnection?
    private var step: ProtocolStep = .idle
    private var receiveBuffer = Data()
    private var tagCounter: Int = 0
    private var knownExistsCount: Int?
    private var reconnectAttempt: Int = 0
    private var isStopped: Bool = true

    private var idleRenewalTimer: DispatchSourceTimer?
    private var commandWatchdogTimer: DispatchSourceTimer?
    private var reconnectWorkItem: DispatchWorkItem?

    init(eventHandler: @escaping @Sendable (IMAPClientEvent) -> Void) {
        self.eventHandler = eventHandler
    }

    func start(with configuration: IMAPConfiguration) {
        queue.async { [weak self] in
            guard let self else { return }
            self.config = configuration
            self.isStopped = false
            self.reconnectAttempt = 0
            self.connectInternal()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStopped = true
            self.cancelTimers()
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.teardownConnection()
            self.eventHandler(.stateChanged(.disconnected))
        }
    }

    /// Forces an immediate teardown and fresh connection (used after Mac wake or network switch).
    func forceReconnect(reason: String) {
        queue.async { [weak self] in
            guard let self, !self.isStopped, self.config != nil else { return }
            self.eventHandler(.log("Reconnecting IMAP session (\(reason))"))
            self.cancelTimers()
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.reconnectAttempt = 0
            self.teardownConnection()
            self.connectInternal()
        }
    }

    // MARK: - Internal Connection Management

    private func connectInternal() {
        guard !isStopped, let config else { return }

        cancelTimers()
        teardownConnection()
        receiveBuffer.removeAll(keepingCapacity: false)
        step = .awaitingGreeting

        eventHandler(.stateChanged(.connecting))
        eventHandler(.log("Opening TLS connection to \(config.host):\(config.port)…"))

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 60
        tcpOptions.keepaliveInterval = 15
        tcpOptions.keepaliveCount = 3
        tcpOptions.connectionTimeout = 15

        let tlsOptions = NWProtocolTLS.Options()
        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)

        guard let port = NWEndpoint.Port(rawValue: config.port) else {
            eventHandler(.stateChanged(.error("Invalid port \(config.port)")))
            return
        }

        let conn = NWConnection(host: NWEndpoint.Host(config.host), port: port, using: parameters)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.handleConnectionState(state)
        }

        startWatchdog(seconds: 20, description: "TLS connection & IMAP greeting")
        conn.start(queue: queue)
        receiveLoop(on: conn)
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        guard !isStopped else { return }
        switch state {
        case .ready:
            eventHandler(.log("TLS handshake complete; waiting for server greeting."))
        case .waiting(let error):
            eventHandler(.log("Network waiting: \(error.localizedDescription)"))
            scheduleReconnect(reason: "Network waiting (\(error.localizedDescription))")
        case .failed(let error):
            eventHandler(.log("Connection failed: \(error.localizedDescription)"))
            scheduleReconnect(reason: error.localizedDescription)
        case .cancelled:
            break
        default:
            break
        }
    }

    private func receiveLoop(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard conn === self.connection, !self.isStopped else { return }

            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.processBufferedLines()
            }

            if let error {
                self.eventHandler(.log("Socket receive error: \(error.localizedDescription)"))
                self.scheduleReconnect(reason: error.localizedDescription)
                return
            }

            if isComplete {
                self.eventHandler(.log("Server closed the IMAP connection."))
                self.scheduleReconnect(reason: "Server closed connection")
                return
            }

            self.receiveLoop(on: conn)
        }
    }

    private func processBufferedLines() {
        let newline = UInt8(ascii: "\n")
        while let newlineIndex = receiveBuffer.firstIndex(of: newline) {
            let lineData = receiveBuffer.subdata(in: 0..<newlineIndex)
            receiveBuffer.removeSubrange(0...newlineIndex)

            if let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r\n")) {
                if !line.isEmpty {
                    handleServerLine(line)
                }
            }
        }
    }

    // MARK: - IMAP State Machine

    private func handleServerLine(_ line: String) {
        guard let config else { return }

        // Always inspect untagged EXISTS / EXPUNGE lines in any state after SELECT
        if let exists = Self.parseUntaggedNumber(line: line, keyword: "EXISTS") {
            let previous = knownExistsCount
            knownExistsCount = exists
            eventHandler(.inboxCountUpdated(exists))

            if case .idling(let tag) = step {
                _ = tag
                eventHandler(.stateChanged(.idling(mailbox: config.mailbox, existsCount: exists)))
                if let previous, exists > previous {
                    eventHandler(.log("Gmail reported * \(exists) EXISTS (was \(previous)) -> New mail arrived!"))
                    eventHandler(.newMailDetected(existsCount: exists))
                } else if previous == nil {
                    eventHandler(.newMailDetected(existsCount: exists))
                }
            } else if let previous, exists > previous {
                // New mail arrived between IDLE cycles or during reconnect SELECT
                eventHandler(.log("Mailbox count grew to \(exists) (was \(previous)) during sync -> triggering fetch."))
                eventHandler(.newMailDetected(existsCount: exists))
            }
            return
        }

        if Self.parseUntaggedNumber(line: line, keyword: "EXPUNGE") != nil {
            if let current = knownExistsCount, current > 0 {
                let updated = current - 1
                knownExistsCount = updated
                eventHandler(.inboxCountUpdated(updated))
                if case .idling = step {
                    eventHandler(.stateChanged(.idling(mailbox: config.mailbox, existsCount: updated)))
                }
            }
            return
        }

        switch step {
        case .idle:
            break

        case .awaitingGreeting:
            if line.hasPrefix("* OK") {
                cancelWatchdog()
                let tag = nextTag()
                step = .loggingIn(tag: tag)
                eventHandler(.stateChanged(.authenticating))
                let escapedUser = Self.escapeIMAPQuoted(config.email)
                let escapedPass = Self.escapeIMAPQuoted(config.appPassword)
                startWatchdog(seconds: 15, description: "LOGIN response")
                sendRaw("\(tag) LOGIN \"\(escapedUser)\" \"\(escapedPass)\"\r\n", redactLogAs: "\(tag) LOGIN \"\(escapedUser)\" <redacted>")
            } else if line.hasPrefix("* BYE") {
                scheduleReconnect(reason: "Server sent BYE on greeting")
            }

        case .loggingIn(let tag):
            if line.hasPrefix("\(tag) OK") {
                cancelWatchdog()
                reconnectAttempt = 0
                let selectTag = nextTag()
                step = .selecting(tag: selectTag)
                eventHandler(.stateChanged(.selectingMailbox(config.mailbox)))
                let escapedMailbox = Self.escapeIMAPQuoted(config.mailbox)
                startWatchdog(seconds: 15, description: "SELECT \(config.mailbox)")
                sendRaw("\(selectTag) SELECT \"\(escapedMailbox)\"\r\n")
            } else if line.hasPrefix("\(tag) NO") || line.hasPrefix("\(tag) BAD") {
                cancelWatchdog()
                teardownConnection()
                isStopped = true
                let detail = "Check Gmail address & 16-char App Password (\(line))"
                eventHandler(.log("Authentication rejected: \(line)"))
                eventHandler(.stateChanged(.authFailed(detail)))
            }

        case .selecting(let tag):
            if line.hasPrefix("\(tag) OK") {
                cancelWatchdog()
                enterIdle()
            } else if line.hasPrefix("\(tag) NO") || line.hasPrefix("\(tag) BAD") {
                cancelWatchdog()
                eventHandler(.log("Failed to select mailbox '\(config.mailbox)': \(line)"))
                scheduleReconnect(reason: "SELECT failed: \(line)")
            }

        case .enteringIdle(let tag):
            if line.hasPrefix("+") {
                cancelWatchdog()
                step = .idling(tag: tag)
                let count = knownExistsCount ?? 0
                eventHandler(.stateChanged(.idling(mailbox: config.mailbox, existsCount: count)))
                eventHandler(.log("Entered IMAP IDLE on \(config.mailbox) (\(count) messages). Waiting for instant push…"))
                scheduleIdleRenewal(minutes: config.idleRenewalMinutes)
            } else if line.hasPrefix("\(tag) NO") || line.hasPrefix("\(tag) BAD") {
                cancelWatchdog()
                scheduleReconnect(reason: "IDLE rejected: \(line)")
            }

        case .idling:
            if line.hasPrefix("* BYE") {
                eventHandler(.log("Server sent BYE while idling: \(line)"))
                scheduleReconnect(reason: "Server sent BYE")
            }

        case .exitingIdle(let tag):
            if line.hasPrefix("\(tag) OK") {
                cancelWatchdog()
                enterIdle()
            } else if line.hasPrefix("\(tag) NO") || line.hasPrefix("\(tag) BAD") || line.hasPrefix("* BYE") {
                cancelWatchdog()
                scheduleReconnect(reason: "Error exiting IDLE: \(line)")
            }
        }
    }

    private func enterIdle() {
        let idleTag = nextTag()
        step = .enteringIdle(tag: idleTag)
        startWatchdog(seconds: 15, description: "IDLE continuation (+)")
        sendRaw("\(idleTag) IDLE\r\n")
    }

    private func renewIdle() {
        guard case .idling(let tag) = step else { return }
        step = .exitingIdle(tag: tag)
        eventHandler(.log("Refreshing IMAP IDLE session (sending DONE)…"))
        startWatchdog(seconds: 12, description: "DONE acknowledgement")
        sendRaw("DONE\r\n")
    }

    // MARK: - Helpers & Timers

    private func sendRaw(_ command: String, redactLogAs redacted: String? = nil) {
        guard let connection else { return }
        let data = Data(command.utf8)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.eventHandler(.log("Send error: \(error.localizedDescription)"))
                self.scheduleReconnect(reason: "Send error: \(error.localizedDescription)")
            } else if let redacted {
                self.eventHandler(.log("-> \(redacted)"))
            }
        })
    }

    private func scheduleIdleRenewal(minutes: Int) {
        idleRenewalTimer?.cancel()
        let clampedMinutes = max(2, min(minutes, 25))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(clampedMinutes * 60))
        timer.setEventHandler { [weak self] in
            self?.renewIdle()
        }
        idleRenewalTimer = timer
        timer.resume()
    }

    private func startWatchdog(seconds: Int, description: String) {
        commandWatchdogTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(seconds))
        timer.setEventHandler { [weak self] in
            guard let self, !self.isStopped else { return }
            self.eventHandler(.log("Timed out waiting for \(description) (\(seconds)s)."))
            self.scheduleReconnect(reason: "Timeout waiting for \(description)")
        }
        commandWatchdogTimer = timer
        timer.resume()
    }

    private func cancelWatchdog() {
        commandWatchdogTimer?.cancel()
        commandWatchdogTimer = nil
    }

    private func cancelTimers() {
        idleRenewalTimer?.cancel()
        idleRenewalTimer = nil
        cancelWatchdog()
    }

    private func teardownConnection() {
        step = .idle
        if let conn = connection {
            conn.stateUpdateHandler = nil
            conn.cancel()
            connection = nil
        }
    }

    private func scheduleReconnect(reason: String) {
        guard !isStopped else { return }
        cancelTimers()
        teardownConnection()
        reconnectWorkItem?.cancel()

        reconnectAttempt += 1
        // Exponential backoff capped at 30 seconds: 2s, 4s, 8s, 16s, 30s
        let delay = min(30, Int(pow(2.0, Double(min(reconnectAttempt, 5)))))
        eventHandler(.stateChanged(.reconnecting(attempt: reconnectAttempt, delaySeconds: delay)))
        eventHandler(.log("Scheduling reconnect #\(reconnectAttempt) in \(delay)s (\(reason))"))

        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped else { return }
            self.connectInternal()
        }
        reconnectWorkItem = item
        queue.asyncAfter(deadline: .now() + .seconds(delay), execute: item)
    }

    private func nextTag() -> String {
        tagCounter = (tagCounter % 9999) + 1
        return String(format: "A%04d", tagCounter)
    }

    /// Parses lines like `* 1420 EXISTS` or `* 5 EXPUNGE`.
    private static func parseUntaggedNumber(line: String, keyword: String) -> Int? {
        guard line.hasPrefix("* ") else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 3,
              parts[0] == "*",
              parts[2].uppercased() == keyword,
              let number = Int(parts[1]) else {
            return nil
        }
        return number
    }

    private static func escapeIMAPQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
