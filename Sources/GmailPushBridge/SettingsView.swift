import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var coordinator: BridgeCoordinator
    @ObservedObject var settings: AppSettings
    @ObservedObject private var updateManager = UpdateManager.shared

    @State private var oauthClientSecretInput: String = ""
    @State private var appPasswordInput: String = ""
    @State private var saveFeedback: String?
    @State private var launchAtLogin: Bool = LaunchAgentManager.isEnabled
    @State private var showOAuthSetupGuide: Bool = false

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .none
        df.timeStyle = .medium
        return df
    }()

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                statusBanner
                authGroupBox
                appleMailSection
                timingSection
                updatesSection
                activityLogSection
                sponsorSection
            }
            .padding(18)
        }
        .frame(minWidth: 540, idealWidth: 640, maxWidth: .infinity,
               minHeight: 520, idealHeight: 740, maxHeight: .infinity)
        .sheet(isPresented: $showOAuthSetupGuide) {
            OAuthSetupGuideSheet()
        }
        .onAppear {
            if let existing = KeychainStore.loadAppPassword(for: settings.gmailAddress) {
                appPasswordInput = existing
            }
            if let tokens = KeychainStore.loadOAuthTokens(for: settings.gmailAddress),
               let secret = tokens.clientSecret {
                oauthClientSecretInput = secret
            }
            launchAtLogin = LaunchAgentManager.isEnabled
        }
    }

    private var statusBanner: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.statusSummaryText)
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
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    private var authGroupBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Auth Mode", selection: $settings.authMethod) {
                    Text("Google OAuth 2.0").tag(GmailAuthMethod.oauth2)
                    Text("App Password").tag(GmailAuthMethod.appPassword)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if settings.authMethod == .oauth2 {
                    oauthSectionContent
                } else {
                    appPasswordSectionContent
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label("Gmail Authentication (Stored in Keychain)", systemImage: "key.fill")
                .font(.headline)
        }
    }

    @ViewBuilder
    private var oauthSectionContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Setup Guide helper banner
            HStack(spacing: 10) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Need a Google OAuth Client ID?")
                        .font(.subheadline.weight(.semibold))
                    Text("Takes ~2 minutes to set up your free, private Google Cloud credentials.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Setup Guide") {
                    showOAuthSetupGuide = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    if let url = URL(string: "https://rallendo.github.io/gmail-push-bridge/oauth-setup.html") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .help("Open web guide in browser")
            }
            .padding(10)
            .background(Color.blue.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.blue.opacity(0.2), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Google OAuth Desktop Client ID")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button {
                        showOAuthSetupGuide = true
                    } label: {
                        Label("How to get this?", systemImage: "info.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                }
                HStack(spacing: 8) {
                    TextField("xxx.apps.googleusercontent.com", text: $settings.oauthClientId)
                        .textFieldStyle(.roundedBorder)

                    Button("Import client_secret.json…") {
                        importGoogleClientSecretJSON()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("OAuth Client Secret")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if let url = URL(string: "https://console.cloud.google.com/apis/credentials") {
                        Link("Google Cloud Credentials ↗", destination: url)
                            .font(.caption)
                    }
                }
                SecureField("Desktop Client Secret (from Google Cloud Console)", text: $oauthClientSecretInput)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Gmail Address")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if settings.hasOAuthTokens {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("OAuth Token Saved")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                    }
                }
                TextField("you@gmail.com (auto-filled on sign-in)", text: $settings.gmailAddress)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Button(action: startGoogleOAuthFlow) {
                        HStack(spacing: 6) {
                            if coordinator.isSigningInWithGoogle {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Waiting for Sign-In…")
                            } else {
                                Image(systemName: "safari")
                                Text("Sign in with Google (Browser)")
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(coordinator.isSigningInWithGoogle)

                    if settings.hasOAuthTokens {
                        Button("Connect Now") {
                            coordinator.startMonitoring()
                        }
                        Button("Sign Out") {
                            coordinator.signOutOAuth()
                            oauthClientSecretInput = ""
                            appPasswordInput = ""
                            saveFeedback = "OAuth tokens removed."
                        }
                    }

                    Button("Test Apple Mail Trigger") {
                        coordinator.triggerManualFetch()
                    }
                }

                if let saveFeedback {
                    Text(saveFeedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private var appPasswordSectionContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Gmail Address")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if settings.hasAppPassword {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("App Password Saved")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                    }
                }
                TextField("you@gmail.com", text: $settings.gmailAddress)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Google App Password")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if let url = URL(string: "https://myaccount.google.com/apppasswords") {
                        Link("Get App Password ↗", destination: url)
                            .font(.caption)
                    }
                }
                SecureField("16-character Google App Password", text: $appPasswordInput)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Button("Save & Connect") {
                        saveAppPasswordAndConnect()
                    }
                    .buttonStyle(.borderedProminent)

                    if settings.hasAppPassword {
                        Button("Remove App Password") {
                            coordinator.removeAppPassword()
                            appPasswordInput = ""
                            saveFeedback = "App Password removed."
                        }
                    }

                    Button("Test Apple Mail Trigger") {
                        coordinator.triggerManualFetch()
                    }
                }

                if let saveFeedback {
                    Text(saveFeedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var appleMailSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Apple Mail Account Name")
                        .font(.subheadline.weight(.medium))
                    HStack(spacing: 8) {
                        TextField("e.g. Google or Gmail", text: $settings.appleMailAccountName)
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
                }

                Toggle("Fallback to checking all accounts if account name isn't found", isOn: $settings.checkAllAccountsFallback)
                Toggle("Also run 'synchronize' on account (syncs flags & folders)", isOn: $settings.runSynchronizeInAdditionToCheck)
                Toggle("Two-way read & archive sync (sync on EXPUNGE & flag changes)", isOn: $settings.syncReadAndArchiveChanges)
                Toggle("Automatically pause IMAP IDLE when Apple Mail is closed", isOn: $settings.autoDisconnectWhenMailClosed)
                    .onChange(of: settings.autoDisconnectWhenMailClosed) { newValue in
                        coordinator.handleAutoDisconnectSettingChanged(newValue)
                    }
            }
            .padding(.vertical, 4)
        } label: {
            Label("Apple Mail Target", systemImage: "envelope.fill")
                .font(.headline)
        }
    }

    private var timingSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 24) {
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
                        guard newValue != LaunchAgentManager.isEnabled else { return }
                        do {
                            try LaunchAgentManager.setEnabled(newValue)
                            coordinator.appendLog(newValue ? "Enabled LaunchAgent at login." : "Disabled LaunchAgent at login.")
                        } catch {
                            launchAtLogin = LaunchAgentManager.isEnabled
                            coordinator.appendLog("Failed to update LaunchAgent: \(error.localizedDescription)")
                            let alert = NSAlert()
                            alert.messageText = "Cannot Enable Start at Login"
                            alert.informativeText = error.localizedDescription
                            alert.alertStyle = .warning
                            alert.addButton(withTitle: "OK")
                            alert.runModal()
                        }
                    }
            }
            .padding(.vertical, 4)
        } label: {
            Label("Timing & Startup", systemImage: "clock.fill")
                .font(.headline)
        }
    }

    private var updatesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gmail Push Bridge v\(updateManager.currentVersion) (Build \(updateManager.currentBuild))")
                            .font(.subheadline.weight(.semibold))

                        if let lastChecked = updateManager.lastCheckedDate {
                            Text("Last checked: \(Self.timeFormatter.string(from: lastChecked))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Not checked yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if updateManager.state.isChecking {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking…")
                                .font(.caption)
                        }
                    } else {
                        Button("Check for Updates Now") {
                            updateManager.checkForUpdates(isUserInitiated: true)
                        }
                        .disabled(updateManager.state.isDownloading)
                    }
                }

                Toggle("Automatically check for updates daily", isOn: $settings.automaticallyCheckForUpdates)

                if let update = updateManager.availableUpdate {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Label("Update Available: \(update.tagName)", systemImage: "sparkles")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.blue)

                            Spacer()

                            if update.assetSize > 0 {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(update.assetSize), countStyle: .file))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if !update.notes.isEmpty {
                            ScrollView(.vertical) {
                                Text(update.notes)
                                    .font(.caption)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 90)
                            .padding(8)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                            )
                        }

                        if case .downloading(let progress) = updateManager.state {
                            VStack(alignment: .leading, spacing: 4) {
                                ProgressView(value: progress, total: 1.0)
                                HStack {
                                    Text(updateManager.statusMessage ?? "Downloading…")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Cancel") {
                                        updateManager.cancelDownload()
                                    }
                                    .buttonStyle(.plain)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                }
                            }
                        } else if case .installing = updateManager.state {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Installing update and relaunching…")
                                    .font(.caption)
                            }
                        } else {
                            HStack(spacing: 10) {
                                Button("Download & Install Update") {
                                    updateManager.downloadAndInstallUpdate(update)
                                }
                                .buttonStyle(.borderedProminent)

                                Button("View on GitHub ↗") {
                                    NSWorkspace.shared.open(update.htmlURL)
                                }
                            }
                        }
                    }
                    .padding(10)
                    .background(Color.blue.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.blue.opacity(0.25), lineWidth: 1)
                    )
                } else if case .failed(let err) = updateManager.state {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label("Software Updates", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                .font(.headline)
        }
    }

    private var activityLogSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Spacer()
                    Text("Total Pushes: \(coordinator.totalPushesTriggered)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollViewReader { proxy in
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
                                .id(entry.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .frame(height: 120)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                    .onChange(of: coordinator.activityLog.count) { _ in
                        if let last = coordinator.activityLog.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label("Live Activity Log", systemImage: "terminal.fill")
                .font(.headline)
        }
    }

    private var sponsorSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "heart.fill")
                .foregroundStyle(.pink)
                .font(.subheadline)

            VStack(alignment: .leading, spacing: 2) {
                Text("Enjoying Gmail Push Bridge?")
                    .font(.caption.weight(.medium))
                Text("Support ongoing development or buy the developer a coffee.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                if let url = URL(string: "https://github.com/sponsors/rallendo") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 4) {
                    Text("☕️ Sponsor on GitHub")
                    Image(systemName: "arrow.up.forward.app")
                        .font(.caption2)
                }
            }
            .buttonStyle(.link)
            .font(.caption.weight(.semibold))
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusColor: Color {
        if coordinator.isPaused { return .orange }
        if coordinator.isWaitingForMail { return .blue.opacity(0.75) }
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

    private func startGoogleOAuthFlow() {
        saveFeedback = nil
        Task {
            do {
                try await coordinator.signInWithGoogle(clientSecret: oauthClientSecretInput)
                saveFeedback = "Signed in as \(settings.gmailAddress) ✓"
            } catch {
                saveFeedback = error.localizedDescription
                coordinator.appendLog("Google OAuth sign-in error: \(error.localizedDescription)")
            }
        }
    }

    private func importGoogleClientSecretJSON() {
        let panel = NSOpenPanel()
        panel.title = "Select Google OAuth Desktop client_secret.json"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        struct GoogleCredentialsFile: Decodable {
            struct ClientInfo: Decodable {
                let client_id: String
                let client_secret: String?
            }
            let installed: ClientInfo?
            let web: ClientInfo?
        }

        do {
            let data = try Data(contentsOf: url)
            let parsed = try JSONDecoder().decode(GoogleCredentialsFile.self, from: data)
            if let info = parsed.installed ?? parsed.web {
                settings.oauthClientId = info.client_id
                if let secret = info.client_secret {
                    oauthClientSecretInput = secret
                }
                saveFeedback = "Imported OAuth Client ID ✓"
                coordinator.appendLog("Imported Google OAuth Client ID from \(url.lastPathComponent).")
            } else {
                saveFeedback = "Invalid client_secret.json format."
            }
        } catch {
            saveFeedback = "Failed to parse JSON: \(error.localizedDescription)"
        }
    }

    private func saveAppPasswordAndConnect() {
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
            settings.objectWillChange.send()
            saveFeedback = "Saved to Keychain ✓"
            coordinator.startMonitoring()
        } catch {
            saveFeedback = error.localizedDescription
            coordinator.appendLog("Keychain save failed: \(error.localizedDescription)")
        }
    }
}

struct OAuthSetupGuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Google OAuth Setup Guide")
                        .font(.headline)
                    Text("Create your free private Desktop Client ID in under 2 minutes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(Color.secondary.opacity(0.08))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    guideStep(
                        number: "1",
                        title: "Create a Google Cloud Project",
                        description: "Name it 'Gmail Push Bridge' (leave Organization as 'No organization').",
                        url: "https://console.cloud.google.com/projectcreate",
                        buttonTitle: "Open New Project Page ↗"
                    )

                    guideStep(
                        number: "2",
                        title: "Enable the Gmail API",
                        description: "Select your project in the top bar, then click Enable.",
                        url: "https://console.cloud.google.com/apis/library/gmail.googleapis.com",
                        buttonTitle: "Open Gmail API Library ↗"
                    )

                    guideStep(
                        number: "3",
                        title: "Configure OAuth Consent Screen",
                        description: "Choose 'External' → fill in your email → under 'Test users' add your Gmail address → leave status as 'Testing'.",
                        url: "https://console.cloud.google.com/apis/credentials/consent",
                        buttonTitle: "Open Consent Screen ↗"
                    )

                    guideStep(
                        number: "4",
                        title: "Create Desktop OAuth Credentials",
                        description: "Click '+ Create Credentials' → 'OAuth client ID' → choose 'Desktop app' → click 'Create' → Download JSON.",
                        url: "https://console.cloud.google.com/apis/credentials",
                        buttonTitle: "Open Credentials Dashboard ↗"
                    )

                    guideStep(
                        number: "5",
                        title: "Import into Gmail Push Bridge",
                        description: "Click 'Import client_secret.json…' in Settings, then click 'Sign in with Google'. Click 'Advanced → Go to Gmail Push Bridge (unsafe)' to approve your private app.",
                        url: nil,
                        buttonTitle: nil
                    )
                }
                .padding()
            }

            Divider()

            HStack {
                Button("Open Web Guide in Browser ↗") {
                    if let url = URL(string: "https://rallendo.github.io/gmail-push-bridge/oauth-setup.html") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)

                Spacer()

                Button("Close") {
                    dismiss()
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.05))
        }
        .frame(width: 530, height: 570)
    }

    private func guideStep(
        number: String,
        title: String,
        description: String,
        url: String?,
        buttonTitle: String?
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.blue)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let urlString = url, let buttonTitle = buttonTitle, let targetUrl = URL(string: urlString) {
                    Button(buttonTitle) {
                        NSWorkspace.shared.open(targetUrl)
                    }
                    .buttonStyle(.link)
                    .font(.caption.weight(.medium))
                    .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
