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

@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let authMethod = "authMethod"
        static let oauthClientId = "oauthClientId"
        static let gmailAddress = "gmailAddress"
        static let appleMailAccountName = "appleMailAccountName"
        static let checkAllAccountsFallback = "checkAllAccountsFallback"
        static let runSynchronizeInAdditionToCheck = "runSynchronizeInAdditionToCheck"
        static let debounceSeconds = "debounceSeconds"
        static let idleRenewalMinutes = "idleRenewalMinutes"
        static let imapHost = "imapHost"
        static let imapPort = "imapPort"
        static let watchedMailbox = "watchedMailbox"
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

    init() {
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
        let savedDebounce = defaults.double(forKey: Keys.debounceSeconds)
        self.debounceSeconds = savedDebounce > 0 ? savedDebounce : 2.0

        let savedRenewal = defaults.integer(forKey: Keys.idleRenewalMinutes)
        self.idleRenewalMinutes = savedRenewal > 0 ? savedRenewal : 14

        self.imapHost = defaults.string(forKey: Keys.imapHost) ?? "imap.gmail.com"
        let savedPort = defaults.integer(forKey: Keys.imapPort)
        self.imapPort = savedPort > 0 ? UInt16(savedPort) : 993
        self.watchedMailbox = defaults.string(forKey: Keys.watchedMailbox) ?? "INBOX"
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
