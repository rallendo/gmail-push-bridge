import AppKit
import Foundation

@MainActor
final class UpdateManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = UpdateManager()

    // GitHub repository configuration
    static let repositoryOwner = "rallendo"
    static let repositoryName = "gmail-push-bridge"
    static let apiEndpoint = URL(string: "https://api.github.com/repos/\(repositoryOwner)/\(repositoryName)/releases/latest")!

    enum State: Equatable {
        case idle
        case checking
        case upToDate(version: String)
        case updateAvailable(AppRelease)
        case downloading(progress: Double)
        case installing
        case readyToRelaunch
        case failed(String)

        var isChecking: Bool {
            if case .checking = self { return true }
            return false
        }

        var isDownloading: Bool {
            if case .downloading = self { return true }
            return false
        }
    }

    struct AppRelease: Identifiable, Sendable, Equatable {
        let id: String
        let tagName: String
        let version: String
        let title: String
        let notes: String
        let htmlURL: URL
        let downloadURL: URL?
        let publishedAt: Date?
        let assetSize: Int
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastCheckedDate: Date?
    @Published private(set) var availableUpdate: AppRelease?
    @Published private(set) var statusMessage: String?

    private var downloadTask: URLSessionDownloadTask?
    private lazy var downloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue.main)
    }()

    private var periodicTimer: Timer?
    private var isUserInitiatedCheck: Bool = false

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    override init() {
        super.init()
        let lastTimestamp = UserDefaults.standard.double(forKey: "lastUpdateCheckTimestamp")
        if lastTimestamp > 0 {
            self.lastCheckedDate = Date(timeIntervalSince1970: lastTimestamp)
        }
    }

    func startPeriodicChecks(settings: AppSettings) {
        stopPeriodicChecks()

        guard settings.automaticallyCheckForUpdates else { return }

        // Initial check with a gentle delay after app startup
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000) // 6 seconds
            guard let self = self, settings.automaticallyCheckForUpdates else { return }
            self.checkForUpdates(isUserInitiated: false)
        }

        // Check every 24 hours (86,400 seconds)
        periodicTimer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, settings.automaticallyCheckForUpdates else { return }
                self.checkForUpdates(isUserInitiated: false)
            }
        }
    }

    func stopPeriodicChecks() {
        periodicTimer?.invalidate()
        periodicTimer = nil
    }

    func checkForUpdates(isUserInitiated: Bool = true) {
        guard !state.isChecking && !state.isDownloading else { return }

        self.isUserInitiatedCheck = isUserInitiated
        self.state = .checking
        self.statusMessage = "Checking for updates…"

        Task {
            do {
                var request = URLRequest(url: Self.apiEndpoint)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("GmailPushBridge/\(currentVersion)", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 15

                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw UpdateError.networkError("Invalid server response.")
                }

                if httpResponse.statusCode == 404 {
                    // No releases published yet
                    handleNoReleasesFound()
                    return
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    throw UpdateError.networkError("GitHub API returned status \(httpResponse.statusCode).")
                }

                let releaseDTO = try JSONDecoder().decode(GitHubReleaseDTO.self, from: data)
                handleReleaseFound(releaseDTO)
            } catch {
                handleCheckFailure(error)
            }
        }
    }

    private func handleNoReleasesFound() {
        recordCheckTimestamp()
        self.availableUpdate = nil
        self.state = .upToDate(version: currentVersion)
        self.statusMessage = "You're on the latest version (\(currentVersion))."

        if isUserInitiatedCheck {
            showUpToDateAlert()
        }
    }

    private func handleReleaseFound(_ release: GitHubReleaseDTO) {
        recordCheckTimestamp()

        let remoteTag = release.tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteVersion = remoteTag.hasPrefix("v") || remoteTag.hasPrefix("V")
            ? String(remoteTag.dropFirst())
            : remoteTag

        let hasNewVersion = Self.isVersion(remoteVersion, newerThan: currentVersion)

        if hasNewVersion {
            let zipAsset = release.assets.first(where: {
                $0.name.lowercased().hasSuffix(".zip")
            })

            let downloadURL = zipAsset.flatMap { URL(string: $0.browserDownloadUrl) }
            let htmlURL = URL(string: release.htmlUrl) ?? URL(string: "https://github.com/\(Self.repositoryOwner)/\(Self.repositoryName)/releases")!

            let appRelease = AppRelease(
                id: String(release.id ?? 0),
                tagName: remoteTag,
                version: remoteVersion,
                title: release.name ?? remoteTag,
                notes: release.body ?? "No release notes provided.",
                htmlURL: htmlURL,
                downloadURL: downloadURL,
                publishedAt: release.publishedAt.flatMap { ISO8601DateFormatter().date(from: $0) },
                assetSize: zipAsset?.size ?? 0
            )

            self.availableUpdate = appRelease
            self.state = .updateAvailable(appRelease)
            self.statusMessage = "Update available: \(remoteTag)"

            if isUserInitiatedCheck {
                showUpdateAvailableAlert(appRelease)
            }
        } else {
            self.availableUpdate = nil
            self.state = .upToDate(version: currentVersion)
            self.statusMessage = "You're on the latest version (\(currentVersion))."

            if isUserInitiatedCheck {
                showUpToDateAlert()
            }
        }
    }

    private func handleCheckFailure(_ error: Error) {
        let msg = (error as? UpdateError)?.localizedDescription ?? error.localizedDescription
        self.state = .failed(msg)
        self.statusMessage = "Update check failed: \(msg)"

        if isUserInitiatedCheck {
            let alert = NSAlert()
            alert.messageText = "Update Check Failed"
            alert.informativeText = "Unable to check for updates: \(msg)\n\nPlease check your internet connection or try again later."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func recordCheckTimestamp() {
        let now = Date()
        self.lastCheckedDate = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "lastUpdateCheckTimestamp")
    }

    // MARK: - Download & Install

    func downloadAndInstallUpdate(_ release: AppRelease) {
        guard let downloadURL = release.downloadURL else {
            // If there's no direct zip asset, open the release page in the browser
            NSWorkspace.shared.open(release.htmlURL)
            return
        }

        guard !state.isDownloading else { return }

        self.state = .downloading(progress: 0.0)
        self.statusMessage = "Downloading update \(release.tagName)…"

        let request = URLRequest(url: downloadURL)
        downloadTask = downloadSession.downloadTask(with: request)
        downloadTask?.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        if let update = availableUpdate {
            self.state = .updateAvailable(update)
            self.statusMessage = "Download canceled."
        } else {
            self.state = .idle
            self.statusMessage = nil
        }
    }

    // MARK: - URLSessionDownloadDelegate

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let progress: Double
        if totalBytesExpectedToWrite > 0 {
            progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        } else {
            progress = 0.5
        }

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.state = .downloading(progress: progress)
            let percent = Int(progress * 100)
            self.statusMessage = "Downloading update: \(percent)%"
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // Don't report error if task was explicitly cancelled
                if (error as NSError).code == NSURLErrorCancelled { return }
                self.state = .failed("Download failed: \(error.localizedDescription)")
                self.statusMessage = "Download failed."
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Move downloaded file to temporary path before URLSession removes it
        let tempZip = FileManager.default.temporaryDirectory.appendingPathComponent("GmailPushBridge-Update-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: tempZip)
            Task { @MainActor [weak self] in
                self?.installUpdate(from: tempZip)
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.state = .failed("Could not stage download: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Installation Execution

    private func installUpdate(from zipURL: URL) {
        self.state = .installing
        self.statusMessage = "Extracting & preparing update…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("GmailPushBridge-Staging-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

                // 1. Extract zip with ditto (preserves symlinks, code signatures, and permissions)
                let ditto = Process()
                ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                ditto.arguments = ["-xk", zipURL.path, tempDir.path]
                try ditto.run()
                ditto.waitUntilExit()

                guard ditto.terminationStatus == 0 else {
                    throw UpdateError.installFailed("Failed to unpack update archive.")
                }

                // 2. Locate GmailPushBridge.app inside extracted files
                let fileManager = FileManager.default
                let topLevelItems = try fileManager.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)

                var appBundleURL: URL?
                if let directApp = topLevelItems.first(where: { $0.pathExtension == "app" }) {
                    appBundleURL = directApp
                } else {
                    for item in topLevelItems {
                        var isDir: ObjCBool = false
                        if fileManager.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                            let subItems = (try? fileManager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
                            if let subApp = subItems.first(where: { $0.pathExtension == "app" }) {
                                appBundleURL = subApp
                                break
                            }
                        }
                    }
                }

                guard let extractedApp = appBundleURL else {
                    throw UpdateError.installFailed("Downloaded update does not contain an application bundle.")
                }

                // 3. Remove macOS Quarantine flag so Gatekeeper allows it to launch smoothly
                let xattr = Process()
                xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                xattr.arguments = ["-r", "-d", "com.apple.quarantine", extractedApp.path]
                try? xattr.run()
                xattr.waitUntilExit()

                // Clean up zip file
                try? fileManager.removeItem(at: zipURL)

                // Determine target installation destination
                let currentBundle = Bundle.main.bundleURL
                let destinationPath: String
                if currentBundle.pathExtension == "app" {
                    destinationPath = currentBundle.path
                } else if fileManager.fileExists(atPath: "/Applications/Gmail Push Bridge.app") {
                    destinationPath = "/Applications/Gmail Push Bridge.app"
                } else {
                    destinationPath = "/Applications/GmailPushBridge.app"
                }

                // 4. Create and launch self-terminating update installer script
                let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("install-gmailpushbridge-\(UUID().uuidString).sh")
                let installerScript = """
                #!/bin/bash
                set -e
                PID="\(ProcessInfo.processInfo.processIdentifier)"
                SRC="\(extractedApp.path)"
                DST="\(destinationPath)"
                STAGING_DIR="\(tempDir.path)"

                # Wait for running app process to terminate
                for i in {1..100}; do
                    if ! kill -0 "$PID" 2>/dev/null; then
                        break
                    fi
                    sleep 0.1
                done

                # Replace app bundle
                if rm -rf "$DST" 2>/dev/null && cp -R "$SRC" "$DST" 2>/dev/null; then
                    :
                else
                    # If standard write fails (e.g., system /Applications requires elevated rights), use AppleScript
                    osascript -e "do shell script \\"rm -rf '$DST' && cp -R '$SRC' '$DST'\\" with administrator privileges"
                fi

                # Clean up staging directory
                rm -rf "$STAGING_DIR"
                rm -f "$0"

                # Relaunch updated application
                open "$DST"
                """

                try installerScript.write(to: scriptURL, atomically: true, encoding: .utf8)
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

                let runner = Process()
                runner.executableURL = URL(fileURLWithPath: "/bin/bash")
                runner.arguments = [scriptURL.path]
                try runner.run()

                Task { @MainActor [weak self] in
                    self?.state = .readyToRelaunch
                    self?.statusMessage = "Relaunching…"
                    // Give installer process a moment to spawn, then terminate cleanly
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    NSApplication.shared.terminate(nil)
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.state = .failed("Installation failed: \(error.localizedDescription)")
                    self?.statusMessage = "Installation failed."
                }
            }
        }
    }

    // MARK: - Alerts

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "You're Up to Date"
        alert.informativeText = "Gmail Push Bridge \(currentVersion) is currently the newest version available."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showUpdateAvailableAlert(_ release: AppRelease) {
        let alert = NSAlert()
        alert.messageText = "Update Available: \(release.tagName)"
        alert.informativeText = "A new version of Gmail Push Bridge is available.\n\nCurrent version: \(currentVersion)\nNew version: \(release.version)\n\nWould you like to install it now?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "View Release Notes…")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: // Install Update
            downloadAndInstallUpdate(release)
        case .alertSecondButtonReturn: // View Release Notes
            NSWorkspace.shared.open(release.htmlURL)
        default:
            break
        }
    }

    // MARK: - Version Comparison

    static func isVersion(_ newVersion: String, newerThan currentVersion: String) -> Bool {
        func parseVersion(_ v: String) -> [Int] {
            let clean = v.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let prefix = clean.components(separatedBy: CharacterSet(charactersIn: "-+")).first ?? clean
            let parts = prefix.components(separatedBy: ".")
            return parts.compactMap { Int($0) }
        }

        let newParts = parseVersion(newVersion)
        let curParts = parseVersion(currentVersion)
        let maxCount = max(newParts.count, curParts.count)

        for i in 0..<maxCount {
            let n = i < newParts.count ? newParts[i] : 0
            let c = i < curParts.count ? curParts[i] : 0
            if n > c { return true }
            if n < c { return false }
        }
        return false
    }
}

// MARK: - Data Transfer Objects

struct GitHubReleaseDTO: Codable, Sendable {
    let id: Int?
    let tagName: String
    let name: String?
    let body: String?
    let htmlUrl: String
    let publishedAt: String?
    let draft: Bool?
    let prerelease: Bool?
    let assets: [GitHubAssetDTO]

    enum CodingKeys: String, CodingKey {
        case id
        case tagName = "tag_name"
        case name
        case body
        case htmlUrl = "html_url"
        case publishedAt = "published_at"
        case draft
        case prerelease
        case assets
    }
}

struct GitHubAssetDTO: Codable, Sendable {
    let name: String
    let browserDownloadUrl: String
    let size: Int

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
        case size
    }
}

enum UpdateError: LocalizedError {
    case networkError(String)
    case invalidBundle
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .networkError(let msg): return msg
        case .invalidBundle: return "The downloaded update did not contain a valid GmailPushBridge.app bundle."
        case .installFailed(let msg): return msg
        }
    }
}
