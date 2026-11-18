import Foundation
import Network
import Security

enum IMAPClientEvent: Sendable {
    case stateChanged(IMAPConnectionState)
    case inboxCountUpdated(Int)
    case newMailDetected(existsCount: Int)
    case mailboxSyncDetected(reason: String)
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

enum IMAPCredentialMode: Sendable {
    case appPassword(String)
    case xoauth2(tokenProvider: @Sendable () async throws -> String)
}

struct IMAPConfiguration: Sendable {
    let host: String
    let port: UInt16
    let email: String
    let credentialMode: IMAPCredentialMode
    let mailbox: String
    let idleRenewalMinutes: Int
}

final class IMAPIdleClient: @unchecked Sendable {
    nonisolated static let maxReceiveBufferBytes = 65_536

    private let queue = DispatchQueue(label: "com.gmailpushbridge.imap", qos: .utility)
    private let eventHandler: @Sendable (IMAPClientEvent) -> Void

    private enum ProtocolStep {
        case idle
        case awaitingGreeting
        case preparingOAuth
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
    private(set) var sentCommandsForTesting: [String] = []

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

    /// Updates the IDLE renewal interval dynamically without tearing down the active connection.
    func updateIdleRenewalMinutes(_ minutes: Int) {
        queue.async { [weak self] in
            guard let self, let current = self.config else { return }
            self.config = IMAPConfiguration(
                host: current.host,
                port: current.port,
                email: current.email,
                credentialMode: current.credentialMode,
                mailbox: current.mailbox,
                idleRenewalMinutes: minutes
            )
            if case .idling = self.step {
                self.scheduleIdleRenewal(minutes: minutes)
            }
        }
    }

    func configureForTesting(_ configuration: IMAPConfiguration) {
        cancelTimers()
        teardownConnection()
        config = configuration
        isStopped = false
        step = .awaitingGreeting
        receiveBuffer.removeAll(keepingCapacity: false)
        tagCounter = 0
        knownExistsCount = nil
        reconnectAttempt = 0
        sentCommandsForTesting.removeAll()
    }

    func receiveRawDataForTesting(_ data: Data) {
        receiveBuffer.append(data)
        processBufferedLines()
    }

    func triggerIdleRenewalForTesting() {
        renewIdle()
    }

    // MARK: - Internal Connection Management

    private func connectInternal() {
        guard !isStopped, let config else { return }

        guard AppSettings.isAllowedGmailIMAPEndpoint(host: config.host, port: config.port) else {
            isStopped = true
            eventHandler(.log("Blocked connection to untrusted IMAP endpoint \(config.host):\(config.port)"))
            eventHandler(.stateChanged(.authFailed("Untrusted IMAP host: \(config.host):\(config.port)")))
            return
        }

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
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions,
            .TLSv12
        )
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
                if self.receiveBuffer.count + data.count > Self.maxReceiveBufferBytes {
                    self.receiveBuffer.removeAll(keepingCapacity: false)
                    self.eventHandler(.log("IMAP receive buffer exceeded \(Self.maxReceiveBufferBytes) bytes; disconnecting."))
                    self.scheduleReconnect(reason: "IMAP response line exceeded maximum buffer size")
                    return
                }
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

        // Always inspect untagged EXISTS / EXPUNGE / FETCH (FLAGS) lines in any state after SELECT
        if let exists = Self.parseUntaggedNumber(line: line, keyword: "EXISTS") {
            let previous = knownExistsCount
            knownExistsCount = exists
            eventHandler(.inboxCountUpdated(exists))

            if case .idling = step {
                eventHandler(.stateChanged(.idling(mailbox: config.mailbox, existsCount: exists)))
                if let previous, exists > previous {
                    eventHandler(.log("Gmail reported * \(exists) EXISTS (was \(previous)) -> New mail arrived!"))
                    eventHandler(.newMailDetected(existsCount: exists))
                } else if let previous, exists < previous {
                    eventHandler(.log("Gmail reported * \(exists) EXISTS (was \(previous)) -> Messages removed from \(config.mailbox)."))
                    eventHandler(.mailboxSyncDetected(reason: "Gmail IDLE (* \(exists) EXISTS, was \(previous))"))
                } else if previous == nil {
                    eventHandler(.newMailDetected(existsCount: exists))
                }
            } else if let previous, exists > previous {
                // New mail arrived between IDLE cycles or during reconnect SELECT
                eventHandler(.log("Mailbox count grew to \(exists) (was \(previous)) during sync -> triggering fetch."))
                eventHandler(.newMailDetected(existsCount: exists))
            } else if let previous, exists < previous {
                eventHandler(.log("Mailbox count decreased to \(exists) (was \(previous)) during sync -> triggering sync."))
                eventHandler(.mailboxSyncDetected(reason: "Gmail sync (* \(exists) EXISTS, was \(previous))"))
            }
            return
        }

        if let expungedSeq = Self.parseUntaggedNumber(line: line, keyword: "EXPUNGE") {
            if let current = knownExistsCount, current > 0 {
                let updated = current - 1
                knownExistsCount = updated
                eventHandler(.inboxCountUpdated(updated))
                if case .idling = step {
                    eventHandler(.stateChanged(.idling(mailbox: config.mailbox, existsCount: updated)))
                }
            }
            if case .idling = step {
                eventHandler(.log("Gmail reported * \(expungedSeq) EXPUNGE (\(knownExistsCount ?? 0) remaining) -> Message archived/removed."))
                eventHandler(.mailboxSyncDetected(reason: "Gmail IDLE (* \(expungedSeq) EXPUNGE)"))
            } else if case .exitingIdle = step {
                eventHandler(.log("Gmail reported * \(expungedSeq) EXPUNGE during IDLE refresh -> Message archived/removed."))
                eventHandler(.mailboxSyncDetected(reason: "Gmail IDLE (* \(expungedSeq) EXPUNGE)"))
            }
            return
        }

        if let flagSummary = Self.parseUntaggedFetchFlags(line: line) {
            if case .idling = step {
                eventHandler(.log("Gmail reported flag change (\(flagSummary)) -> triggering sync."))
                eventHandler(.mailboxSyncDetected(reason: "Gmail IDLE (\(flagSummary))"))
            } else if case .exitingIdle = step {
                eventHandler(.log("Gmail reported flag change during IDLE refresh (\(flagSummary)) -> triggering sync."))
                eventHandler(.mailboxSyncDetected(reason: "Gmail IDLE (\(flagSummary))"))
            }
            return
        }

        switch step {
        case .idle, .preparingOAuth:
            break

        case .awaitingGreeting:
            if line.hasPrefix("* OK") {
                cancelWatchdog()
                beginAuthentication(using: config)
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
            } else if line.hasPrefix("+ ") || line == "+" {
                // Gmail XOAUTH2 sends `+ <base64_error_json>` before `<tag> NO` when a token is rejected;
                // RFC / Google XOAUTH2 requires sending an empty `\r\n` to complete the failed SASL exchange.
                sendRaw("\r\n")
            } else if line.hasPrefix("\(tag) NO") || line.hasPrefix("\(tag) BAD") {
                cancelWatchdog()
                teardownConnection()
                isStopped = true
                let detail = "Authentication rejected (\(line))"
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

    private func beginAuthentication(using config: IMAPConfiguration) {
        eventHandler(.stateChanged(.authenticating))
        switch config.credentialMode {
        case .appPassword(let password):
            let tag = nextTag()
            step = .loggingIn(tag: tag)
            let escapedUser = Self.escapeIMAPQuoted(config.email)
            let escapedPass = Self.escapeIMAPQuoted(password)
            startWatchdog(seconds: 15, description: "LOGIN response")
            sendRaw("\(tag) LOGIN \"\(escapedUser)\" \"\(escapedPass)\"\r\n", redactLogAs: "\(tag) LOGIN \"\(escapedUser)\" <redacted>")

        case .xoauth2(let tokenProvider):
            step = .preparingOAuth
            startWatchdog(seconds: 20, description: "OAuth2 token refresh & XOAUTH2 login")
            Task { [weak self] in
                guard let self else { return }
                do {
                    let accessToken = try await tokenProvider()
                    self.queue.async { [weak self] in
                        guard let self, !self.isStopped, case .preparingOAuth = self.step else { return }
                        let tag = self.nextTag()
                        self.step = .loggingIn(tag: tag)
                        let sasl = GoogleOAuthManager.buildXOAuth2SASL(email: config.email, accessToken: accessToken)
                        self.startWatchdog(seconds: 15, description: "AUTHENTICATE XOAUTH2 response")
                        self.sendRaw(
                            "\(tag) AUTHENTICATE XOAUTH2 \(sasl)\r\n",
                            redactLogAs: "\(tag) AUTHENTICATE XOAUTH2 <oauth2-token-for-\(config.email)>"
                        )
                    }
                } catch {
                    self.queue.async { [weak self] in
                        guard let self, !self.isStopped else { return }
                        self.cancelWatchdog()
                        self.teardownConnection()
                        self.isStopped = true
                        self.eventHandler(.log("OAuth2 token error: \(error.localizedDescription)"))
                        self.eventHandler(.stateChanged(.authFailed(error.localizedDescription)))
                    }
                }
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
        sentCommandsForTesting.append(command)
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

    nonisolated static func parseUntaggedNumber(line: String, keyword: String) -> Int? {
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

    private nonisolated static let canonicalSystemFlags: [String: String] = [
        "\\seen": "\\Seen",
        "\\answered": "\\Answered",
        "\\flagged": "\\Flagged",
        "\\deleted": "\\Deleted",
        "\\draft": "\\Draft"
    ]

    nonisolated static func parseUntaggedFetchFlags(line: String) -> String? {
        guard line.hasPrefix("* ") else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 4,
              parts[0] == "*",
              let seq = Int(parts[1]),
              parts[2].uppercased() == "FETCH" else {
            return nil
        }

        guard let flagsKeywordRange = line.range(
            of: #"(?:^|[\s(])FLAGS\s*\("#,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return nil
        }

        let afterOpenParen = flagsKeywordRange.upperBound
        guard let closeParenIndex = line[afterOpenParen...].firstIndex(of: ")") else {
            return nil
        }

        let flagsContent = line[afterOpenParen..<closeParenIndex]
        let matchedFlags = flagsContent
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { canonicalSystemFlags[$0.lowercased()] }

        if matchedFlags.isEmpty {
            return "* \(seq) FETCH FLAGS (cleared)"
        }
        return "* \(seq) FETCH FLAGS (\(matchedFlags.joined(separator: " ")))"
    }

    nonisolated static func escapeIMAPQuoted(_ value: String) -> String {
        let sanitized = String(value.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        })
        return sanitized
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
