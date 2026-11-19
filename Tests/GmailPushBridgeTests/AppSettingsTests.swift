import XCTest
@testable import GmailPushBridge

@MainActor
final class AppSettingsTests: XCTestCase {
    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "com.gmailpushbridge.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return (defaults, suiteName)
    }

    func testAllowedGmailIMAPEndpoints() {
        XCTAssertTrue(AppSettings.isAllowedGmailIMAPEndpoint(host: "imap.gmail.com", port: 993))
        XCTAssertTrue(AppSettings.isAllowedGmailIMAPEndpoint(host: "imap.googlemail.com", port: 993))
        XCTAssertTrue(AppSettings.isAllowedGmailIMAPEndpoint(host: "  IMAP.GMAIL.COM \n", port: 993))
        XCTAssertTrue(AppSettings.isAllowedGmailIMAPEndpoint(host: "IMAP.GOOGLEMAIL.COM", port: 993))

        XCTAssertFalse(AppSettings.isAllowedGmailIMAPEndpoint(host: "imap.gmail.com", port: 143))
        XCTAssertFalse(AppSettings.isAllowedGmailIMAPEndpoint(host: "imap.gmail.com", port: 995))
        XCTAssertFalse(AppSettings.isAllowedGmailIMAPEndpoint(host: "imap.gmail.com", port: 80))
        XCTAssertFalse(AppSettings.isAllowedGmailIMAPEndpoint(host: "imap.gmail.com", port: 0))
        XCTAssertFalse(AppSettings.isAllowedGmailIMAPEndpoint(host: "evil.example.com", port: 993))
        XCTAssertFalse(AppSettings.isAllowedGmailIMAPEndpoint(host: "imap.gmail.com.attacker.com", port: 993))
        XCTAssertFalse(AppSettings.isAllowedGmailIMAPEndpoint(host: "", port: 993))
    }

    func testGmailAuthMethodMetadata() {
        XCTAssertEqual(GmailAuthMethod.allCases.count, 2)
        XCTAssertEqual(GmailAuthMethod.oauth2.id, "oauth2")
        XCTAssertEqual(GmailAuthMethod.appPassword.id, "appPassword")
        XCTAssertFalse(GmailAuthMethod.oauth2.title.isEmpty)
        XCTAssertFalse(GmailAuthMethod.appPassword.title.isEmpty)
    }

    func testDefaultValues() {
        let (defaults, _) = makeIsolatedDefaults()
        let settings = AppSettings(defaults: defaults, startUpdateChecks: false)

        XCTAssertEqual(settings.authMethod, .oauth2)
        XCTAssertEqual(settings.gmailAddress, "")
        XCTAssertEqual(settings.appleMailAccountName, "Google")
        XCTAssertTrue(settings.checkAllAccountsFallback)
        XCTAssertTrue(settings.runSynchronizeInAdditionToCheck)
        XCTAssertTrue(settings.syncReadAndArchiveChanges)
        XCTAssertTrue(settings.autoDisconnectWhenMailClosed)
        XCTAssertEqual(settings.lowPowerModeBehavior, .reduceActivity)
        XCTAssertEqual(settings.debounceSeconds, 2.0)
        XCTAssertEqual(settings.idleRenewalMinutes, 25)
        XCTAssertEqual(settings.imapHost, AppSettings.defaultGmailIMAPHost)
        XCTAssertEqual(settings.imapPort, AppSettings.defaultGmailIMAPPort)
        XCTAssertEqual(settings.watchedMailbox, "INBOX")
        XCTAssertFalse(settings.filterByGmailCategories)
        XCTAssertTrue(settings.pushCategoryPrimary)
        XCTAssertFalse(settings.pushCategoryUpdates)
        XCTAssertFalse(settings.pushCategorySocial)
        XCTAssertFalse(settings.pushCategoryPromotions)
        XCTAssertFalse(settings.pushCategoryForums)
        XCTAssertFalse(settings.pushImportantOnly)
        XCTAssertTrue(settings.automaticallyCheckForUpdates)
        XCTAssertFalse(settings.isConfigured)
    }

    func testPersistenceAcrossReinstantiation() {
        let (defaults, _) = makeIsolatedDefaults()
        let settings = AppSettings(defaults: defaults, startUpdateChecks: false)

        settings.authMethod = .appPassword
        settings.oauthClientId = "123456-abcdef.apps.googleusercontent.com"
        settings.gmailAddress = "alice@gmail.com"
        settings.appleMailAccountName = "Personal Gmail"
        settings.checkAllAccountsFallback = false
        settings.runSynchronizeInAdditionToCheck = false
        settings.syncReadAndArchiveChanges = false
        settings.autoDisconnectWhenMailClosed = false
        settings.lowPowerModeBehavior = .pauseIdle
        settings.debounceSeconds = 4.5
        settings.idleRenewalMinutes = 20
        settings.imapHost = "imap.googlemail.com"
        settings.imapPort = 993
        settings.watchedMailbox = "[Gmail]/All Mail"
        settings.filterByGmailCategories = true
        settings.pushCategoryPrimary = false
        settings.pushCategoryUpdates = true
        settings.pushCategorySocial = true
        settings.pushCategoryPromotions = true
        settings.pushCategoryForums = true
        settings.pushImportantOnly = true
        settings.automaticallyCheckForUpdates = false

        let reloaded = AppSettings(defaults: defaults, startUpdateChecks: false)
        XCTAssertEqual(reloaded.authMethod, .appPassword)
        XCTAssertEqual(reloaded.oauthClientId, "123456-abcdef.apps.googleusercontent.com")
        XCTAssertEqual(reloaded.gmailAddress, "alice@gmail.com")
        XCTAssertEqual(reloaded.appleMailAccountName, "Personal Gmail")
        XCTAssertFalse(reloaded.checkAllAccountsFallback)
        XCTAssertFalse(reloaded.runSynchronizeInAdditionToCheck)
        XCTAssertFalse(reloaded.syncReadAndArchiveChanges)
        XCTAssertFalse(reloaded.autoDisconnectWhenMailClosed)
        XCTAssertEqual(reloaded.lowPowerModeBehavior, .pauseIdle)
        XCTAssertEqual(reloaded.debounceSeconds, 4.5)
        XCTAssertEqual(reloaded.idleRenewalMinutes, 20)
        XCTAssertEqual(reloaded.imapHost, "imap.googlemail.com")
        XCTAssertEqual(reloaded.imapPort, 993)
        XCTAssertEqual(reloaded.watchedMailbox, "[Gmail]/All Mail")
        XCTAssertTrue(reloaded.filterByGmailCategories)
        XCTAssertFalse(reloaded.pushCategoryPrimary)
        XCTAssertTrue(reloaded.pushCategoryUpdates)
        XCTAssertTrue(reloaded.pushCategorySocial)
        XCTAssertTrue(reloaded.pushCategoryPromotions)
        XCTAssertTrue(reloaded.pushCategoryForums)
        XCTAssertTrue(reloaded.pushImportantOnly)
        XCTAssertFalse(reloaded.automaticallyCheckForUpdates)
    }

    func testSanitizesInvalidPersistedValuesOnInit() {
        let (defaults, _) = makeIsolatedDefaults()
        defaults.set("invalidAuthMethod", forKey: "authMethod")
        defaults.set("invalidBehavior", forKey: "lowPowerModeBehavior")
        defaults.set("evil.example.com", forKey: "imapHost")
        defaults.set(143, forKey: "imapPort")
        defaults.set(-1.5, forKey: "debounceSeconds")
        defaults.set(0, forKey: "idleRenewalMinutes")

        let settings = AppSettings(defaults: defaults, startUpdateChecks: false)
        XCTAssertEqual(settings.authMethod, .oauth2)
        XCTAssertEqual(settings.lowPowerModeBehavior, .reduceActivity)
        XCTAssertEqual(settings.imapHost, AppSettings.defaultGmailIMAPHost)
        XCTAssertEqual(settings.imapPort, AppSettings.defaultGmailIMAPPort)
        XCTAssertEqual(defaults.string(forKey: "imapHost"), AppSettings.defaultGmailIMAPHost)
        XCTAssertEqual(defaults.integer(forKey: "imapPort"), Int(AppSettings.defaultGmailIMAPPort))
        XCTAssertEqual(settings.debounceSeconds, 2.0)
        XCTAssertEqual(settings.idleRenewalMinutes, 25)
    }

    func testNormalizesAllowedGooglemailHostOnInit() {
        let (defaults, _) = makeIsolatedDefaults()
        defaults.set("  IMAP.GOOGLEMAIL.COM  ", forKey: "imapHost")
        defaults.set(993, forKey: "imapPort")

        let settings = AppSettings(defaults: defaults, startUpdateChecks: false)
        XCTAssertEqual(settings.imapHost, "imap.googlemail.com")
        XCTAssertEqual(settings.imapPort, 993)
    }

    func testLowPowerModeBehaviorMetadataAndEffectiveTiming() {
        XCTAssertEqual(LowPowerModeBehavior.allCases.count, 3)
        for behavior in LowPowerModeBehavior.allCases {
            XCTAssertFalse(behavior.id.isEmpty)
            XCTAssertFalse(behavior.title.isEmpty)
        }

        let (defaults, _) = makeIsolatedDefaults()
        let settings = AppSettings(defaults: defaults, startUpdateChecks: false)
        settings.debounceSeconds = 2.0
        settings.idleRenewalMinutes = 14
        settings.lowPowerModeBehavior = .reduceActivity

        XCTAssertEqual(settings.effectiveDebounceSeconds(isLowPowerMode: false), 2.0)
        XCTAssertEqual(settings.effectiveIdleRenewalMinutes(isLowPowerMode: false), 14)
        XCTAssertEqual(settings.effectiveDebounceSeconds(isLowPowerMode: true), 8.0)
        XCTAssertEqual(settings.effectiveIdleRenewalMinutes(isLowPowerMode: true), 25)

        settings.debounceSeconds = 9.5
        XCTAssertEqual(settings.effectiveDebounceSeconds(isLowPowerMode: true), 9.5)

        settings.debounceSeconds = 2.0
        settings.lowPowerModeBehavior = .keepNormal
        XCTAssertEqual(settings.effectiveDebounceSeconds(isLowPowerMode: true), 2.0)
        XCTAssertEqual(settings.effectiveIdleRenewalMinutes(isLowPowerMode: true), 14)

        settings.lowPowerModeBehavior = .pauseIdle
        XCTAssertEqual(settings.effectiveDebounceSeconds(isLowPowerMode: true), 2.0)
        XCTAssertEqual(settings.effectiveIdleRenewalMinutes(isLowPowerMode: true), 14)
    }

    func testGmailCategoryFilterQueryAndSummary() {
        let (defaults, _) = makeIsolatedDefaults()
        let settings = AppSettings(defaults: defaults, startUpdateChecks: false)

        // Disabled by default -> nil query
        XCTAssertNil(settings.compiledGmailFilterQuery())
        XCTAssertEqual(settings.activeFilterSummary, "All Inbox Mail")

        // Enabled with default Primary
        settings.filterByGmailCategories = true
        XCTAssertEqual(settings.compiledGmailFilterQuery(), "category:primary")
        XCTAssertEqual(settings.activeFilterSummary, "Primary")

        // Multiple categories combined with OR
        settings.pushCategoryUpdates = true
        XCTAssertEqual(settings.compiledGmailFilterQuery(), "(category:primary OR category:updates)")
        XCTAssertEqual(settings.activeFilterSummary, "Primary, Updates")

        // Multiple categories + Important only
        settings.pushImportantOnly = true
        XCTAssertEqual(settings.compiledGmailFilterQuery(), "(category:primary OR category:updates) is:important")
        XCTAssertEqual(settings.activeFilterSummary, "Primary, Updates (Important only)")

        // Important only with no categories selected
        settings.pushCategoryPrimary = false
        settings.pushCategoryUpdates = false
        XCTAssertEqual(settings.compiledGmailFilterQuery(), "is:important")
        XCTAssertEqual(settings.activeFilterSummary, "Important only")

        // All categories & Important unchecked while filter enabled -> safe fallback to Primary
        settings.pushImportantOnly = false
        XCTAssertEqual(settings.compiledGmailFilterQuery(), "category:primary")
        XCTAssertEqual(settings.activeFilterSummary, "Primary")
    }
}
