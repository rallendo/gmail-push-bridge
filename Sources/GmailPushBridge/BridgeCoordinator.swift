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
    @Published private(set) var isSleeping: Bool = false
    @Published private(set) var isWaitingForMail: Bool = false
    @Published private(set) var isLowPowerModeEnabled: Bool = false
    @Published private(set) var isPausedForLowPowerMode: Bool = false
    @Published private(set) var isSigningInWithGoogle: Bool = false
    @Published private(set) var lastTriggerDate: Date?
    @Published private(set) var lastTriggerSummary: String = "No push triggered yet"
    @Published private(set) var totalPushesTriggered: Int = 0
    @Published private(set) var totalPushesFilteredOut: Int = 0
    @Published private(set) var detectedMailAccounts: [String] = []
    @Published private(set) var activityLog: [LogEntry] = []

    private static let minReadArchiveDebounceSeconds: Double = 5.0
    private static let syncEchoCooldownSeconds: TimeInterval = 15.0

    private let enableBackgroundMonitors: Bool
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
        self.enableBackgroundMonitors = enableBackgroundMonitors
        guard enableBackgroundMonitors else { return }

        self.isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
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
            onSystemSleep: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleSystemSleep()
                }
            },
            onSystemWake: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleSystemWake()
                }
            },
            onNetworkRestored: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, !self.isPaused, !self.isSleeping, !self.isWaitingForMail, !self.isPausedForLowPowerMode, self.settings.isConfigured else { return }
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
            },
            onLowPowerModeChanged: { [weak self] isLowPower in
                Task { @MainActor [weak self] in
                    self?.handleLowPowerModeChanged(isLowPower)
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

        if let existingTokens,
           let existingSecret = existingTokens.clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
           !existingSecret.isEmpty {
            let clientId = existingTokens.clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? settings.oauthClientId
                : existingTokens.clientId
            try? KeychainStore.saveOAuthClientSecret(existingSecret, forClientId: clientId)
        }

        isWaitingForMail = false
        isPausedForLowPowerMode = false
        imapClient?.stop()
        connectionState = .disconnected
        if !email.isEmpty {
            KeychainStore.deleteOAuthTokens(for: email)
        }
        settings.objectWillChange.send()
        appendLog("Removed stored OAuth tokens from Keychain (kept Client ID & Secret).")

        if let tokens = existingTokens {
            let tokenToRevoke = tokens.refreshToken.isEmpty ? tokens.accessToken : tokens.refreshToken
            Task {
                await GoogleOAuthManager.shared.revokeToken(tokenToRevoke)
            }
        }
    }

    func removeOAuthClientSecret() {
        let clientId = settings.oauthClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientId.isEmpty else { return }
        KeychainStore.deleteOAuthClientSecret(forClientId: clientId)
        settings.objectWillChange.send()
        appendLog("Removed stored OAuth Client Secret from Keychain.")
    }

    func removeAppPassword() {
        let email = settings.gmailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        isWaitingForMail = false
        isPausedForLowPowerMode = false
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

        switch settings.authMethod {
        case .oauth2:
            guard settings.hasOAuthTokens else {
                connectionState = .disconnected
                appendLog("Click 'Sign in with Google' to authorize IMAP access.")
                return
            }

        case .appPassword:
            guard settings.hasAppPassword else {
                connectionState = .disconnected
                appendLog("Cannot start: 16-character App Password missing.")
                return
            }
        }

        isPaused = false
        isSleeping = false
        if systemMonitor != nil {
            isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        if settings.lowPowerModeBehavior == .pauseIdle && isLowPowerModeEnabled {
            enterLowPowerStandby(logMessage: "macOS Low Power Mode is active — pausing IMAP IDLE to conserve battery.")
            return
        }
        if settings.autoDisconnectWhenMailClosed && !AppleMailBridge.isMailRunning() {
            enterMailClosedStandby(logMessage: "Waiting for Apple Mail to launch (auto-disconnect when Mail is closed is enabled).")
            return
        }

        let credentialMode: IMAPCredentialMode
        switch settings.authMethod {
        case .oauth2:
            credentialMode = .xoauth2 {
                try await GoogleOAuthManager.shared.validAccessToken(for: email)
            }

        case .appPassword:
            guard let appPassword = settings.sanitizedAppPassword() else {
                connectionState = .disconnected
                appendLog("Cannot start: 16-character App Password missing or Keychain access denied.")
                return
            }
            credentialMode = .appPassword(appPassword)
        }

        isWaitingForMail = false
        isPausedForLowPowerMode = false
        let config = IMAPConfiguration(
            host: settings.imapHost,
            port: settings.imapPort,
            email: email,
            credentialMode: credentialMode,
            mailbox: settings.watchedMailbox,
            idleRenewalMinutes: settings.effectiveIdleRenewalMinutes(isLowPowerMode: isLowPowerModeEnabled),
            filterQuery: settings.compiledGmailFilterQuery()
        )
        imapClient?.start(with: config)
    }

    func pauseMonitoring() {
        isPaused = true
        isSleeping = false
        isWaitingForMail = false
        isPausedForLowPowerMode = false
        cancelPendingDebounce()
        imapClient?.stop()
        appendLog("Monitoring paused by user.")
    }

    func handleAutoDisconnectSettingChanged(_ enabled: Bool) {
        guard settings.isConfigured, !isPaused, !isPausedForLowPowerMode else {
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

    func handleLowPowerModeBehaviorChanged(_ behavior: LowPowerModeBehavior) {
        if systemMonitor != nil {
            isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        let effectiveIdle = settings.effectiveIdleRenewalMinutes(isLowPowerMode: isLowPowerModeEnabled)
        imapClient?.updateIdleRenewalMinutes(effectiveIdle)

        guard (settings.isConfigured || !enableBackgroundMonitors), !isPaused else {
            if behavior != .pauseIdle || !isLowPowerModeEnabled {
                isPausedForLowPowerMode = false
            }
            return
        }

        if isLowPowerModeEnabled {
            switch behavior {
            case .pauseIdle:
                if !isPausedForLowPowerMode {
                    enterLowPowerStandby(logMessage: "Low Power Mode behavior set to pause — pausing IMAP IDLE.")
                }
            case .reduceActivity:
                let effectiveDebounce = settings.effectiveDebounceSeconds(isLowPowerMode: true)
                if isPausedForLowPowerMode {
                    isPausedForLowPowerMode = false
                    guard enableBackgroundMonitors else { return }
                    if settings.autoDisconnectWhenMailClosed && !AppleMailBridge.isMailRunning() {
                        enterMailClosedStandby(logMessage: "Apple Mail is closed — staying in standby.")
                    } else {
                        appendLog("Low Power Mode behavior set to conserve battery (debounce \(String(format: "%.1fs", effectiveDebounce)), IDLE \(effectiveIdle) min) — reconnecting.")
                        startMonitoring()
                        scheduleDebouncedFetch(reason: "Low Power Mode setting changed", delayOverride: 2.0)
                    }
                } else {
                    appendLog("Low Power Mode active — widening debounce to \(String(format: "%.1fs", effectiveDebounce)) and IDLE refresh to \(effectiveIdle) min.")
                }
            case .keepNormal:
                if isPausedForLowPowerMode {
                    isPausedForLowPowerMode = false
                    guard enableBackgroundMonitors else { return }
                    if settings.autoDisconnectWhenMailClosed && !AppleMailBridge.isMailRunning() {
                        enterMailClosedStandby(logMessage: "Apple Mail is closed — staying in standby.")
                    } else {
                        appendLog("Low Power Mode behavior set to keep normal timing — reconnecting.")
                        startMonitoring()
                        scheduleDebouncedFetch(reason: "Low Power Mode setting changed", delayOverride: 2.0)
                    }
                } else {
                    appendLog("Low Power Mode active — keeping normal push timing (\(String(format: "%.1fs", settings.debounceSeconds)), \(settings.idleRenewalMinutes) min).")
                }
            }
        } else if isPausedForLowPowerMode {
            isPausedForLowPowerMode = false
            guard enableBackgroundMonitors else { return }
            startMonitoring()
        }
    }

    func handleIdleRenewalMinutesChanged() {
        let effectiveIdle = settings.effectiveIdleRenewalMinutes(isLowPowerMode: isLowPowerModeEnabled)
        imapClient?.updateIdleRenewalMinutes(effectiveIdle)
    }

    func handlePushFilterSettingsChanged() {
        if settings.filterByGmailCategories &&
            !settings.pushCategoryPrimary &&
            !settings.pushCategoryUpdates &&
            !settings.pushCategorySocial &&
            !settings.pushCategoryPromotions &&
            !settings.pushCategoryForums &&
            !settings.pushImportantOnly {
            settings.pushCategoryPrimary = true
        }

        let query = settings.compiledGmailFilterQuery()
        imapClient?.updateFilterQuery(query)
        if settings.filterByGmailCategories {
            appendLog("Gmail category filter active: \(settings.activeFilterSummary) [X-GM-RAW: \(query ?? "")]")
        } else {
            appendLog("Gmail category filter disabled — pushing all INBOX mail.")
        }
    }

    private func enterMailClosedStandby(logMessage: String) {
        cancelPendingDebounce()
        isWaitingForMail = true
        isPausedForLowPowerMode = false
        imapClient?.stop()
        connectionState = .disconnected
        appendLog(logMessage)
    }

    private func enterLowPowerStandby(logMessage: String) {
        cancelPendingDebounce()
        isPausedForLowPowerMode = true
        isWaitingForMail = false
        imapClient?.stop()
        connectionState = .disconnected
        appendLog(logMessage)
    }

    func handleLowPowerModeChanged(_ isEnabled: Bool) {
        let wasEnabled = isLowPowerModeEnabled
        isLowPowerModeEnabled = isEnabled
        guard wasEnabled != isEnabled || (isEnabled && settings.lowPowerModeBehavior == .pauseIdle && !isPausedForLowPowerMode) else {
            return
        }

        let effectiveIdle = settings.effectiveIdleRenewalMinutes(isLowPowerMode: isEnabled)
        imapClient?.updateIdleRenewalMinutes(effectiveIdle)

        guard (settings.isConfigured || !enableBackgroundMonitors), !isPaused else {
            if !isEnabled {
                isPausedForLowPowerMode = false
            }
            return
        }

        if isEnabled {
            switch settings.lowPowerModeBehavior {
            case .reduceActivity:
                let effectiveDebounce = settings.effectiveDebounceSeconds(isLowPowerMode: true)
                appendLog("macOS Low Power Mode enabled — widening debounce to \(String(format: "%.1fs", effectiveDebounce)) and IDLE refresh to \(effectiveIdle) min.")
            case .pauseIdle:
                if !isPausedForLowPowerMode {
                    enterLowPowerStandby(logMessage: "macOS Low Power Mode enabled — pausing IMAP IDLE to conserve battery.")
                }
            case .keepNormal:
                appendLog("macOS Low Power Mode enabled — keeping normal push timing.")
            }
        } else {
            switch settings.lowPowerModeBehavior {
            case .reduceActivity:
                appendLog("macOS Low Power Mode disabled — restoring debounce to \(String(format: "%.1fs", settings.debounceSeconds)) and IDLE refresh to \(settings.idleRenewalMinutes) min.")
            case .pauseIdle:
                if isPausedForLowPowerMode {
                    isPausedForLowPowerMode = false
                    guard enableBackgroundMonitors else {
                        appendLog("macOS Low Power Mode disabled — ready to resume IMAP IDLE.")
                        return
                    }
                    if settings.autoDisconnectWhenMailClosed && !AppleMailBridge.isMailRunning() {
                        enterMailClosedStandby(logMessage: "macOS Low Power Mode disabled, but Apple Mail is closed — staying in standby.")
                    } else {
                        appendLog("macOS Low Power Mode disabled — reconnecting IMAP IDLE & checking mail.")
                        startMonitoring()
                        scheduleDebouncedFetch(reason: "Low Power Mode disabled", delayOverride: 2.0)
                    }
                }
            case .keepNormal:
                if isPausedForLowPowerMode {
                    isPausedForLowPowerMode = false
                    guard enableBackgroundMonitors else { return }
                    startMonitoring()
                }
            }
        }
    }

    private func cancelPendingDebounce() {
        debounceTask?.cancel()
        debounceTask = nil
        pendingDebounceIsNewMail = false
        pendingDebounceForceSynchronize = false
    }

    func handleSystemSleep() {
        guard !isSleeping else { return }
        isSleeping = true
        cancelPendingDebounce()
        if !isPaused && !isWaitingForMail && !isPausedForLowPowerMode && (settings.isConfigured || !enableBackgroundMonitors) {
            imapClient?.stop()
            connectionState = .disconnected
            appendLog("Mac going to sleep — pausing IMAP IDLE until wake.")
        }
    }

    func handleSystemWake() {
        isSleeping = false
        guard !isPaused, !isWaitingForMail, !isPausedForLowPowerMode, settings.isConfigured else { return }
        if settings.lowPowerModeBehavior == .pauseIdle && ProcessInfo.processInfo.isLowPowerModeEnabled {
            enterLowPowerStandby(logMessage: "Low Power Mode is active after wake — staying in standby.")
            return
        }
        if settings.autoDisconnectWhenMailClosed && !AppleMailBridge.isMailRunning() {
            enterMailClosedStandby(logMessage: "Apple Mail is closed after wake — staying in standby.")
            return
        }
        appendLog("Mac woke from sleep — reconnecting IMAP IDLE & checking mail.")
        startMonitoring()
        scheduleDebouncedFetch(reason: "Wake from sleep", delayOverride: 3.0)
    }

    private func handleMailTerminated() {
        guard settings.autoDisconnectWhenMailClosed, !isPaused, !isPausedForLowPowerMode, settings.isConfigured else { return }
        enterMailClosedStandby(logMessage: "Apple Mail quit — pausing IMAP IDLE until Mail launches.")
    }

    private func handleMailLaunched() {
        guard !isPaused, !isSleeping, !isPausedForLowPowerMode, settings.isConfigured else { return }
        if settings.lowPowerModeBehavior == .pauseIdle && isLowPowerModeEnabled {
            return
        }
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
        case .filteredMailSkipped(let count, _):
            totalPushesFilteredOut += 1
            lastTriggerSummary = "Filtered out (* \(count) EXISTS — non-matching category)"
        case .mailboxSyncDetected(let reason):
            guard settings.syncReadAndArchiveChanges else { return }
            if isExecutingMailFetch {
                return
            }
            if let lastCompleted = lastMailFetchCompletedAt,
               Date().timeIntervalSince(lastCompleted) < Self.syncEchoCooldownSeconds {
                return
            }
            let defaultDebounce = settings.effectiveDebounceSeconds(isLowPowerMode: isLowPowerModeEnabled)
            let minDelay = max(Self.minReadArchiveDebounceSeconds, defaultDebounce)
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

        let defaultDebounce = settings.effectiveDebounceSeconds(isLowPowerMode: isLowPowerModeEnabled)
        let resolvedDelay: Double
        if effectiveIsNewMail && !isNewMail {
            resolvedDelay = max(0.5, defaultDebounce)
        } else {
            resolvedDelay = max(0.5, delayOverride ?? defaultDebounce)
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
        if isPausedForLowPowerMode {
            return "Standby (Low Power Mode)"
        }
        if isWaitingForMail {
            return "Standby (Apple Mail closed)"
        }
        if isLowPowerModeEnabled && settings.lowPowerModeBehavior == .reduceActivity && connectionState.isIdling {
            return "\(connectionState.summaryText) • Low Power"
        }
        return connectionState.summaryText
    }

    var menuBarIconName: String {
        if isPaused {
            return "envelope.badge.fill"
        }
        if isPausedForLowPowerMode {
            return "bolt.slash.circle"
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
