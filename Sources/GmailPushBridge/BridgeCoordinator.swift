import AppKit
import Foundation

struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let message: String
}

@MainActor
final class BridgeCoordinator: ObservableObject {
    let settings: AppSettings
    let updateManager = UpdateManager.shared

    @Published private(set) var connectionState: IMAPConnectionState = .disconnected
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var isWaitingForMail: Bool = false
    @Published private(set) var isSigningInWithGoogle: Bool = false
    @Published private(set) var lastTriggerDate: Date?
    @Published private(set) var lastTriggerSummary: String = "No push triggered yet"
    @Published private(set) var totalPushesTriggered: Int = 0
    @Published private(set) var detectedMailAccounts: [String] = []
    @Published private(set) var activityLog: [LogEntry] = []

    private static let minReadArchiveDebounceSeconds: Double = 3.0
    private static let syncEchoCooldownSeconds: TimeInterval = 3.0

    private let mailBridge = AppleMailBridge()
    private var imapClient: IMAPIdleClient?
    private var systemMonitor: SystemMonitor?
    private var debounceTask: Task<Void, Never>?
    private var pendingDebounceIsNewMail: Bool = false
    private var pendingDebounceForceSynchronize: Bool = false
    private var isExecutingMailFetch: Bool = false
    private var lastMailFetchCompletedAt: Date?

    init(settings: AppSettings? = nil, enableBackgroundMonitors: Bool = true) {
        self.settings = settings ?? AppSettings()
        guard enableBackgroundMonitors else { return }

        setupClients()
        updateManager.startPeriodicChecks(settings: self.settings)
        if self.settings.isConfigured {
            startMonitoring()
        } else {
            appendLog("Welcome! Sign in with Google (OAuth 2.0 / Passkey) or add an App Password above.")
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard let self else { return }
                SettingsWindowController.shared.show(coordinator: self)
            }
        }
    }

    private func setupClients() {
        imapClient = IMAPIdleClient { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleIMAPEvent(event)
            }
        }

        systemMonitor = SystemMonitor(
            onSystemWake: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, !self.isPaused, !self.isWaitingForMail, self.settings.isConfigured else { return }
                    if self.settings.autoDisconnectWhenMailClosed && !AppleMailBridge.isMailRunning() {
                        self.enterMailClosedStandby(logMessage: "Apple Mail is closed after wake — staying in standby.")
                        return
                    }
                    self.appendLog("Mac woke from sleep — reconnecting IMAP IDLE & checking mail.")
                    self.imapClient?.forceReconnect(reason: "Mac woke from sleep")
                    self.scheduleDebouncedFetch(reason: "Wake from sleep", delayOverride: 3.0)
                }
            },
            onNetworkRestored: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, !self.isPaused, !self.isWaitingForMail, self.settings.isConfigured else { return }
                    if self.settings.autoDisconnectWhenMailClosed && !AppleMailBridge.isMailRunning() {
                        return
                    }
                    self.appendLog("Network path changed/restored — refreshing IMAP IDLE session.")
                    self.imapClient?.forceReconnect(reason: "Network path updated")
                }
            },
            onMailLaunched: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleMailLaunched()
                }
            },
            onMailTerminated: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleMailTerminated()
                }
            }
        )
        systemMonitor?.start()
    }

    func signInWithGoogle(clientSecret: String?) async throws {
        isSigningInWithGoogle = true
        defer { isSigningInWithGoogle = false }

        appendLog("Opening browser for Google OAuth 2.0 sign-in (Passkey / Touch ID supported)…")
        let result = try await GoogleOAuthManager.shared.signInWithBrowser(
            clientId: settings.oauthClientId,
            clientSecret: clientSecret,
            loginHintEmail: settings.gmailAddress
        )
        settings.gmailAddress = result.email
        settings.authMethod = .oauth2
        appendLog("Signed in with Google as \(result.email). OAuth tokens stored in Keychain.")
        startMonitoring()
    }

    func signOutOAuth() {
        let email = settings.gmailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingTokens = email.isEmpty ? nil : KeychainStore.loadOAuthTokens(for: email)

        isWaitingForMail = false
        imapClient?.stop()
        connectionState = .disconnected
        if !email.isEmpty {
            KeychainStore.deleteOAuthTokens(for: email)
        }
        settings.objectWillChange.send()
        appendLog("Removed stored OAuth tokens from Keychain.")

        if let tokens = existingTokens {
            let tokenToRevoke = tokens.refreshToken.isEmpty ? tokens.accessToken : tokens.refreshToken
            Task {
                await GoogleOAuthManager.shared.revokeToken(tokenToRevoke)
            }
        }
    }

    func removeAppPassword() {
        let email = settings.gmailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        isWaitingForMail = false
        imapClient?.stop()
        connectionState = .disconnected
        if !email.isEmpty {
            KeychainStore.deleteAppPassword(for: email)
        }
        settings.objectWillChange.send()
        appendLog("Removed stored App Password from Keychain.")
    }

    func startMonitoring() {
        let email = settings.gmailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else {
            connectionState = .disconnected
            appendLog("Cannot start: Gmail address missing.")
            return
        }

        let credentialMode: IMAPCredentialMode
        switch settings.authMethod {
        case .oauth2:
            guard settings.hasOAuthTokens else {
                connectionState = .disconnected
                appendLog("Click 'Sign in with Google' to authorize IMAP access.")
                return
            }
            credentialMode = .xoauth2 {
                try await GoogleOAuthManager.shared.validAccessToken(for: email)
            }

        case .appPassword:
            guard let appPassword = settings.sanitizedAppPassword() else {
                connectionState = .disconnected
                appendLog("Cannot start: 16-character App Password missing.")
                return
            }
            credentialMode = .appPassword(appPassword)
        }

        isPaused = false
        if settings.autoDisconnectWhenMailClosed && !AppleMailBridge.isMailRunning() {
            enterMailClosedStandby(logMessage: "Waiting for Apple Mail to launch (auto-disconnect when Mail is closed is enabled).")
            return
        }

        isWaitingForMail = false
        let config = IMAPConfiguration(
            host: settings.imapHost,
            port: settings.imapPort,
            email: email,
            credentialMode: credentialMode,
            mailbox: settings.watchedMailbox,
            idleRenewalMinutes: settings.idleRenewalMinutes
        )
        imapClient?.start(with: config)
    }

    func pauseMonitoring() {
        isPaused = true
        isWaitingForMail = false
        cancelPendingDebounce()
        imapClient?.stop()
        appendLog("Monitoring paused by user.")
    }

    func handleAutoDisconnectSettingChanged(_ enabled: Bool) {
        guard settings.isConfigured, !isPaused else {
            if !enabled {
                isWaitingForMail = false
            }
            return
        }

        if enabled && !AppleMailBridge.isMailRunning() {
            if !isWaitingForMail {
                enterMailClosedStandby(logMessage: "Auto-disconnect enabled while Apple Mail is closed — pausing IMAP IDLE.")
            }
        } else if !enabled && isWaitingForMail {
            isWaitingForMail = false
            appendLog("Auto-disconnect disabled — connecting IMAP IDLE now.")
            startMonitoring()
        }
    }

    private func enterMailClosedStandby(logMessage: String) {
        cancelPendingDebounce()
        isWaitingForMail = true
        imapClient?.stop()
        connectionState = .disconnected
        appendLog(logMessage)
    }

    private func cancelPendingDebounce() {
        debounceTask?.cancel()
        debounceTask = nil
        pendingDebounceIsNewMail = false
        pendingDebounceForceSynchronize = false
    }

    private func handleMailTerminated() {
        guard settings.autoDisconnectWhenMailClosed, !isPaused, settings.isConfigured else { return }
        enterMailClosedStandby(logMessage: "Apple Mail quit — pausing IMAP IDLE until Mail launches.")
    }

    private func handleMailLaunched() {
        guard !isPaused, settings.isConfigured else { return }
        if isWaitingForMail || connectionState == .disconnected {
            isWaitingForMail = false
            appendLog("Apple Mail launched — reconnecting IMAP IDLE & checking mail.")
            startMonitoring()
            scheduleDebouncedFetch(reason: "Apple Mail launched", delayOverride: 2.5)
        }
    }

    func togglePause() {
        if isPaused {
            startMonitoring()
        } else {
            pauseMonitoring()
        }
    }

    func reconnectNow() {
        guard settings.isConfigured else {
            appendLog("Configure your Gmail credentials in Settings first.")
            return
        }
        isPaused = false
        startMonitoring()
    }

    func triggerManualFetch() {
        appendLog("Manual Apple Mail fetch requested.")
        Task {
            await executeMailFetch(reason: "Manual trigger")
        }
    }

    func refreshMailAccounts() {
        Task {
            do {
                let accounts = try await mailBridge.fetchAccountNames()
                self.detectedMailAccounts = accounts
                if !accounts.isEmpty {
                    appendLog("Detected Apple Mail accounts: \(accounts.joined(separator: ", "))")
                    if !accounts.contains(settings.appleMailAccountName),
                       let likelyGmail = accounts.first(where: {
                           $0.localizedCaseInsensitiveContains("google") ||
                           $0.localizedCaseInsensitiveContains("gmail") ||
                           $0.localizedCaseInsensitiveContains(settings.gmailAddress)
                       }) {
                        settings.appleMailAccountName = likelyGmail
                    }
                }
            } catch {
                appendLog("Could not list Apple Mail accounts: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Event Handling & Debouncing

    func handleIMAPEvent(_ event: IMAPClientEvent) {
        switch event {
        case .stateChanged(let state):
            self.connectionState = state
        case .inboxCountUpdated:
            break
        case .newMailDetected(let count):
            scheduleDebouncedFetch(
                reason: "Gmail IDLE (* \(count) EXISTS)",
                delayOverride: nil,
                isNewMail: true,
                forceSynchronize: false
            )
        case .mailboxSyncDetected(let reason):
            guard settings.syncReadAndArchiveChanges else { return }
            if isExecutingMailFetch {
                return
            }
            if let lastCompleted = lastMailFetchCompletedAt,
               Date().timeIntervalSince(lastCompleted) < Self.syncEchoCooldownSeconds {
                return
            }
            let minDelay = max(Self.minReadArchiveDebounceSeconds, settings.debounceSeconds)
            scheduleDebouncedFetch(
                reason: reason,
                delayOverride: minDelay,
                isNewMail: false,
                forceSynchronize: true
            )
        case .log(let message):
            appendLog(message)
        }
    }

    private func scheduleDebouncedFetch(
        reason: String,
        delayOverride: Double?,
        isNewMail: Bool = false,
        forceSynchronize: Bool = false
    ) {
        let effectiveIsNewMail = isNewMail || (debounceTask != nil && pendingDebounceIsNewMail)
        let effectiveForceSync = forceSynchronize || (debounceTask != nil && pendingDebounceForceSynchronize)
        debounceTask?.cancel()

        pendingDebounceIsNewMail = effectiveIsNewMail
        pendingDebounceForceSynchronize = effectiveForceSync

        let resolvedDelay: Double
        if effectiveIsNewMail && !isNewMail {
            resolvedDelay = max(0.5, settings.debounceSeconds)
        } else {
            resolvedDelay = max(0.5, delayOverride ?? settings.debounceSeconds)
        }

        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(resolvedDelay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            let shouldForceSync = self.pendingDebounceForceSynchronize
            self.pendingDebounceIsNewMail = false
            self.pendingDebounceForceSynchronize = false
            self.debounceTask = nil
            await self.executeMailFetch(reason: reason, forceSynchronize: shouldForceSync)
        }
    }

    private func executeMailFetch(reason: String, forceSynchronize: Bool = false) async {
        isExecutingMailFetch = true
        defer {
            isExecutingMailFetch = false
            lastMailFetchCompletedAt = Date()
        }

        let result = await mailBridge.triggerFetch(
            accountName: settings.appleMailAccountName,
            fallbackToAllAccounts: settings.checkAllAccountsFallback,
            includeSynchronize: forceSynchronize || settings.runSynchronizeInAdditionToCheck
        )

        lastTriggerDate = result.timestamp
        switch result.outcome {
        case .triggeredAccount(let account):
            totalPushesTriggered += 1
            lastTriggerSummary = "Fetched '\(account)' (\(reason))"
            appendLog("Triggered Apple Mail fetch for account '\(account)' [\(reason)].")
        case .triggeredAllAccounts:
            totalPushesTriggered += 1
            lastTriggerSummary = "Fetched all accounts (\(reason))"
            appendLog("Triggered Apple Mail fetch for all accounts [\(reason)].")
        case .skippedMailNotRunning:
            lastTriggerSummary = "Skipped (Apple Mail not running)"
            appendLog("Skipped push trigger because Apple Mail is not currently running.")
        case .failed(let errorMessage):
            lastTriggerSummary = "Failed: \(errorMessage)"
            appendLog("Apple Mail trigger error: \(errorMessage)")
        }
    }

    func appendLog(_ message: String) {
        let entry = LogEntry(timestamp: Date(), message: message)
        activityLog.insert(entry, at: 0)
        if activityLog.count > 60 {
            activityLog.removeLast(activityLog.count - 60)
        }
    }

    var statusSummaryText: String {
        if isPaused {
            return "Paused"
        }
        if isWaitingForMail {
            return "Standby (Apple Mail closed)"
        }
        return connectionState.summaryText
    }

    var menuBarIconName: String {
        if isPaused {
            return "envelope.badge.fill"
        }
        if isWaitingForMail {
            return "envelope.badge"
        }
        switch connectionState {
        case .idling:
            return "bolt.horizontal.circle.fill"
        case .connecting, .authenticating, .selectingMailbox, .reconnecting:
            return "arrow.triangle.2.circlepath.circle"
        case .authFailed, .error:
            return "exclamationmark.triangle.fill"
        case .disconnected:
            return "envelope"
        }
    }
}
