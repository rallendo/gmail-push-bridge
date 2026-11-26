import CryptoKit
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

struct CredentialsVault: Codable, Equatable, Sendable {
    var oauthTokens: [String: OAuthTokenSet] = [:]
    var oauthClientSecrets: [String: String] = [:]
    var appPasswords: [String: String] = [:]

    var isEmpty: Bool {
        oauthTokens.isEmpty && oauthClientSecrets.isEmpty && appPasswords.isEmpty
    }
}

struct VaultManifest: Codable, Equatable, Sendable {
    var salt: String? = nil
    var oauthTokenHashes: Set<String> = []
    var oauthTokenClientIdHashes: Set<String> = []
    var oauthClientSecretHashes: Set<String> = []
    var appPasswordHashes: Set<String> = []

    static func generateSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            fatalError("SecRandomCopyBytes failed with OSStatus \(status)")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func hashKey(_ normalizedKey: String, salt: String?) -> String {
        if let salt, !salt.isEmpty {
            let key = SymmetricKey(data: Data(salt.utf8))
            let mac = HMAC<SHA256>.authenticationCode(for: Data(normalizedKey.utf8), using: key)
            return mac.map { String(format: "%02x", $0) }.joined()
        }
        let digest = SHA256.hash(data: Data(normalizedKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func hashKey(_ normalizedKey: String) -> String {
        hashKey(normalizedKey, salt: nil)
    }

    func matchesOAuthToken(normalizedEmail: String) -> Bool {
        oauthTokenHashes.contains(Self.hashKey(normalizedEmail, salt: salt))
    }

    func matchesAppPassword(normalizedEmail: String) -> Bool {
        appPasswordHashes.contains(Self.hashKey(normalizedEmail, salt: salt))
    }

    func matchesOAuthClientSecret(normalizedClientId: String) -> Bool {
        let hash = Self.hashKey(normalizedClientId, salt: salt)
        return oauthClientSecretHashes.contains(hash) || oauthTokenClientIdHashes.contains(hash)
    }

    static func from(vault: CredentialsVault, salt: String? = nil) -> VaultManifest {
        let resolvedSalt = (salt?.isEmpty == false) ? salt! : generateSalt()
        var manifest = VaultManifest(salt: resolvedSalt)
        for email in vault.oauthTokens.keys {
            let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalized.isEmpty {
                manifest.oauthTokenHashes.insert(hashKey(normalized, salt: resolvedSalt))
            }
        }
        for token in vault.oauthTokens.values {
            let normalizedClientId = token.clientId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let secret = token.clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !normalizedClientId.isEmpty && !secret.isEmpty {
                manifest.oauthTokenClientIdHashes.insert(hashKey(normalizedClientId, salt: resolvedSalt))
            }
        }
        for (clientId, secret) in vault.oauthClientSecrets {
            let normalizedClientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedClientId.isEmpty && !trimmedSecret.isEmpty {
                manifest.oauthClientSecretHashes.insert(hashKey(normalizedClientId, salt: resolvedSalt))
            }
        }
        for email in vault.appPasswords.keys {
            let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalized.isEmpty {
                manifest.appPasswordHashes.insert(hashKey(normalized, salt: resolvedSalt))
            }
        }
        return manifest
    }
}

enum KeychainDataReadResult: Equatable, Sendable {
    case data(Data)
    case notFound
    case error(OSStatus)
}

enum KeychainAttributesReadResult: Equatable, Sendable {
    case found(genericData: Data?)
    case notFound
    case error(OSStatus)
}

protocol KeychainBackend: Sendable {
    func readData(service: String, account: String) -> KeychainDataReadResult
    func readAttributes(service: String, account: String) -> KeychainAttributesReadResult
    func saveData(_ data: Data, genericData: Data?, service: String, account: String) -> OSStatus
    func deleteItem(service: String, account: String) -> OSStatus
}

struct SystemKeychainBackend: KeychainBackend {
    func readData(service: String, account: String) -> KeychainDataReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return .data(data)
        } else if status == errSecItemNotFound {
            return .notFound
        } else {
            return .error(status == errSecSuccess ? errSecDecode : status)
        }
    }

    func readAttributes(service: String, account: String) -> KeychainAttributesReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess {
            let dict = item as? [String: Any]
            let genericData = dict?[kSecAttrGeneric as String] as? Data
            return .found(genericData: genericData)
        } else if status == errSecItemNotFound {
            return .notFound
        } else {
            return .error(status)
        }
    }

    func saveData(_ data: Data, genericData: Data?, service: String, account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        var attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        if let genericData {
            attributes[kSecAttrGeneric as String] = genericData
        }

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            return SecItemAdd(addQuery as CFDictionary, nil)
        }
        return updateStatus
    }

    func deleteItem(service: String, account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return SecItemDelete(query as CFDictionary)
    }
}

private final class VaultStore: @unchecked Sendable {
    // Two-lock hierarchy: ioLock serializes blocking Keychain data I/O / mutations;
    // cacheLock protects only in-memory state and is NEVER held across backend calls.
    // Acquisition order when both are needed: ioLock -> cacheLock.
    private let ioLock = NSLock()
    private let cacheLock = NSLock()

    private var backend: any KeychainBackend = SystemKeychainBackend()
    private var cachedVault: CredentialsVault?
    private var knownVaultAbsent: Bool = false
    private var cachedManifest: VaultManifest?
    private var vaultExistsWithoutManifest: Bool = false
    private var legacyPresenceCache: [String: Bool] = [:]

    private enum VaultPresenceState {
        case loaded(CredentialsVault)
        case absent
        case manifest(VaultManifest)
        case existsWithoutManifest
        case error(OSStatus)
    }

    private enum VaultLookupOutcome {
        case loaded(CredentialsVault)
        case absent
        case skippedByManifest
        case unreadable(OSStatus)
    }

    private enum VaultMutationLoadOutcome {
        case loaded(CredentialsVault)
        case notFound
        case unreadable(OSStatus)
    }

    private enum LegacyStringReadOutcome {
        case value(String)
        case notFound
        case error(OSStatus)
    }

    // MARK: - Testing Configuration

    func configureBackendForTesting(_ newBackend: any KeychainBackend) {
        ioLock.lock()
        defer { ioLock.unlock() }
        cacheLock.lock()
        backend = newBackend
        cachedVault = nil
        knownVaultAbsent = false
        cachedManifest = nil
        vaultExistsWithoutManifest = false
        legacyPresenceCache.removeAll()
        cacheLock.unlock()
    }

    func clearCacheForTesting() {
        ioLock.lock()
        defer { ioLock.unlock() }
        cacheLock.lock()
        cachedVault = nil
        knownVaultAbsent = false
        cachedManifest = nil
        vaultExistsWithoutManifest = false
        legacyPresenceCache.removeAll()
        cacheLock.unlock()
    }

    func resetForTesting() {
        configureBackendForTesting(SystemKeychainBackend())
    }

    // MARK: - Normalization & Helpers

    private func normalizeKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizeClientId(_ clientId: String) -> String? {
        let normalized = normalizeKey(clientId)
        return normalized.isEmpty ? nil : normalized
    }

    private func getBackend() -> any KeychainBackend {
        cacheLock.lock()
        let b = backend
        cacheLock.unlock()
        return b
    }

    private func getCachedVaultSnapshot() -> (vault: CredentialsVault?, knownAbsent: Bool, backend: any KeychainBackend) {
        cacheLock.lock()
        let result = (cachedVault, knownVaultAbsent, backend)
        cacheLock.unlock()
        return result
    }

    private func extractClientSecret(from vault: CredentialsVault, normalizedClientId: String) -> String? {
        if let stored = vault.oauthClientSecrets[normalizedClientId]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored
        }
        for token in vault.oauthTokens.values {
            if normalizeClientId(token.clientId) == normalizedClientId,
               let embedded = token.clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
               !embedded.isEmpty {
                return embedded
            }
        }
        return nil
    }

    // MARK: - Prompt-Free Attribute Inspection

    private func inspectVaultState() -> VaultPresenceState {
        let currentBackend: any KeychainBackend
        cacheLock.lock()
        if let vault = cachedVault {
            cacheLock.unlock()
            return .loaded(vault)
        }
        if knownVaultAbsent {
            cacheLock.unlock()
            return .absent
        }
        if let manifest = cachedManifest {
            cacheLock.unlock()
            return .manifest(manifest)
        }
        if vaultExistsWithoutManifest {
            cacheLock.unlock()
            return .existsWithoutManifest
        }
        currentBackend = backend
        cacheLock.unlock()

        let attrsResult = currentBackend.readAttributes(
            service: KeychainStore.service,
            account: KeychainStore.vaultAccountKey
        )

        switch attrsResult {
        case .notFound:
            cacheLock.lock()
            if let vault = cachedVault {
                cacheLock.unlock()
                return .loaded(vault)
            }
            knownVaultAbsent = true
            cachedManifest = nil
            vaultExistsWithoutManifest = false
            cacheLock.unlock()
            return .absent

        case .found(let genericData):
            let decodedManifest: VaultManifest?
            if let genericData {
                decodedManifest = try? JSONDecoder().decode(VaultManifest.self, from: genericData)
            } else {
                decodedManifest = nil
            }

            cacheLock.lock()
            if let vault = cachedVault {
                cacheLock.unlock()
                return .loaded(vault)
            }
            knownVaultAbsent = false
            if let decodedManifest {
                cachedManifest = decodedManifest
                vaultExistsWithoutManifest = false
                cacheLock.unlock()
                return .manifest(decodedManifest)
            } else {
                cachedManifest = nil
                vaultExistsWithoutManifest = true
                cacheLock.unlock()
                return .existsWithoutManifest
            }

        case .error(let status):
            return .error(status)
        }
    }

    private func hasLegacyItem(_ legacyKey: String) -> Bool {
        let normalized = normalizeKey(legacyKey)
        guard !normalized.isEmpty else { return false }

        let currentBackend: any KeychainBackend
        cacheLock.lock()
        if let cached = legacyPresenceCache[normalized] {
            cacheLock.unlock()
            return cached
        }
        currentBackend = backend
        cacheLock.unlock()

        let attrsResult = currentBackend.readAttributes(
            service: KeychainStore.service,
            account: normalized
        )

        switch attrsResult {
        case .found:
            cacheLock.lock()
            legacyPresenceCache[normalized] = true
            cacheLock.unlock()
            return true
        case .notFound:
            cacheLock.lock()
            legacyPresenceCache[normalized] = false
            cacheLock.unlock()
            return false
        case .error:
            return false
        }
    }

    // MARK: - Prompt-Free Existence & Memory-Only Checks

    func hasOAuthTokens(for account: String) -> Bool {
        let normalized = normalizeKey(account)
        guard !normalized.isEmpty else { return false }

        switch inspectVaultState() {
        case .loaded(let vault):
            if vault.oauthTokens[normalized] != nil {
                return true
            }
        case .manifest(let manifest):
            if manifest.matchesOAuthToken(normalizedEmail: normalized) {
                return true
            }
        case .existsWithoutManifest:
            return true
        case .absent, .error:
            break
        }

        return hasLegacyItem("oauth_tokens:\(normalized)")
    }

    func hasAppPassword(for account: String) -> Bool {
        let normalized = normalizeKey(account)
        guard !normalized.isEmpty else { return false }

        switch inspectVaultState() {
        case .loaded(let vault):
            if vault.appPasswords[normalized] != nil {
                return true
            }
        case .manifest(let manifest):
            if manifest.matchesAppPassword(normalizedEmail: normalized) {
                return true
            }
        case .existsWithoutManifest:
            return true
        case .absent, .error:
            break
        }

        return hasLegacyItem("app_password:\(normalized)") || hasLegacyItem(normalized)
    }

    func hasOAuthClientSecret(forClientId clientId: String) -> Bool {
        guard let normalized = normalizeClientId(clientId) else { return false }

        switch inspectVaultState() {
        case .loaded(let vault):
            if extractClientSecret(from: vault, normalizedClientId: normalized) != nil {
                return true
            }
        case .manifest(let manifest):
            if manifest.matchesOAuthClientSecret(normalizedClientId: normalized) {
                return true
            }
        case .existsWithoutManifest:
            return true
        case .absent, .error:
            break
        }

        return hasLegacyItem("oauth_client_secret:\(normalized)")
    }

    func cachedOAuthTokens(for account: String) -> OAuthTokenSet? {
        let normalized = normalizeKey(account)
        guard !normalized.isEmpty else { return nil }
        return getCachedVaultSnapshot().vault?.oauthTokens[normalized]
    }

    func cachedAppPassword(for account: String) -> String? {
        let normalized = normalizeKey(account)
        guard !normalized.isEmpty else { return nil }
        return getCachedVaultSnapshot().vault?.appPasswords[normalized]
    }

    func cachedOAuthClientSecret(forClientId clientId: String) -> String? {
        guard let normalized = normalizeClientId(clientId),
              let vault = getCachedVaultSnapshot().vault else {
            return nil
        }
        return extractClientSecret(from: vault, normalizedClientId: normalized)
    }

    // MARK: - Vault I/O (Caller MUST hold ioLock)

    private func loadVaultForRead(manifestMatches: (VaultManifest) -> Bool) -> VaultLookupOutcome {
        let snapshot = getCachedVaultSnapshot()
        if let vault = snapshot.vault {
            return .loaded(vault)
        }
        if snapshot.knownAbsent {
            return .absent
        }

        switch inspectVaultState() {
        case .loaded(let vault):
            return .loaded(vault)
        case .absent:
            return .absent
        case .error(let status):
            return .unreadable(status)
        case .manifest(let manifest):
            if !manifestMatches(manifest) {
                return .skippedByManifest
            }
        case .existsWithoutManifest:
            break
        }

        let readResult = snapshot.backend.readData(
            service: KeychainStore.service,
            account: KeychainStore.vaultAccountKey
        )

        switch readResult {
        case .notFound:
            cacheLock.lock()
            cachedVault = nil
            knownVaultAbsent = true
            cachedManifest = nil
            vaultExistsWithoutManifest = false
            cacheLock.unlock()
            return .absent

        case .error(let status):
            return .unreadable(status)

        case .data(let data):
            guard let vault = try? JSONDecoder().decode(CredentialsVault.self, from: data) else {
                return .unreadable(errSecDecode)
            }
            cacheLock.lock()
            let existingSalt = cachedManifest?.salt
            cacheLock.unlock()
            let manifest = VaultManifest.from(vault: vault, salt: existingSalt)
            cacheLock.lock()
            cachedVault = vault
            knownVaultAbsent = false
            cachedManifest = manifest
            vaultExistsWithoutManifest = false
            cacheLock.unlock()
            return .loaded(vault)
        }
    }

    private func loadExistingVaultForMutation() -> VaultMutationLoadOutcome {
        switch loadVaultForRead(manifestMatches: { _ in true }) {
        case .loaded(let vault):
            return .loaded(vault)
        case .absent:
            return .notFound
        case .unreadable(let status):
            return .unreadable(status)
        case .skippedByManifest:
            return .notFound
        }
    }

    private func persistVault(_ vault: CredentialsVault) -> OSStatus {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let vaultData = try? encoder.encode(vault) else {
            return errSecParam
        }
        cacheLock.lock()
        let existingSalt = cachedManifest?.salt
        cacheLock.unlock()
        let manifest = VaultManifest.from(vault: vault, salt: existingSalt)
        let manifestData = try? encoder.encode(manifest)

        let currentBackend = getBackend()
        let status = currentBackend.saveData(
            vaultData,
            genericData: manifestData,
            service: KeychainStore.service,
            account: KeychainStore.vaultAccountKey
        )

        if status == errSecSuccess {
            cacheLock.lock()
            cachedVault = vault
            cachedManifest = manifest
            knownVaultAbsent = false
            vaultExistsWithoutManifest = false
            cacheLock.unlock()
        }
        return status
    }

    private func persistOrDeleteEmptyVault(_ vault: CredentialsVault) {
        if vault.isEmpty {
            let currentBackend = getBackend()
            let status = currentBackend.deleteItem(
                service: KeychainStore.service,
                account: KeychainStore.vaultAccountKey
            )
            if status == errSecSuccess || status == errSecItemNotFound {
                cacheLock.lock()
                cachedVault = nil
                cachedManifest = nil
                knownVaultAbsent = true
                vaultExistsWithoutManifest = false
                cacheLock.unlock()
            }
        } else {
            _ = persistVault(vault)
        }
    }

    private func deleteLegacyItemIfPresent(_ legacyKey: String) {
        let normalized = normalizeKey(legacyKey)
        guard !normalized.isEmpty else { return }
        guard hasLegacyItem(normalized) else { return }

        let status = getBackend().deleteItem(service: KeychainStore.service, account: normalized)
        if status == errSecSuccess || status == errSecItemNotFound {
            cacheLock.lock()
            legacyPresenceCache[normalized] = false
            cacheLock.unlock()
        }
    }

    private func readLegacyString(forKey legacyKey: String) -> LegacyStringReadOutcome {
        let normalized = normalizeKey(legacyKey)
        guard !normalized.isEmpty else { return .notFound }

        let result = getBackend().readData(service: KeychainStore.service, account: normalized)
        switch result {
        case .data(let data):
            guard let str = String(data: data, encoding: .utf8) else {
                return .error(errSecDecode)
            }
            return .value(str)
        case .notFound:
            cacheLock.lock()
            legacyPresenceCache[normalized] = false
            cacheLock.unlock()
            return .notFound
        case .error(let status):
            return .error(status)
        }
    }

    // MARK: - Typed Vault Operations

    func saveOAuthTokens(_ tokens: OAuthTokenSet, for account: String) throws {
        let normalized = normalizeKey(account)
        guard !normalized.isEmpty else { return }

        ioLock.lock()
        defer { ioLock.unlock() }

        let previousVault: CredentialsVault?
        var vault: CredentialsVault
        switch loadExistingVaultForMutation() {
        case .loaded(let existing):
            previousVault = existing
            vault = existing
        case .notFound:
            previousVault = nil
            vault = CredentialsVault()
        case .unreadable(let status):
            throw KeychainError.unexpectedStatus(status)
        }

        vault.oauthTokens[normalized] = tokens
        var legacyClientSecretKey: String?
        if let secret = tokens.clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
           !secret.isEmpty,
           let normalizedClientId = normalizeClientId(tokens.clientId) {
            vault.oauthClientSecrets[normalizedClientId] = secret
            legacyClientSecretKey = "oauth_client_secret:\(normalizedClientId)"
        }

        let isAbsent = getCachedVaultSnapshot().knownAbsent
        if let previousVault, previousVault == vault, !isAbsent {
            deleteLegacyItemIfPresent("oauth_tokens:\(normalized)")
            if let legacyClientSecretKey {
                deleteLegacyItemIfPresent(legacyClientSecretKey)
            }
            return
        }

        let status = persistVault(vault)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }

        deleteLegacyItemIfPresent("oauth_tokens:\(normalized)")
        if let legacyClientSecretKey {
            deleteLegacyItemIfPresent(legacyClientSecretKey)
        }
    }

    func loadOAuthTokens(for account: String) -> OAuthTokenSet? {
        let normalized = normalizeKey(account)
        guard !normalized.isEmpty else { return nil }

        let legacyKey = "oauth_tokens:\(normalized)"
        if let vault = getCachedVaultSnapshot().vault {
            if let tokens = vault.oauthTokens[normalized] {
                return tokens
            }
            if !hasLegacyItem(legacyKey) {
                return nil
            }
        }

        ioLock.lock()
        defer { ioLock.unlock() }

        switch loadVaultForRead(manifestMatches: { $0.matchesOAuthToken(normalizedEmail: normalized) }) {
        case .loaded(let vault):
            if let tokens = vault.oauthTokens[normalized] {
                return tokens
            }
        case .unreadable:
            return nil
        case .absent, .skippedByManifest:
            break
        }

        guard hasLegacyItem(legacyKey) else { return nil }

        let readResult = getBackend().readData(service: KeychainStore.service, account: legacyKey)
        guard case .data(let data) = readResult else {
            if case .notFound = readResult {
                cacheLock.lock()
                legacyPresenceCache[legacyKey] = false
                cacheLock.unlock()
            }
            return nil
        }

        guard let tokens = try? JSONDecoder().decode(OAuthTokenSet.self, from: data) else {
            return nil
        }

        var vault: CredentialsVault
        switch loadExistingVaultForMutation() {
        case .loaded(let existing):
            vault = existing
        case .notFound:
            vault = CredentialsVault()
        case .unreadable:
            return tokens
        }

        vault.oauthTokens[normalized] = tokens
        var legacyClientSecretKey: String?
        if let secret = tokens.clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
           !secret.isEmpty,
           let normalizedClientId = normalizeClientId(tokens.clientId) {
            vault.oauthClientSecrets[normalizedClientId] = secret
            legacyClientSecretKey = "oauth_client_secret:\(normalizedClientId)"
        }

        if persistVault(vault) == errSecSuccess {
            deleteLegacyItemIfPresent(legacyKey)
            if let legacyClientSecretKey {
                deleteLegacyItemIfPresent(legacyClientSecretKey)
            }
        }

        return tokens
    }

    func deleteOAuthTokens(for account: String) {
        let normalized = normalizeKey(account)
        guard !normalized.isEmpty else { return }

        ioLock.lock()
        defer { ioLock.unlock() }

        if case .loaded(var vault) = loadVaultForRead(manifestMatches: { $0.matchesOAuthToken(normalizedEmail: normalized) }),
           vault.oauthTokens.removeValue(forKey: normalized) != nil {
            persistOrDeleteEmptyVault(vault)
        }

        deleteLegacyItemIfPresent("oauth_tokens:\(normalized)")
    }

    func saveAppPassword(_ password: String, for account: String) throws {
        let normalized = normalizeKey(account)
        guard !normalized.isEmpty else { return }

        ioLock.lock()
        defer { ioLock.unlock() }

        let previousVault: CredentialsVault?
        var vault: CredentialsVault
        switch loadExistingVaultForMutation() {
        case .loaded(let existing):
            previousVault = existing
            vault = existing
        case .notFound:
            previousVault = nil
            vault = CredentialsVault()
        case .unreadable(let status):
            throw KeychainError.unexpectedStatus(status)
        }

        vault.appPasswords[normalized] = password

        let isAbsent = getCachedVaultSnapshot().knownAbsent
        if let previousVault, previousVault == vault, !isAbsent {
            deleteLegacyItemIfPresent("app_password:\(normalized)")
            deleteLegacyItemIfPresent(normalized)
            return
        }

        let status = persistVault(vault)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }

        deleteLegacyItemIfPresent("app_password:\(normalized)")
        deleteLegacyItemIfPresent(normalized)
    }

    func loadAppPassword(for account: String) -> String? {
        let normalized = normalizeKey(account)
        guard !normalized.isEmpty else { return nil }

        let primaryLegacyKey = "app_password:\(normalized)"
        let fallbackLegacyKey = normalized
        if let vault = getCachedVaultSnapshot().vault {
            if let password = vault.appPasswords[normalized] {
                return password
            }
            if !hasLegacyItem(primaryLegacyKey) && !hasLegacyItem(fallbackLegacyKey) {
                return nil
            }
        }

        ioLock.lock()
        defer { ioLock.unlock() }

        switch loadVaultForRead(manifestMatches: { $0.matchesAppPassword(normalizedEmail: normalized) }) {
        case .loaded(let vault):
            if let password = vault.appPasswords[normalized] {
                return password
            }
        case .unreadable:
            return nil
        case .absent, .skippedByManifest:
            break
        }

        var migratedPassword: String?
        for candidateKey in [primaryLegacyKey, fallbackLegacyKey] {
            guard hasLegacyItem(candidateKey) else { continue }
            switch readLegacyString(forKey: candidateKey) {
            case .value(let str):
                migratedPassword = str
            case .notFound:
                continue
            case .error:
                return nil
            }
            if migratedPassword != nil {
                break
            }
        }

        guard let password = migratedPassword else { return nil }

        var vault: CredentialsVault
        switch loadExistingVaultForMutation() {
        case .loaded(let existing):
            vault = existing
        case .notFound:
            vault = CredentialsVault()
        case .unreadable:
            return password
        }

        vault.appPasswords[normalized] = password
        if persistVault(vault) == errSecSuccess {
            deleteLegacyItemIfPresent(primaryLegacyKey)
            deleteLegacyItemIfPresent(fallbackLegacyKey)
        }

        return password
    }

    func deleteAppPassword(for account: String) {
        let normalized = normalizeKey(account)
        guard !normalized.isEmpty else { return }

        ioLock.lock()
        defer { ioLock.unlock() }

        if case .loaded(var vault) = loadVaultForRead(manifestMatches: { $0.matchesAppPassword(normalizedEmail: normalized) }),
           vault.appPasswords.removeValue(forKey: normalized) != nil {
            persistOrDeleteEmptyVault(vault)
        }

        deleteLegacyItemIfPresent("app_password:\(normalized)")
        deleteLegacyItemIfPresent(normalized)
    }

    func saveOAuthClientSecret(_ secret: String, forClientId clientId: String) throws {
        guard let normalizedClientId = normalizeClientId(clientId) else { return }
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSecret.isEmpty else { return }

        ioLock.lock()
        defer { ioLock.unlock() }

        let previousVault: CredentialsVault?
        var vault: CredentialsVault
        switch loadExistingVaultForMutation() {
        case .loaded(let existing):
            previousVault = existing
            vault = existing
        case .notFound:
            previousVault = nil
            vault = CredentialsVault()
        case .unreadable(let status):
            throw KeychainError.unexpectedStatus(status)
        }

        vault.oauthClientSecrets[normalizedClientId] = trimmedSecret

        let legacyKey = "oauth_client_secret:\(normalizedClientId)"
        let isAbsent = getCachedVaultSnapshot().knownAbsent
        if let previousVault, previousVault == vault, !isAbsent {
            deleteLegacyItemIfPresent(legacyKey)
            return
        }

        let status = persistVault(vault)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }

        deleteLegacyItemIfPresent(legacyKey)
    }

    func loadOAuthClientSecret(forClientId clientId: String) -> String? {
        guard let normalizedClientId = normalizeClientId(clientId) else { return nil }

        let legacyKey = "oauth_client_secret:\(normalizedClientId)"
        if let vault = getCachedVaultSnapshot().vault {
            if let secret = extractClientSecret(from: vault, normalizedClientId: normalizedClientId) {
                return secret
            }
            if !hasLegacyItem(legacyKey) {
                return nil
            }
        }

        ioLock.lock()
        defer { ioLock.unlock() }

        switch loadVaultForRead(manifestMatches: {
            $0.matchesOAuthClientSecret(normalizedClientId: normalizedClientId)
        }) {
        case .loaded(let vault):
            if let secret = extractClientSecret(from: vault, normalizedClientId: normalizedClientId) {
                return secret
            }
        case .unreadable:
            return nil
        case .absent, .skippedByManifest:
            break
        }

        guard hasLegacyItem(legacyKey) else { return nil }

        switch readLegacyString(forKey: legacyKey) {
        case .value(let rawSecret):
            let trimmed = rawSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            var vault: CredentialsVault
            switch loadExistingVaultForMutation() {
            case .loaded(let existing):
                vault = existing
            case .notFound:
                vault = CredentialsVault()
            case .unreadable:
                return trimmed
            }

            vault.oauthClientSecrets[normalizedClientId] = trimmed
            if persistVault(vault) == errSecSuccess {
                deleteLegacyItemIfPresent(legacyKey)
            }
            return trimmed

        case .notFound, .error:
            return nil
        }
    }

    func deleteOAuthClientSecret(forClientId clientId: String) {
        guard let normalizedClientId = normalizeClientId(clientId) else { return }

        ioLock.lock()
        defer { ioLock.unlock() }

        if case .loaded(var vault) = loadVaultForRead(manifestMatches: {
            $0.matchesOAuthClientSecret(normalizedClientId: normalizedClientId)
        }) {
            var modified = vault.oauthClientSecrets.removeValue(forKey: normalizedClientId) != nil
            for (email, var token) in vault.oauthTokens where normalizeClientId(token.clientId) == normalizedClientId && token.clientSecret != nil {
                token.clientSecret = nil
                vault.oauthTokens[email] = token
                modified = true
            }
            if modified {
                persistOrDeleteEmptyVault(vault)
            }
        }

        deleteLegacyItemIfPresent("oauth_client_secret:\(normalizedClientId)")
    }

    // MARK: - Raw Keychain Helpers (Backwards Compatibility)

    func saveRawData(_ data: Data, forKey key: String) throws {
        let normalizedKey = normalizeKey(key)
        guard !normalizedKey.isEmpty else { return }

        ioLock.lock()
        defer { ioLock.unlock() }

        let status = getBackend().saveData(
            data,
            genericData: nil,
            service: KeychainStore.service,
            account: normalizedKey
        )
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }

        cacheLock.lock()
        legacyPresenceCache[normalizedKey] = true
        if normalizedKey == KeychainStore.vaultAccountKey {
            cachedVault = nil
            knownVaultAbsent = false
            cachedManifest = nil
            vaultExistsWithoutManifest = false
        }
        cacheLock.unlock()
    }

    func loadRawData(forKey key: String) -> Data? {
        let normalizedKey = normalizeKey(key)
        guard !normalizedKey.isEmpty else { return nil }

        ioLock.lock()
        defer { ioLock.unlock() }

        switch getBackend().readData(service: KeychainStore.service, account: normalizedKey) {
        case .data(let data):
            return data
        case .notFound:
            cacheLock.lock()
            legacyPresenceCache[normalizedKey] = false
            cacheLock.unlock()
            return nil
        case .error:
            return nil
        }
    }

    func deleteRawData(forKey key: String) {
        let normalizedKey = normalizeKey(key)
        guard !normalizedKey.isEmpty else { return }

        ioLock.lock()
        defer { ioLock.unlock() }

        let status = getBackend().deleteItem(service: KeychainStore.service, account: normalizedKey)
        if status == errSecSuccess || status == errSecItemNotFound {
            cacheLock.lock()
            legacyPresenceCache[normalizedKey] = false
            if normalizedKey == KeychainStore.vaultAccountKey {
                cachedVault = nil
                knownVaultAbsent = true
                cachedManifest = nil
                vaultExistsWithoutManifest = false
            }
            cacheLock.unlock()
        }
    }
}

struct KeychainStore {
    static let service = "com.gmailpushbridge.app"
    static let vaultAccountKey = "credentials_vault"

    private static let store = VaultStore()

    static func configureBackendForTesting(_ backend: any KeychainBackend) {
        store.configureBackendForTesting(backend)
    }

    static func clearCacheForTesting() {
        store.clearCacheForTesting()
    }

    static func resetForTesting() {
        store.resetForTesting()
    }

    static func saveData(_ data: Data, forKey key: String) throws {
        try store.saveRawData(data, forKey: key)
    }

    static func loadData(forKey key: String) -> Data? {
        store.loadRawData(forKey: key)
    }

    static func deleteData(forKey key: String) {
        store.deleteRawData(forKey: key)
    }

    // MARK: - Prompt-Free Presence & Memory-Only Cache Checks

    static func hasOAuthTokens(for account: String) -> Bool {
        store.hasOAuthTokens(for: account)
    }

    static func hasAppPassword(for account: String) -> Bool {
        store.hasAppPassword(for: account)
    }

    static func hasOAuthClientSecret(forClientId clientId: String) -> Bool {
        store.hasOAuthClientSecret(forClientId: clientId)
    }

    static func cachedOAuthTokens(for account: String) -> OAuthTokenSet? {
        store.cachedOAuthTokens(for: account)
    }

    static func cachedAppPassword(for account: String) -> String? {
        store.cachedAppPassword(for: account)
    }

    static func cachedOAuthClientSecret(forClientId clientId: String) -> String? {
        store.cachedOAuthClientSecret(forClientId: clientId)
    }

    // MARK: - App Password Helpers

    static func saveAppPassword(_ password: String, for account: String) throws {
        try store.saveAppPassword(password, for: account)
    }

    static func loadAppPassword(for account: String) -> String? {
        store.loadAppPassword(for: account)
    }

    static func deleteAppPassword(for account: String) {
        store.deleteAppPassword(for: account)
    }

    // MARK: - OAuth Token Helpers

    static func saveOAuthTokens(_ tokens: OAuthTokenSet, for account: String) throws {
        try store.saveOAuthTokens(tokens, for: account)
    }

    static func loadOAuthTokens(for account: String) -> OAuthTokenSet? {
        store.loadOAuthTokens(for: account)
    }

    static func deleteOAuthTokens(for account: String) {
        store.deleteOAuthTokens(for: account)
    }

    // MARK: - OAuth Client Secret Helpers

    private static let oauthClientSecretKeyPrefix = "oauth_client_secret:"

    static func oauthClientSecretKey(forClientId clientId: String) -> String? {
        let trimmed = clientId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        return "\(oauthClientSecretKeyPrefix)\(trimmed)"
    }

    static func saveOAuthClientSecret(_ secret: String, forClientId clientId: String) throws {
        try store.saveOAuthClientSecret(secret, forClientId: clientId)
    }

    static func loadOAuthClientSecret(forClientId clientId: String) -> String? {
        store.loadOAuthClientSecret(forClientId: clientId)
    }

    static func deleteOAuthClientSecret(forClientId clientId: String) {
        store.deleteOAuthClientSecret(forClientId: clientId)
    }
}
