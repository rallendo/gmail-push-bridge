import XCTest
@testable import GmailPushBridge

final class SystemAndBridgeTests: XCTestCase {
    func testAppleMailBridgeSanitizeAccountName() {
        XCTAssertEqual(AppleMailBridge.sanitizeAccountName("  Google  "), "Google")
        XCTAssertEqual(AppleMailBridge.sanitizeAccountName("Work\r\n\0\u{7F} Mail"), "Work Mail")
        XCTAssertEqual(AppleMailBridge.sanitizeAccountName("Personal (Gmail)"), "Personal (Gmail)")
        XCTAssertEqual(AppleMailBridge.sanitizeAccountName("   \t\n  "), "")
    }

    func testLaunchAgentApprovedPaths() throws {
        XCTAssertTrue(LaunchAgentManager.isApprovedApplicationPath("/Applications/GmailPushBridge.app"))

        let userAppsBundle = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications")
            .appendingPathComponent("GmailPushBridge.app")
            .path
        XCTAssertTrue(LaunchAgentManager.isApprovedApplicationPath(userAppsBundle))

        XCTAssertFalse(LaunchAgentManager.isApprovedApplicationPath("/tmp/GmailPushBridge.app"))
        XCTAssertFalse(LaunchAgentManager.isApprovedApplicationPath("/Applications/../tmp/GmailPushBridge.app"))

        let downloadsBundle = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
            .appendingPathComponent("GmailPushBridge.app")
            .path
        XCTAssertFalse(LaunchAgentManager.isApprovedApplicationPath(downloadsBundle))

        let tempAppURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestApp-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: tempAppURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempAppURL)
        }
        XCTAssertFalse(LaunchAgentManager.isApprovedApplicationLocation(bundleURL: tempAppURL))
        XCTAssertFalse(LaunchAgentManager.isApprovedApplicationLocation(bundleURL: URL(fileURLWithPath: "/Applications/NotAnApp.txt")))
    }

    @MainActor
    func testBridgeCoordinatorStatusIconsLoggingAndEvents() {
        let suiteName = "com.gmailpushbridge.coordinator.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(defaults: defaults, startUpdateChecks: false)
        let coordinator = BridgeCoordinator(settings: settings, enableBackgroundMonitors: false)

        // Initial state
        XCTAssertEqual(coordinator.connectionState, .disconnected)
        XCTAssertEqual(coordinator.statusSummaryText, "Disconnected")
        XCTAssertEqual(coordinator.menuBarIconName, "envelope")

        // State updates via handleIMAPEvent
        coordinator.handleIMAPEvent(.stateChanged(.connecting))
        XCTAssertEqual(coordinator.statusSummaryText, "Connecting to Gmail IMAP…")
        XCTAssertEqual(coordinator.menuBarIconName, "arrow.triangle.2.circlepath.circle")

        coordinator.handleIMAPEvent(.stateChanged(.authenticating))
        XCTAssertEqual(coordinator.statusSummaryText, "Authenticating…")
        XCTAssertEqual(coordinator.menuBarIconName, "arrow.triangle.2.circlepath.circle")

        coordinator.handleIMAPEvent(.stateChanged(.selectingMailbox("INBOX")))
        XCTAssertEqual(coordinator.statusSummaryText, "Selecting INBOX…")
        XCTAssertEqual(coordinator.menuBarIconName, "arrow.triangle.2.circlepath.circle")

        coordinator.handleIMAPEvent(.stateChanged(.reconnecting(attempt: 1, delaySeconds: 2)))
        XCTAssertEqual(coordinator.statusSummaryText, "Reconnecting (#1 in 2s)…")
        XCTAssertEqual(coordinator.menuBarIconName, "arrow.triangle.2.circlepath.circle")

        coordinator.handleIMAPEvent(.stateChanged(.idling(mailbox: "INBOX", existsCount: 3)))
        XCTAssertEqual(coordinator.statusSummaryText, "Connected • IDLE on INBOX (3 msgs)")
        XCTAssertEqual(coordinator.menuBarIconName, "bolt.horizontal.circle.fill")

        coordinator.handleIMAPEvent(.stateChanged(.authFailed("bad")))
        XCTAssertEqual(coordinator.statusSummaryText, "Auth Failed: bad")
        XCTAssertEqual(coordinator.menuBarIconName, "exclamationmark.triangle.fill")

        coordinator.handleIMAPEvent(.stateChanged(.error("network dropped")))
        XCTAssertEqual(coordinator.statusSummaryText, "Error: network dropped")
        XCTAssertEqual(coordinator.menuBarIconName, "exclamationmark.triangle.fill")

        // Pause overrides state summary & icon
        coordinator.pauseMonitoring()
        XCTAssertTrue(coordinator.isPaused)
        XCTAssertEqual(coordinator.statusSummaryText, "Paused")
        XCTAssertEqual(coordinator.menuBarIconName, "envelope.badge.fill")

        // Log event handling and 60-entry buffer cap
        coordinator.handleIMAPEvent(.log("Test IMAP log"))
        XCTAssertEqual(coordinator.activityLog.first?.message, "Test IMAP log")

        for idx in 1...70 {
            coordinator.appendLog("Entry \(idx)")
        }
        XCTAssertEqual(coordinator.activityLog.count, 60)
        XCTAssertEqual(coordinator.activityLog.first?.message, "Entry 70")
        XCTAssertEqual(coordinator.activityLog.last?.message, "Entry 11")
    }

    @MainActor
    func testBridgeCoordinatorLowPowerModeTransitions() {
        let suiteName = "com.gmailpushbridge.lowpower.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(defaults: defaults, startUpdateChecks: false)
        let coordinator = BridgeCoordinator(settings: settings, enableBackgroundMonitors: false)

        XCTAssertFalse(coordinator.isLowPowerModeEnabled)
        XCTAssertFalse(coordinator.isPausedForLowPowerMode)

        coordinator.handleIMAPEvent(.stateChanged(.idling(mailbox: "INBOX", existsCount: 3)))
        XCTAssertEqual(coordinator.statusSummaryText, "Connected • IDLE on INBOX (3 msgs)")

        // .reduceActivity appends "• Low Power" while idling
        coordinator.handleLowPowerModeChanged(true)
        XCTAssertTrue(coordinator.isLowPowerModeEnabled)
        XCTAssertFalse(coordinator.isPausedForLowPowerMode)
        XCTAssertEqual(coordinator.statusSummaryText, "Connected • IDLE on INBOX (3 msgs) • Low Power")
        XCTAssertEqual(coordinator.menuBarIconName, "bolt.horizontal.circle.fill")

        // .keepNormal removes "• Low Power" suffix
        settings.lowPowerModeBehavior = .keepNormal
        coordinator.handleLowPowerModeBehaviorChanged(.keepNormal)
        XCTAssertEqual(coordinator.statusSummaryText, "Connected • IDLE on INBOX (3 msgs)")

        // Switching to .pauseIdle while Low Power Mode is active enters standby
        settings.lowPowerModeBehavior = .pauseIdle
        coordinator.handleLowPowerModeBehaviorChanged(.pauseIdle)
        XCTAssertTrue(coordinator.isPausedForLowPowerMode)
        XCTAssertEqual(coordinator.connectionState, .disconnected)
        XCTAssertEqual(coordinator.statusSummaryText, "Standby (Low Power Mode)")
        XCTAssertEqual(coordinator.menuBarIconName, "bolt.slash.circle")

        // Disabling Low Power Mode clears Low Power standby
        coordinator.handleLowPowerModeChanged(false)
        XCTAssertFalse(coordinator.isLowPowerModeEnabled)
        XCTAssertFalse(coordinator.isPausedForLowPowerMode)
        XCTAssertEqual(coordinator.statusSummaryText, "Disconnected")
        XCTAssertEqual(coordinator.menuBarIconName, "envelope")

        // Enabling Low Power Mode directly when .pauseIdle is configured enters standby
        coordinator.handleLowPowerModeChanged(true)
        XCTAssertTrue(coordinator.isPausedForLowPowerMode)
        XCTAssertEqual(coordinator.statusSummaryText, "Standby (Low Power Mode)")
        XCTAssertEqual(coordinator.menuBarIconName, "bolt.slash.circle")

        coordinator.handleLowPowerModeChanged(false)
        XCTAssertFalse(coordinator.isPausedForLowPowerMode)
    }

    @MainActor
    func testBridgeCoordinatorSleepAndWakeTransitions() {
        let suiteName = "com.gmailpushbridge.sleepwake.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(defaults: defaults, startUpdateChecks: false)
        let coordinator = BridgeCoordinator(settings: settings, enableBackgroundMonitors: false)

        XCTAssertFalse(coordinator.isSleeping)
        coordinator.handleIMAPEvent(.stateChanged(.idling(mailbox: "INBOX", existsCount: 3)))
        XCTAssertEqual(coordinator.connectionState, .idling(mailbox: "INBOX", existsCount: 3))

        coordinator.handleSystemSleep()
        XCTAssertTrue(coordinator.isSleeping)
        XCTAssertEqual(coordinator.connectionState, .disconnected)

        coordinator.handleSystemWake()
        XCTAssertFalse(coordinator.isSleeping)
    }

    @MainActor
    func testBridgeCoordinatorPushFilterEventsAndFallback() {
        let suiteName = "com.gmailpushbridge.filter.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(defaults: defaults, startUpdateChecks: false)
        let coordinator = BridgeCoordinator(settings: settings, enableBackgroundMonitors: false)

        XCTAssertEqual(coordinator.totalPushesFilteredOut, 0)

        coordinator.handleIMAPEvent(.filteredMailSkipped(existsCount: 42, query: "category:primary"))
        XCTAssertEqual(coordinator.totalPushesFilteredOut, 1)
        XCTAssertEqual(coordinator.totalPushesTriggered, 0)
        XCTAssertEqual(coordinator.lastTriggerSummary, "Filtered out (* 42 EXISTS — non-matching category)")

        // Enabling filter with all categories & Important unchecked auto-restores Primary
        settings.filterByGmailCategories = true
        settings.pushCategoryPrimary = false
        settings.pushCategoryUpdates = false
        settings.pushCategorySocial = false
        settings.pushCategoryPromotions = false
        settings.pushCategoryForums = false
        settings.pushImportantOnly = false

        coordinator.handlePushFilterSettingsChanged()
        XCTAssertTrue(settings.pushCategoryPrimary)
        XCTAssertEqual(settings.compiledGmailFilterQuery(), "category:primary")
        XCTAssertTrue(coordinator.activityLog.first?.message.contains("category:primary") == true)

        // Disabling filter logs disabled state
        settings.filterByGmailCategories = false
        coordinator.handlePushFilterSettingsChanged()
        XCTAssertNil(settings.compiledGmailFilterQuery())
        XCTAssertTrue(coordinator.activityLog.first?.message.contains("disabled") == true)
    }
}
