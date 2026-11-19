import Foundation

enum GmailAuthMethod: String, CaseIterable, Identifiable, Sendable {
    case oauth2 = "oauth2"
    case appPassword = "appPassword"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oauth2:
            return "Sign in with Google (OAuth 2.0 / Passkey)"
        case .appPassword:
            return "Google App Password"
        }
    }
}

enum LowPowerModeBehavior: String, CaseIterable, Identifiable, Sendable {
    case reduceActivity = "reduceActivity"
    case pauseIdle = "pauseIdle"
    case keepNormal = "keepNormal"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reduceActivity:
            return "Widen Debounce & IDLE Refresh (8s / 25m)"
        case .pauseIdle:
            return "Pause IMAP IDLE in Low Power Mode"
        case .keepNormal:
            return "Keep Normal Push Timing"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    nonisolated static let defaultGmailIMAPHost = "imap.gmail.com"
    nonisolated static let defaultGmailIMAPPort: UInt16 = 993
    nonisolated static let defaultIdleRenewalMinutes: Int = 25
    nonisolated static let lowPowerDebounceSeconds: Double = 8.0
    nonisolated static let lowPowerIdleRenewalMinutes: Int = 25
    nonisolated static let allowedGmailIMAPHosts: Set<String> = [
        "imap.gmail.com",
        "imap.googlemail.com"
    ]

    nonisolated static func isAllowedGmailIMAPEndpoint(host: String, port: UInt16) -> Bool {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allowedGmailIMAPHosts.contains(normalizedHost) && port == defaultGmailIMAPPort
    }

    private let defaults: UserDefaults
    private let startUpdateChecks: Bool

    private enum Keys {
        static let authMethod = "authMethod"
        static let oauthClientId = "oauthClientId"
        static let gmailAddress = "gmailAddress"
        static let appleMailAccountName = "appleMailAccountName"
        static let checkAllAccountsFallback = "checkAllAccountsFallback"
        static let runSynchronizeInAdditionToCheck = "runSynchronizeInAdditionToCheck"
        static let syncReadAndArchiveChanges = "syncReadAndArchiveChanges"
        static let autoDisconnectWhenMailClosed = "autoDisconnectWhenMailClosed"
        static let lowPowerModeBehavior = "lowPowerModeBehavior"
        static let debounceSeconds = "debounceSeconds"
        static let idleRenewalMinutes = "idleRenewalMinutes"
        static let imapHost = "imapHost"
        static let imapPort = "imapPort"
        static let watchedMailbox = "watchedMailbox"
        static let filterByGmailCategories = "filterByGmailCategories"
        static let pushCategoryPrimary = "pushCategoryPrimary"
        static let pushCategoryUpdates = "pushCategoryUpdates"
        static let pushCategorySocial = "pushCategorySocial"
        static let pushCategoryPromotions = "pushCategoryPromotions"
        static let pushCategoryForums = "pushCategoryForums"
        static let pushImportantOnly = "pushImportantOnly"
        static let automaticallyCheckForUpdates = "automaticallyCheckForUpdates"
    }

    @Published var authMethod: GmailAuthMethod {
        didSet { defaults.set(authMethod.rawValue, forKey: Keys.authMethod) }
    }

    @Published var oauthClientId: String {
        didSet { defaults.set(oauthClientId, forKey: Keys.oauthClientId) }
    }

    @Published var gmailAddress: String {
        didSet { defaults.set(gmailAddress, forKey: Keys.gmailAddress) }
    }

    @Published var appleMailAccountName: String {
        didSet { defaults.set(appleMailAccountName, forKey: Keys.appleMailAccountName) }
    }

    @Published var checkAllAccountsFallback: Bool {
        didSet { defaults.set(checkAllAccountsFallback, forKey: Keys.checkAllAccountsFallback) }
    }

    @Published var runSynchronizeInAdditionToCheck: Bool {
        didSet { defaults.set(runSynchronizeInAdditionToCheck, forKey: Keys.runSynchronizeInAdditionToCheck) }
    }

    @Published var syncReadAndArchiveChanges: Bool {
        didSet { defaults.set(syncReadAndArchiveChanges, forKey: Keys.syncReadAndArchiveChanges) }
    }

    @Published var autoDisconnectWhenMailClosed: Bool {
        didSet { defaults.set(autoDisconnectWhenMailClosed, forKey: Keys.autoDisconnectWhenMailClosed) }
    }

    @Published var lowPowerModeBehavior: LowPowerModeBehavior {
        didSet { defaults.set(lowPowerModeBehavior.rawValue, forKey: Keys.lowPowerModeBehavior) }
    }

    @Published var debounceSeconds: Double {
        didSet { defaults.set(debounceSeconds, forKey: Keys.debounceSeconds) }
    }

    @Published var idleRenewalMinutes: Int {
        didSet { defaults.set(idleRenewalMinutes, forKey: Keys.idleRenewalMinutes) }
    }

    @Published var imapHost: String {
        didSet { defaults.set(imapHost, forKey: Keys.imapHost) }
    }

    @Published var imapPort: UInt16 {
        didSet { defaults.set(Int(imapPort), forKey: Keys.imapPort) }
    }

    @Published var watchedMailbox: String {
        didSet { defaults.set(watchedMailbox, forKey: Keys.watchedMailbox) }
    }

    @Published var filterByGmailCategories: Bool {
        didSet { defaults.set(filterByGmailCategories, forKey: Keys.filterByGmailCategories) }
    }

    @Published var pushCategoryPrimary: Bool {
        didSet { defaults.set(pushCategoryPrimary, forKey: Keys.pushCategoryPrimary) }
    }

    @Published var pushCategoryUpdates: Bool {
        didSet { defaults.set(pushCategoryUpdates, forKey: Keys.pushCategoryUpdates) }
    }

    @Published var pushCategorySocial: Bool {
        didSet { defaults.set(pushCategorySocial, forKey: Keys.pushCategorySocial) }
    }

    @Published var pushCategoryPromotions: Bool {
        didSet { defaults.set(pushCategoryPromotions, forKey: Keys.pushCategoryPromotions) }
    }

    @Published var pushCategoryForums: Bool {
        didSet { defaults.set(pushCategoryForums, forKey: Keys.pushCategoryForums) }
    }

    @Published var pushImportantOnly: Bool {
        didSet { defaults.set(pushImportantOnly, forKey: Keys.pushImportantOnly) }
    }

    @Published var automaticallyCheckForUpdates: Bool {
        didSet {
            defaults.set(automaticallyCheckForUpdates, forKey: Keys.automaticallyCheckForUpdates)
            guard startUpdateChecks else { return }
            if automaticallyCheckForUpdates {
                UpdateManager.shared.startPeriodicChecks(settings: self)
            } else {
                UpdateManager.shared.stopPeriodicChecks()
            }
        }
    }

    init(defaults: UserDefaults = .standard, startUpdateChecks: Bool = true) {
        self.defaults = defaults
        self.startUpdateChecks = startUpdateChecks
        if let rawMethod = defaults.string(forKey: Keys.authMethod),
           let parsed = GmailAuthMethod(rawValue: rawMethod) {
            self.authMethod = parsed
        } else {
            self.authMethod = .oauth2
        }

        let bundledClientId = Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientID") as? String
            ?? ProcessInfo.processInfo.environment["GMAIL_PUSH_OAUTH_CLIENT_ID"]
            ?? ""
        let savedClientId = defaults.string(forKey: Keys.oauthClientId) ?? ""
        self.oauthClientId = savedClientId.isEmpty ? bundledClientId : savedClientId

        self.gmailAddress = defaults.string(forKey: Keys.gmailAddress) ?? ""
        self.appleMailAccountName = defaults.string(forKey: Keys.appleMailAccountName) ?? "Google"
        if defaults.object(forKey: Keys.checkAllAccountsFallback) == nil {
            self.checkAllAccountsFallback = true
        } else {
            self.checkAllAccountsFallback = defaults.bool(forKey: Keys.checkAllAccountsFallback)
        }
        if defaults.object(forKey: Keys.runSynchronizeInAdditionToCheck) == nil {
            self.runSynchronizeInAdditionToCheck = true
        } else {
            self.runSynchronizeInAdditionToCheck = defaults.bool(forKey: Keys.runSynchronizeInAdditionToCheck)
        }
        if defaults.object(forKey: Keys.syncReadAndArchiveChanges) == nil {
            self.syncReadAndArchiveChanges = true
        } else {
            self.syncReadAndArchiveChanges = defaults.bool(forKey: Keys.syncReadAndArchiveChanges)
        }
        if defaults.object(forKey: Keys.autoDisconnectWhenMailClosed) == nil {
            self.autoDisconnectWhenMailClosed = true
        } else {
            self.autoDisconnectWhenMailClosed = defaults.bool(forKey: Keys.autoDisconnectWhenMailClosed)
        }
        if let rawLowPowerBehavior = defaults.string(forKey: Keys.lowPowerModeBehavior),
           let parsedLowPowerBehavior = LowPowerModeBehavior(rawValue: rawLowPowerBehavior) {
            self.lowPowerModeBehavior = parsedLowPowerBehavior
        } else {
            self.lowPowerModeBehavior = .reduceActivity
        }
        let savedDebounce = defaults.double(forKey: Keys.debounceSeconds)
        self.debounceSeconds = savedDebounce > 0 ? savedDebounce : 2.0

        let savedRenewal = defaults.integer(forKey: Keys.idleRenewalMinutes)
        self.idleRenewalMinutes = savedRenewal > 0 ? savedRenewal : Self.defaultIdleRenewalMinutes

        let candidateHost = defaults.string(forKey: Keys.imapHost) ?? Self.defaultGmailIMAPHost
        let savedPort = defaults.integer(forKey: Keys.imapPort)
        let candidatePort = (savedPort > 0 && savedPort <= Int(UInt16.max))
            ? UInt16(savedPort)
            : Self.defaultGmailIMAPPort

        if Self.isAllowedGmailIMAPEndpoint(host: candidateHost, port: candidatePort) {
            self.imapHost = candidateHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self.imapPort = candidatePort
        } else {
            self.imapHost = Self.defaultGmailIMAPHost
            self.imapPort = Self.defaultGmailIMAPPort
            defaults.set(Self.defaultGmailIMAPHost, forKey: Keys.imapHost)
            defaults.set(Int(Self.defaultGmailIMAPPort), forKey: Keys.imapPort)
        }
        self.watchedMailbox = defaults.string(forKey: Keys.watchedMailbox) ?? "INBOX"

        if defaults.object(forKey: Keys.filterByGmailCategories) == nil {
            self.filterByGmailCategories = false
        } else {
            self.filterByGmailCategories = defaults.bool(forKey: Keys.filterByGmailCategories)
        }
        if defaults.object(forKey: Keys.pushCategoryPrimary) == nil {
            self.pushCategoryPrimary = true
        } else {
            self.pushCategoryPrimary = defaults.bool(forKey: Keys.pushCategoryPrimary)
        }
        if defaults.object(forKey: Keys.pushCategoryUpdates) == nil {
            self.pushCategoryUpdates = false
        } else {
            self.pushCategoryUpdates = defaults.bool(forKey: Keys.pushCategoryUpdates)
        }
        if defaults.object(forKey: Keys.pushCategorySocial) == nil {
            self.pushCategorySocial = false
        } else {
            self.pushCategorySocial = defaults.bool(forKey: Keys.pushCategorySocial)
        }
        if defaults.object(forKey: Keys.pushCategoryPromotions) == nil {
            self.pushCategoryPromotions = false
        } else {
            self.pushCategoryPromotions = defaults.bool(forKey: Keys.pushCategoryPromotions)
        }
        if defaults.object(forKey: Keys.pushCategoryForums) == nil {
            self.pushCategoryForums = false
        } else {
            self.pushCategoryForums = defaults.bool(forKey: Keys.pushCategoryForums)
        }
        if defaults.object(forKey: Keys.pushImportantOnly) == nil {
            self.pushImportantOnly = false
        } else {
            self.pushImportantOnly = defaults.bool(forKey: Keys.pushImportantOnly)
        }

        if defaults.object(forKey: Keys.automaticallyCheckForUpdates) == nil {
            self.automaticallyCheckForUpdates = true
        } else {
            self.automaticallyCheckForUpdates = defaults.bool(forKey: Keys.automaticallyCheckForUpdates)
        }
    }

    func effectiveDebounceSeconds(isLowPowerMode: Bool) -> Double {
        if isLowPowerMode && lowPowerModeBehavior == .reduceActivity {
            return max(debounceSeconds, Self.lowPowerDebounceSeconds)
        }
        return debounceSeconds
    }

    func effectiveIdleRenewalMinutes(isLowPowerMode: Bool) -> Int {
        if isLowPowerMode && lowPowerModeBehavior == .reduceActivity {
            return max(idleRenewalMinutes, Self.lowPowerIdleRenewalMinutes)
        }
        return idleRenewalMinutes
    }

    private var selectedGmailCategories: [(label: String, queryTerm: String)] {
        let specs: [(enabled: Bool, label: String, queryTerm: String)] = [
            (pushCategoryPrimary, "Primary", "category:primary"),
            (pushCategoryUpdates, "Updates", "category:updates"),
            (pushCategorySocial, "Social", "category:social"),
            (pushCategoryPromotions, "Promotions", "category:promotions"),
            (pushCategoryForums, "Forums", "category:forums")
        ]
        return specs.filter(\.enabled).map { ($0.label, $0.queryTerm) }
    }

    /// Builds a Gmail `X-GM-RAW` search query for the currently enabled category and importance filters.
    func compiledGmailFilterQuery() -> String? {
        guard filterByGmailCategories else { return nil }
        let terms = selectedGmailCategories.map(\.queryTerm)

        let categoryExpr: String?
        if terms.count == 1 {
            categoryExpr = terms[0]
        } else if terms.count > 1 {
            categoryExpr = "(\(terms.joined(separator: " OR ")))"
        } else if pushImportantOnly {
            categoryExpr = nil
        } else {
            categoryExpr = "category:primary"
        }

        if pushImportantOnly {
            if let categoryExpr {
                return "\(categoryExpr) is:important"
            }
            return "is:important"
        }
        return categoryExpr
    }

    var activeFilterSummary: String {
        guard filterByGmailCategories else { return "All Inbox Mail" }
        let labels = selectedGmailCategories.map(\.label)
        if labels.isEmpty {
            return pushImportantOnly ? "Important only" : "Primary"
        }
        let joined = labels.joined(separator: ", ")
        return pushImportantOnly ? "\(joined) (Important only)" : joined
    }

    func sanitizedAppPassword() -> String? {
        guard let raw = KeychainStore.loadAppPassword(for: gmailAddress) else { return nil }
        let cleaned = raw.replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    var hasOAuthTokens: Bool {
        let email = gmailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return false }
        return KeychainStore.loadOAuthTokens(for: email) != nil
    }

    var hasAppPassword: Bool {
        let email = gmailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return false }
        return sanitizedAppPassword() != nil
    }

    var isConfigured: Bool {
        let email = gmailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return false }
        switch authMethod {
        case .oauth2:
            return hasOAuthTokens
        case .appPassword:
            return sanitizedAppPassword() != nil
        }
    }
}
