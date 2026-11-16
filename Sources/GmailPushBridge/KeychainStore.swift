import Foundation
import Security

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error (\(status)): \(message)"
            }
            return "Keychain error (\(status))"
        }
    }
}

struct KeychainStore {
    static let service = "com.gmailpushbridge.app"

    static func saveData(_ data: Data, forKey key: String) throws {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedKey.isEmpty else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: normalizedKey
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        } else if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        } else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    static func loadData(forKey key: String) -> Data? {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedKey.isEmpty else { return nil }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: normalizedKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return data
    }

    static func deleteData(forKey key: String) {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedKey.isEmpty else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: normalizedKey
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - App Password Helpers

    static func saveAppPassword(_ password: String, for account: String) throws {
        try saveData(Data(password.utf8), forKey: "app_password:\(account)")
    }

    static func loadAppPassword(for account: String) -> String? {
        if let data = loadData(forKey: "app_password:\(account)"),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        // Backwards compatibility with initial key format
        if let data = loadData(forKey: account),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return nil
    }

    static func deleteAppPassword(for account: String) {
        deleteData(forKey: "app_password:\(account)")
        deleteData(forKey: account)
    }

    // MARK: - OAuth Token Helpers

    private static let oauthKeyPrefix = "oauth_tokens:"

    static func saveOAuthTokens(_ tokens: OAuthTokenSet, for account: String) throws {
        let data = try JSONEncoder().encode(tokens)
        try saveData(data, forKey: "\(oauthKeyPrefix)\(account)")
    }

    static func loadOAuthTokens(for account: String) -> OAuthTokenSet? {
        guard let data = loadData(forKey: "\(oauthKeyPrefix)\(account)") else { return nil }
        return try? JSONDecoder().decode(OAuthTokenSet.self, from: data)
    }

    static func deleteOAuthTokens(for account: String) {
        deleteData(forKey: "\(oauthKeyPrefix)\(account)")
    }
}
