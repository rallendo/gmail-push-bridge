import XCTest
@testable import GmailPushBridge

private final class MockKeychainBackend: KeychainBackend, @unchecked Sendable {
    struct StoredItem: Equatable {
        var data: Data
        var genericData: Data?
    }

    private let lock = NSLock()
    private var storage: [String: StoredItem] = [:]

    private var readDataError: OSStatus?
    private var readDataCalls = 0
    private var readAttributesCalls = 0
    private var saveCalls = 0
    private var deleteCalls = 0

    private func compositeKey(service: String, account: String) -> String {
        "\(service)::\(account)"
    }

    func resetCounters() {
        lock.lock()
        readDataCalls = 0
        readAttributesCalls = 0
        saveCalls = 0
        deleteCalls = 0
        lock.unlock()
    }

    func setReadDataError(_ status: OSStatus?) {
        lock.lock()
        readDataError = status
        lock.unlock()
    }

    func seedItem(
        service: String = KeychainStore.service,
        account: String,
        data: Data,
        genericData: Data? = nil
    ) {
        lock.lock()
        storage[compositeKey(service: service, account: account)] = StoredItem(
            data: data,
            genericData: genericData
        )
        lock.unlock()
    }

    func item(service: String = KeychainStore.service, account: String) -> StoredItem? {
        lock.lock()
        let found = storage[compositeKey(service: service, account: account)]
        lock.unlock()
        return found
    }

    func counts() -> (readData: Int, readAttributes: Int, save: Int, delete: Int) {
        lock.lock()
        let snapshot = (readDataCalls, readAttributesCalls, saveCalls, deleteCalls)
        lock.unlock()
        return snapshot
    }

    func readData(service: String, account: String) -> KeychainDataReadResult {
        lock.lock()
        defer { lock.unlock() }
        readDataCalls += 1
        if let err = readDataError {
            return .error(err)
        }
        guard let item = storage[compositeKey(service: service, account: account)] else {
            return .notFound
        }
        return .data(item.data)
    }

    func readAttributes(service: String, account: String) -> KeychainAttributesReadResult {
        lock.lock()
        defer { lock.unlock() }
        readAttributesCalls += 1
        guard let item = storage[compositeKey(service: service, account: account)] else {
            return .notFound
        }
        return .found(genericData: item.genericData)
    }

    func saveData(_ data: Data, genericData: Data?, service: String, account: String) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        saveCalls += 1
        let key = compositeKey(service: service, account: account)
        let preservedGeneric = genericData ?? storage[key]?.genericData
        storage[key] = StoredItem(data: data, genericData: preservedGeneric)
        return errSecSuccess
    }

    func deleteItem(service: String, account: String) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        deleteCalls += 1
        let removed = storage.removeValue(forKey: compositeKey(service: service, account: account))
        return removed == nil ? errSecItemNotFound : errSecSuccess
    }
}

final class KeychainStoreTests: XCTestCase {
    private var backend: MockKeychainBackend!

    override func setUp() {
        super.setUp()
        backend = MockKeychainBackend()
        KeychainStore.configureBackendForTesting(backend)
    }

    override func tearDown() {
        KeychainStore.resetForTesting()
        backend = nil
        super.tearDown()
    }

    private func makeSampleTokenSet(
        clientId: String = "123456.apps.googleusercontent.com",
        clientSecret: String? = "client-secret-xyz"
    ) -> OAuthTokenSet {
        OAuthTokenSet(
            accessToken: "ya29.access",
            refreshToken: "1//refresh",
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            clientId: clientId,
            clientSecret: clientSecret
        )
    }

    func testSingleVaultStorageAndCachingAcrossSimulatedRelaunch() throws {
        let tokens = makeSampleTokenSet()
        try KeychainStore.saveOAuthTokens(tokens, for: "  Alice@Gmail.com ")
        try KeychainStore.saveAppPassword("abcd-efgh-ijkl-mnop", for: "Alice@Gmail.com")

        // Verify everything lives inside the single vault entry
        XCTAssertNotNil(backend.item(account: KeychainStore.vaultAccountKey))
        XCTAssertNil(backend.item(account: "oauth_tokens:alice@gmail.com"))
        XCTAssertNil(backend.item(account: "oauth_client_secret:123456.apps.googleusercontent.com"))
        XCTAssertNil(backend.item(account: "app_password:alice@gmail.com"))

        // Simulate app relaunch (clear in-memory cache while preserving Keychain backend)
        KeychainStore.clearCacheForTesting()
        backend.resetCounters()

        // Cached getters do not touch Keychain before unlock
        XCTAssertNil(KeychainStore.cachedOAuthTokens(for: "alice@gmail.com"))
        XCTAssertNil(KeychainStore.cachedOAuthClientSecret(forClientId: "123456.apps.googleusercontent.com"))
        XCTAssertNil(KeychainStore.cachedAppPassword(for: "alice@gmail.com"))
        XCTAssertEqual(backend.counts().readData, 0)
        XCTAssertEqual(backend.counts().readAttributes, 0)

        // Repeated existence checks use 1 attribute read and 0 secret data reads
        for _ in 0..<3 {
            XCTAssertTrue(KeychainStore.hasOAuthTokens(for: "ALICE@gmail.com"))
            XCTAssertTrue(KeychainStore.hasOAuthClientSecret(forClientId: "123456.APPS.GOOGLEUSERCONTENT.COM"))
            XCTAssertTrue(KeychainStore.hasAppPassword(for: "alice@gmail.com"))
        }
        XCTAssertEqual(backend.counts().readData, 0)
        XCTAssertEqual(backend.counts().readAttributes, 1)

        // First load unlocks the single vault once; subsequent loads hit memory cache
        for _ in 0..<3 {
            XCTAssertEqual(KeychainStore.loadOAuthTokens(for: "alice@gmail.com"), tokens)
            XCTAssertEqual(
                KeychainStore.loadOAuthClientSecret(forClientId: "123456.apps.googleusercontent.com"),
                "client-secret-xyz"
            )
            XCTAssertEqual(KeychainStore.loadAppPassword(for: "alice@gmail.com"), "abcd-efgh-ijkl-mnop")
        }
        XCTAssertEqual(backend.counts().readData, 1)

        // Memory-only cached getters now return populated values without any Keychain reads
        XCTAssertEqual(KeychainStore.cachedOAuthTokens(for: "alice@gmail.com"), tokens)
        XCTAssertEqual(
            KeychainStore.cachedOAuthClientSecret(forClientId: "123456.apps.googleusercontent.com"),
            "client-secret-xyz"
        )
        XCTAssertEqual(KeychainStore.cachedAppPassword(for: "alice@gmail.com"), "abcd-efgh-ijkl-mnop")
        XCTAssertEqual(backend.counts().readData, 1)
    }

    func testLazyMigrationFromLegacyOAuthTokensAndClientSecret() throws {
        let tokens = makeSampleTokenSet(
            clientId: "Client-99.apps.googleusercontent.com",
            clientSecret: "embedded-secret"
        )
        let encodedTokens = try JSONEncoder().encode(tokens)
        backend.seedItem(account: "oauth_tokens:alice@gmail.com", data: encodedTokens)
        backend.seedItem(
            account: "oauth_client_secret:client-99.apps.googleusercontent.com",
            data: Data("embedded-secret".utf8)
        )
        backend.resetCounters()

        // Presence check is prompt-free
        XCTAssertTrue(KeychainStore.hasOAuthTokens(for: "Alice@Gmail.com"))
        XCTAssertTrue(KeychainStore.hasOAuthClientSecret(forClientId: "client-99.apps.googleusercontent.com"))
        XCTAssertEqual(backend.counts().readData, 0)

        // Loading OAuth tokens reads legacy item once and consolidates both token & client secret into vault
        let loaded = KeychainStore.loadOAuthTokens(for: "alice@gmail.com")
        XCTAssertEqual(loaded, tokens)
        XCTAssertEqual(backend.counts().readData, 1)

        XCTAssertNotNil(backend.item(account: KeychainStore.vaultAccountKey))
        XCTAssertNil(backend.item(account: "oauth_tokens:alice@gmail.com"))
        XCTAssertNil(backend.item(account: "oauth_client_secret:client-99.apps.googleusercontent.com"))

        // After simulated relaunch, both token and client secret load from the single vault with 1 readData
        KeychainStore.clearCacheForTesting()
        backend.resetCounters()

        XCTAssertEqual(KeychainStore.loadOAuthTokens(for: "alice@gmail.com"), tokens)
        XCTAssertEqual(
            KeychainStore.loadOAuthClientSecret(forClientId: "client-99.apps.googleusercontent.com"),
            "embedded-secret"
        )
        XCTAssertEqual(backend.counts().readData, 1)
    }

    func testLazyMigrationFromLegacyAppPasswordAndOldestKeyFormat() {
        // 1. Primary legacy format ("app_password:<email>")
        backend.seedItem(account: "app_password:bob@gmail.com", data: Data("pass-primary".utf8))
        XCTAssertTrue(KeychainStore.hasAppPassword(for: "bob@gmail.com"))
        XCTAssertEqual(backend.counts().readData, 0)

        XCTAssertEqual(KeychainStore.loadAppPassword(for: "bob@gmail.com"), "pass-primary")
        XCTAssertEqual(backend.counts().readData, 1)
        XCTAssertNil(backend.item(account: "app_password:bob@gmail.com"))
        XCTAssertNotNil(backend.item(account: KeychainStore.vaultAccountKey))

        // 2. Oldest legacy format ("<email>")
        KeychainStore.resetForTesting()
        backend = MockKeychainBackend()
        KeychainStore.configureBackendForTesting(backend)
        backend.seedItem(account: "carol@gmail.com", data: Data("pass-oldest".utf8))
        backend.resetCounters()

        XCTAssertTrue(KeychainStore.hasAppPassword(for: "Carol@Gmail.com"))
        XCTAssertEqual(backend.counts().readData, 0)

        XCTAssertEqual(KeychainStore.loadAppPassword(for: "carol@gmail.com"), "pass-oldest")
        XCTAssertEqual(backend.counts().readData, 1)
        XCTAssertNil(backend.item(account: "carol@gmail.com"))
        XCTAssertNotNil(backend.item(account: KeychainStore.vaultAccountKey))
    }

    func testLegacyAppPasswordMigrationPreservesExistingVaultOAuthTokens() throws {
        let tokens = makeSampleTokenSet()
        try KeychainStore.saveOAuthTokens(tokens, for: "alice@gmail.com")
        backend.seedItem(account: "app_password:alice@gmail.com", data: Data("legacy-app-pass".utf8))

        KeychainStore.clearCacheForTesting()
        backend.resetCounters()

        // Migrate legacy app password while vault already holds OAuth tokens
        XCTAssertEqual(KeychainStore.loadAppPassword(for: "alice@gmail.com"), "legacy-app-pass")
        XCTAssertNil(backend.item(account: "app_password:alice@gmail.com"))

        // Verify existing OAuth tokens were preserved in the vault
        KeychainStore.clearCacheForTesting()
        XCTAssertEqual(KeychainStore.loadOAuthTokens(for: "alice@gmail.com"), tokens)
        XCTAssertEqual(KeychainStore.loadAppPassword(for: "alice@gmail.com"), "legacy-app-pass")
    }

    func testUnreadableVaultDoesNotFallThroughOrClobberExistingData() throws {
        let tokens = makeSampleTokenSet()
        try KeychainStore.saveOAuthTokens(tokens, for: "alice@gmail.com")
        let originalVaultItem = backend.item(account: KeychainStore.vaultAccountKey)

        // Seed a legacy item as well to prove unreadable vault does NOT trigger fallback legacy reads
        backend.seedItem(account: "oauth_tokens:alice@gmail.com", data: try JSONEncoder().encode(tokens))

        KeychainStore.clearCacheForTesting()
        backend.resetCounters()
        backend.setReadDataError(errSecUserCanceled)

        // Manifest still reports presence with 0 data reads
        XCTAssertTrue(KeychainStore.hasOAuthTokens(for: "alice@gmail.com"))
        XCTAssertEqual(backend.counts().readData, 0)

        // Loading returns nil without falling through to legacy item
        XCTAssertNil(KeychainStore.loadOAuthTokens(for: "alice@gmail.com"))
        XCTAssertEqual(backend.counts().readData, 1)

        // Saving refuses to clobber existing unreadable vault
        XCTAssertThrowsError(try KeychainStore.saveAppPassword("new-pass", for: "alice@gmail.com")) { error in
            guard case KeychainError.unexpectedStatus(let status) = error else {
                XCTFail("Expected KeychainError.unexpectedStatus, got \(error)")
                return
            }
            XCTAssertEqual(status, errSecUserCanceled)
        }
        XCTAssertEqual(backend.counts().save, 0)
        XCTAssertEqual(backend.item(account: KeychainStore.vaultAccountKey), originalVaultItem)

        // Once user stops cancelling, loading succeeds cleanly
        backend.setReadDataError(nil)
        XCTAssertEqual(KeychainStore.loadOAuthTokens(for: "alice@gmail.com"), tokens)
    }

    func testManifestPreCheckSkipsDecryptionForAbsentKeys() throws {
        let tokens = makeSampleTokenSet()
        try KeychainStore.saveOAuthTokens(tokens, for: "alice@gmail.com")

        KeychainStore.clearCacheForTesting()
        backend.resetCounters()

        XCTAssertFalse(KeychainStore.hasOAuthTokens(for: "other@gmail.com"))
        XCTAssertFalse(KeychainStore.hasAppPassword(for: "alice@gmail.com"))
        XCTAssertFalse(KeychainStore.hasOAuthClientSecret(forClientId: "other-client.apps.googleusercontent.com"))

        XCTAssertNil(KeychainStore.loadOAuthTokens(for: "other@gmail.com"))
        XCTAssertNil(KeychainStore.loadAppPassword(for: "alice@gmail.com"))
        XCTAssertNil(KeychainStore.loadOAuthClientSecret(forClientId: "other-client.apps.googleusercontent.com"))

        // Vault was never decrypted because the manifest knew none of those keys exist
        XCTAssertEqual(backend.counts().readData, 0)
    }

    func testDeletionPreservesClientSecretAndDeletesVaultWhenEmpty() throws {
        let tokens = makeSampleTokenSet(clientId: "client-1", clientSecret: "secret-1")
        try KeychainStore.saveOAuthTokens(tokens, for: "alice@gmail.com")

        // Delete OAuth tokens -> client secret remains in vault and manifest updates
        KeychainStore.deleteOAuthTokens(for: "alice@gmail.com")
        XCTAssertFalse(KeychainStore.hasOAuthTokens(for: "alice@gmail.com"))
        XCTAssertTrue(KeychainStore.hasOAuthClientSecret(forClientId: "client-1"))
        XCTAssertNotNil(backend.item(account: KeychainStore.vaultAccountKey))

        // Verify across simulated relaunch
        KeychainStore.clearCacheForTesting()
        backend.resetCounters()
        XCTAssertFalse(KeychainStore.hasOAuthTokens(for: "alice@gmail.com"))
        XCTAssertTrue(KeychainStore.hasOAuthClientSecret(forClientId: "client-1"))
        XCTAssertEqual(backend.counts().readData, 0)
        XCTAssertEqual(KeychainStore.loadOAuthClientSecret(forClientId: "client-1"), "secret-1")

        // Deleting the last remaining secret removes the vault entry entirely
        KeychainStore.deleteOAuthClientSecret(forClientId: "client-1")
        XCTAssertFalse(KeychainStore.hasOAuthClientSecret(forClientId: "client-1"))
        XCTAssertNil(backend.item(account: KeychainStore.vaultAccountKey))
    }

    func testNoOpSaveAvoidanceDoesNotRewriteVault() throws {
        let tokens = makeSampleTokenSet()
        try KeychainStore.saveOAuthTokens(tokens, for: "alice@gmail.com")
        try KeychainStore.saveOAuthClientSecret("client-secret-xyz", forClientId: "123456.apps.googleusercontent.com")
        try KeychainStore.saveAppPassword("pass-1234", for: "alice@gmail.com")
        let savesBefore = backend.counts().save

        // Saving identical values again is a no-op
        try KeychainStore.saveOAuthTokens(tokens, for: "alice@gmail.com")
        try KeychainStore.saveOAuthClientSecret("client-secret-xyz", forClientId: "123456.apps.googleusercontent.com")
        try KeychainStore.saveAppPassword("pass-1234", for: "alice@gmail.com")

        XCTAssertEqual(backend.counts().save, savesBefore)
    }

    @MainActor
    func testAppSettingsStatusChecksArePromptFree() throws {
        let suiteName = "com.gmailpushbridge.keychainsettings.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let tokens = makeSampleTokenSet(clientId: "client-settings", clientSecret: "secret-settings")
        try KeychainStore.saveOAuthTokens(tokens, for: "alice@gmail.com")
        try KeychainStore.saveAppPassword("abcd-efgh-ijkl-mnop", for: "alice@gmail.com")

        KeychainStore.clearCacheForTesting()
        backend.resetCounters()

        let settings = AppSettings(defaults: defaults, startUpdateChecks: false)
        settings.gmailAddress = "alice@gmail.com"
        settings.oauthClientId = "client-settings"

        settings.authMethod = .oauth2
        XCTAssertTrue(settings.hasOAuthTokens)
        XCTAssertTrue(settings.hasOAuthClientSecret)
        XCTAssertTrue(settings.isConfigured)

        settings.authMethod = .appPassword
        XCTAssertTrue(settings.hasAppPassword)
        XCTAssertTrue(settings.isConfigured)

        XCTAssertEqual(backend.counts().readData, 0)
    }
}
