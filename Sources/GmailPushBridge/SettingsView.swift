import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var coordinator: BridgeCoordinator
    @ObservedObject var settings: AppSettings

    @State private var appPasswordInput: String = ""
    @State private var saveFeedback: String?
    @State private var launchAtLogin: Bool = LaunchAgentManager.isEnabled

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .none
        df.timeStyle = .medium
        return df
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusBanner

            Form {
                Section {
                    TextField("Gmail Address (e.g. you@gmail.com)", text: $settings.gmailAddress)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        SecureField("16-char Google App Password", text: $appPasswordInput)
                            .textFieldStyle(.roundedBorder)

                        if let url = URL(string: "https://myaccount.google.com/apppasswords") {
                            Link("Get App Password ↗", destination: url)
                                .font(.caption)
                        }
                    }

                    HStack(spacing: 12) {
                        Button("Save & Connect") {
                            saveCredentialsAndConnect()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Test Apple Mail Trigger") {
                            coordinator.triggerManualFetch()
                        }

                        if let saveFeedback {
                            Text(saveFeedback)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Gmail IMAP IDLE Credentials (Stored in macOS Keychain)")
                        .font(.headline)
                }

                Divider()

                Section {
                    HStack {
                        TextField("Apple Mail Account Name", text: $settings.appleMailAccountName)
                            .textFieldStyle(.roundedBorder)

                        if !coordinator.detectedMailAccounts.isEmpty {
                            Menu("Pick Account") {
                                ForEach(coordinator.detectedMailAccounts, id: \.self) { name in
                                    Button(name) {
                                        settings.appleMailAccountName = name
                                    }
                                }
                            }
                            .fixedSize()
                        }

                        Button("Detect from Mail") {
                            coordinator.refreshMailAccounts()
                        }
                    }

                    Toggle("Fallback to checking all accounts if account name isn't found", isOn: $settings.checkAllAccountsFallback)
                    Toggle("Also run 'synchronize' on account (syncs flags & folders)", isOn: $settings.runSynchronizeInAdditionToCheck)
                } header: {
                    Text("Apple Mail Target")
                        .font(.headline)
                }

                Divider()

                Section {
                    HStack(spacing: 20) {
                        Stepper(
                            "Debounce: \(String(format: "%.1fs", settings.debounceSeconds))",
                            value: $settings.debounceSeconds,
                            in: 0.5...10.0,
                            step: 0.5
                        )

                        Stepper(
                            "IDLE Refresh: \(settings.idleRenewalMinutes) min",
                            value: $settings.idleRenewalMinutes,
                            in: 5...25,
                            step: 1
                        )
                    }

                    Toggle("Start automatically at login (LaunchAgent)", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { newValue in
                            do {
                                try LaunchAgentManager.setEnabled(newValue)
                                coordinator.appendLog(newValue ? "Enabled LaunchAgent at login." : "Disabled LaunchAgent at login.")
                            } catch {
                                coordinator.appendLog("Failed to update LaunchAgent: \(error.localizedDescription)")
                            }
                        }
                } header: {
                    Text("Timing & Startup")
                        .font(.headline)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Live Activity Log")
                        .font(.headline)
                    Spacer()
                    Text("Total Pushes: \(coordinator.totalPushesTriggered)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(coordinator.activityLog) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(Self.timeFormatter.string(from: entry.timestamp))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(entry.message)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(height: 140)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
            }
        }
        .padding(20)
        .frame(width: 580)
        .onAppear {
            if let existing = KeychainStore.loadAppPassword(for: settings.gmailAddress) {
                appPasswordInput = existing
            }
            launchAtLogin = LaunchAgentManager.isEnabled
        }
    }

    private var statusBanner: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.isPaused ? "Paused" : coordinator.connectionState.summaryText)
                    .font(.subheadline.weight(.semibold))
                Text(coordinator.lastTriggerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if coordinator.isPaused {
                Button("Resume") { coordinator.startMonitoring() }
            } else if coordinator.connectionState.isIdling {
                Button("Pause") { coordinator.pauseMonitoring() }
            } else {
                Button("Reconnect") { coordinator.reconnectNow() }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusColor: Color {
        if coordinator.isPaused { return .orange }
        switch coordinator.connectionState {
        case .idling:
            return .green
        case .connecting, .authenticating, .selectingMailbox, .reconnecting:
            return .yellow
        case .authFailed, .error:
            return .red
        case .disconnected:
            return .gray
        }
    }

    private func saveCredentialsAndConnect() {
        let email = settings.gmailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else {
            saveFeedback = "Enter your Gmail address first."
            return
        }
        let cleanedPassword = appPasswordInput
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedPassword.isEmpty else {
            saveFeedback = "Enter your 16-character App Password."
            return
        }

        do {
            try KeychainStore.saveAppPassword(cleanedPassword, for: email)
            saveFeedback = "Saved to Keychain ✓"
            coordinator.startMonitoring()
        } catch {
            saveFeedback = error.localizedDescription
            coordinator.appendLog("Keychain save failed: \(error.localizedDescription)")
        }
    }
}
