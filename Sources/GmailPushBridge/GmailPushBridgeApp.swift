import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(coordinator: BridgeCoordinator) {
        if let existing = window {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = SettingsView(coordinator: coordinator, settings: coordinator.settings)
        let hostingController = NSHostingController(rootView: contentView)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Gmail Push Bridge — Settings & Status"
        win.contentViewController = hostingController
        win.center()
        win.isReleasedWhenClosed = false

        self.window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide Dock icon so it runs strictly as a Menu Bar utility
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct GmailPushBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = BridgeCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(coordinator: coordinator)
        } label: {
            Image(systemName: coordinator.menuBarIconName)
                .help("Gmail Push Bridge: \(coordinator.connectionState.summaryText)")
        }
    }
}

struct MenuBarContentView: View {
    @ObservedObject var coordinator: BridgeCoordinator

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .none
        df.timeStyle = .short
        return df
    }()

    var body: some View {
        Text(coordinator.isPaused ? "Status: Paused" : coordinator.connectionState.summaryText)
        Text("Last Push: \(coordinator.lastTriggerSummary)")

        Divider()

        Button("Trigger Apple Mail Fetch Now") {
            coordinator.triggerManualFetch()
        }
        .keyboardShortcut("r", modifiers: [.command])

        Button("Reconnect Gmail IDLE") {
            coordinator.reconnectNow()
        }

        Button(coordinator.isPaused ? "Resume Monitoring" : "Pause Monitoring") {
            coordinator.togglePause()
        }

        Divider()

        Menu("Recent Activity (\(coordinator.activityLog.count))") {
            if coordinator.activityLog.isEmpty {
                Text("No events yet")
            } else {
                ForEach(coordinator.activityLog.prefix(12)) { entry in
                    Text("\(Self.timeFormatter.string(from: entry.timestamp)) — \(entry.message)")
                }
            }
        }

        Button("Settings & Credentials…") {
            SettingsWindowController.shared.show(coordinator: coordinator)
        }
        .keyboardShortcut(",", modifiers: [.command])

        Divider()

        Button("Quit Gmail Push Bridge") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: [.command])
    }
}
