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
}
