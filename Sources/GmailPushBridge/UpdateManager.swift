import AppKit
import CryptoKit
import Foundation
import Security

@MainActor
final class UpdateManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = UpdateManager()

    // GitHub repository configuration
    nonisolated static let repositoryOwner = "rallendo"
    nonisolated static let repositoryName = "gmail-push-bridge"
    static let apiEndpoint = URL(string: "https://api.github.com/repos/\(repositoryOwner)/\(repositoryName)/releases/latest")!
    nonisolated static let expectedBundleIdentifier = "com.gmailpushbridge.app"
    nonisolated static let allowedBundleNames: Set<String> = ["GmailPushBridge.app", "Gmail Push Bridge.app"]

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
        let expectedSHA256: String?
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastCheckedDate: Date?
    @Published private(set) var availableUpdate: AppRelease?
    @Published private(set) var statusMessage: String?

    private var downloadTask: URLSessionDownloadTask?
    private var activeDownloadExpectedSHA256: String?
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

        // Check every 24 hours (86,400 seconds) with generous tolerance for timer coalescing
        let timer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, settings.automaticallyCheckForUpdates else { return }
                self.checkForUpdates(isUserInitiated: false)
            }
        }
        timer.tolerance = 3_600
        periodicTimer = timer
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
            let zipAssets = release.assets.filter {
                $0.name.lowercased().hasSuffix(".zip")
            }
            let zipAsset = zipAssets.first

            let rawDownloadURL = zipAsset.flatMap { URL(string: $0.browserDownloadUrl) }
            let downloadURL = rawDownloadURL.flatMap { Self.isValidDownloadURL($0) ? $0 : nil }
            let defaultReleasesURL = URL(string: "https://github.com/\(Self.repositoryOwner)/\(Self.repositoryName)/releases")!
            let parsedHTMLURL = URL(string: release.htmlUrl)
            let htmlURL = parsedHTMLURL.flatMap { Self.isValidReleasePageURL($0) ? $0 : nil } ?? defaultReleasesURL
            let expectedSHA256 = zipAsset.flatMap {
                Self.extractSHA256(
                    forAssetNamed: $0.name,
                    assetDigest: $0.digest,
                    releaseBody: release.body,
                    allowStandaloneFallback: zipAssets.count == 1
                )
            }

            let appRelease = AppRelease(
                id: String(release.id ?? 0),
                tagName: remoteTag,
                version: remoteVersion,
                title: release.name ?? remoteTag,
                notes: release.body ?? "No release notes provided.",
                htmlURL: htmlURL,
                downloadURL: downloadURL,
                publishedAt: release.publishedAt.flatMap { ISO8601DateFormatter().date(from: $0) },
                assetSize: zipAsset?.size ?? 0,
                expectedSHA256: expectedSHA256
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
        guard let downloadURL = release.downloadURL,
              Self.isValidDownloadURL(downloadURL) else {
            // If there's no valid direct zip asset, open the validated release page in the browser
            if Self.isValidReleasePageURL(release.htmlURL) {
                NSWorkspace.shared.open(release.htmlURL)
            }
            return
        }

        guard !state.isDownloading else { return }

        self.activeDownloadExpectedSHA256 = release.expectedSHA256
        self.state = .downloading(progress: 0.0)
        self.statusMessage = "Downloading update \(release.tagName)…"

        let request = URLRequest(url: downloadURL)
        downloadTask = downloadSession.downloadTask(with: request)
        downloadTask?.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        activeDownloadExpectedSHA256 = nil
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
                self.activeDownloadExpectedSHA256 = nil
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
        guard let httpResponse = downloadTask.response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let finalURL = httpResponse.url,
              Self.isValidDownloadURL(finalURL) else {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.activeDownloadExpectedSHA256 = nil
                self.state = .failed("Download rejected: untrusted download origin or invalid HTTP status.")
                self.statusMessage = "Download verification failed."
            }
            return
        }

        // Move downloaded file to temporary path before URLSession removes it
        let tempZip = FileManager.default.temporaryDirectory.appendingPathComponent("GmailPushBridge-Update-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: tempZip)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let expectedSHA256 = self.activeDownloadExpectedSHA256 ?? self.availableUpdate?.expectedSHA256
                self.activeDownloadExpectedSHA256 = nil
                self.installUpdate(from: tempZip, expectedSHA256: expectedSHA256)
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.activeDownloadExpectedSHA256 = nil
                self?.state = .failed("Could not stage download: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Installation Execution

    private func installUpdate(from zipURL: URL, expectedSHA256: String?) {
        self.state = .installing
        self.statusMessage = "Verifying & preparing update…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fileManager = FileManager.default
            var tempDir: URL?

            do {
                // 1. Verify SHA-256 archive digest if provided by GitHub Release metadata/notes
                if let expectedSHA256 {
                    let zipData = try Data(contentsOf: zipURL)
                    let actualDigest = SHA256.hash(data: zipData)
                    let actualHex = actualDigest.map { String(format: "%02x", $0) }.joined()
                    guard actualHex.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
                        throw UpdateError.verificationFailed("Downloaded archive failed SHA-256 integrity verification.")
                    }
                }

                let stagingDir = fileManager.temporaryDirectory.appendingPathComponent("GmailPushBridge-Staging-\(UUID().uuidString)")
                try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                tempDir = stagingDir

                // 2. Extract zip with ditto (preserves symlinks, code signatures, and permissions)
                let ditto = Process()
                ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                ditto.arguments = ["-xk", zipURL.path, stagingDir.path]
                try ditto.run()
                ditto.waitUntilExit()

                guard ditto.terminationStatus == 0 else {
                    throw UpdateError.installFailed("Failed to unpack update archive.")
                }

                // 3. Locate an allowlisted .app bundle inside extracted files (rejecting symlinks)
                let topLevelItems = try fileManager.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])

                var appBundleURL: URL?
                if let directApp = topLevelItems.first(where: { Self.isAllowedAppBundleCandidate($0) }) {
                    appBundleURL = directApp
                } else {
                    for item in topLevelItems where item.lastPathComponent != "__MACOSX" {
                        let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                        if values?.isDirectory == true, values?.isSymbolicLink == false {
                            let subItems = (try? fileManager.contentsOfDirectory(at: item, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
                            if let subApp = subItems.first(where: { Self.isAllowedAppBundleCandidate($0) }) {
                                appBundleURL = subApp
                                break
                            }
                        }
                    }
                }

                guard let extractedApp = appBundleURL else {
                    throw UpdateError.invalidBundle
                }

                // 4. Verify bundle structure and cryptographic code signature before clearing quarantine
                try Self.verifyAppBundleSignature(at: extractedApp)

                // 5. Remove macOS Quarantine flag only after verification succeeds
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

                // 6. Write a static installer script receiving all paths strictly via positional arguments
                let scriptURL = fileManager.temporaryDirectory.appendingPathComponent("install-gmailpushbridge-\(UUID().uuidString).sh")
                let installerScript = """
                #!/bin/bash
                set -e
                PID="$1"
                SRC="$2"
                DST="$3"
                STAGING_DIR="$4"

                # Wait for running app process to terminate
                for i in {1..100}; do
                    if ! kill -0 "$PID" 2>/dev/null; then
                        break
                    fi
                    sleep 0.1
                done

                # Replace app bundle
                if /bin/rm -rf -- "$DST" 2>/dev/null && /usr/bin/ditto "$SRC" "$DST" 2>/dev/null; then
                    :
                else
                    # If standard write fails (e.g., system /Applications requires elevated rights), pass paths via argv to AppleScript
                    /usr/bin/osascript - "$SRC" "$DST" <<'APPLESCRIPT'
                on run argv
                    set srcPath to item 1 of argv
                    set dstPath to item 2 of argv
                    do shell script "/bin/rm -rf -- " & quoted form of dstPath & " && /usr/bin/ditto " & quoted form of srcPath & " " & quoted form of dstPath with administrator privileges
                end run
                APPLESCRIPT
                fi

                # Clean up staging directory and self
                /bin/rm -rf -- "$STAGING_DIR"
                /bin/rm -f -- "$0"

                # Relaunch updated application
                /usr/bin/open "$DST"
                """

                try installerScript.write(to: scriptURL, atomically: true, encoding: .utf8)
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

                let runner = Process()
                runner.executableURL = URL(fileURLWithPath: "/bin/bash")
                runner.arguments = [
                    scriptURL.path,
                    String(ProcessInfo.processInfo.processIdentifier),
                    extractedApp.path,
                    destinationPath,
                    stagingDir.path
                ]
                try runner.run()

                Task { @MainActor [weak self] in
                    self?.state = .readyToRelaunch
                    self?.statusMessage = "Relaunching…"
                    // Give installer process a moment to spawn, then terminate cleanly
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    NSApplication.shared.terminate(nil)
                }
            } catch {
                try? fileManager.removeItem(at: zipURL)
                if let tempDir {
                    try? fileManager.removeItem(at: tempDir)
                }
                Task { @MainActor [weak self] in
                    self?.state = .failed("Installation failed: \(error.localizedDescription)")
                    self?.statusMessage = "Installation failed."
                }
            }
        }
    }

    // MARK: - Origin, Checksum & Signature Verification

    nonisolated static func isValidDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            return false
        }

        if host == "github.com" {
            let expectedPrefix = "/\(repositoryOwner.lowercased())/\(repositoryName.lowercased())/releases/download/"
            return url.path.lowercased().hasPrefix(expectedPrefix)
        }

        return host == "objects.githubusercontent.com" || host == "release-assets.githubusercontent.com"
    }

    nonisolated static func isValidReleasePageURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com" else {
            return false
        }
        let expectedPrefix = "/\(repositoryOwner.lowercased())/\(repositoryName.lowercased())/"
        return url.path.lowercased().hasPrefix(expectedPrefix)
    }

    nonisolated static func extractSHA256(
        forAssetNamed assetName: String,
        assetDigest: String?,
        releaseBody: String?,
        allowStandaloneFallback: Bool = true
    ) -> String? {
        if let assetDigest {
            let trimmed = assetDigest.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("sha256:") {
                let candidate = String(trimmed.dropFirst("sha256:".count))
                if isValidSHA256Hex(candidate) {
                    return candidate.lowercased()
                }
            }
        }

        guard let releaseBody, !releaseBody.isEmpty else { return nil }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "`*:,;|()[]{}<>\"'="))
        let lines = releaseBody.components(separatedBy: .newlines)

        for line in lines where line.localizedCaseInsensitiveContains(assetName) {
            for token in line.components(separatedBy: separators) where isValidSHA256Hex(token) {
                return token.lowercased()
            }
        }

        if allowStandaloneFallback {
            for line in lines {
                for token in line.components(separatedBy: separators) where isValidSHA256Hex(token) {
                    return token.lowercased()
                }
            }
        }

        return nil
    }

    private nonisolated static func isValidSHA256Hex(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.allSatisfy { ch in
            ("0"..."9").contains(ch) || ("a"..."f").contains(ch) || ("A"..."F").contains(ch)
        }
    }

    private nonisolated static func isAllowedAppBundleCandidate(_ url: URL) -> Bool {
        guard allowedBundleNames.contains(url.lastPathComponent),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink == false
    }

    nonisolated static func verifyAppBundleSignature(at bundleURL: URL) throws {
        let infoPlistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        let plistData = try Data(contentsOf: infoPlistURL)
        guard let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String,
              bundleID == expectedBundleIdentifier,
              let executableName = plist["CFBundleExecutable"] as? String,
              executableName == "GmailPushBridge" else {
            throw UpdateError.verificationFailed("Update bundle metadata failed validation.")
        }

        let executableURL = bundleURL.appendingPathComponent("Contents/MacOS/\(executableName)")
        let execValues = try executableURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard execValues.isRegularFile == true, execValues.isSymbolicLink == false else {
            throw UpdateError.verificationFailed("Update executable missing or invalid.")
        }

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            throw UpdateError.verificationFailed("Could not inspect update code signature (OSStatus \(createStatus)).")
        }

        let checkFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let validityStatus = SecStaticCodeCheckValidity(staticCode, checkFlags, nil)
        guard validityStatus == errSecSuccess else {
            throw UpdateError.verificationFailed("Update code signature is invalid or tampered (OSStatus \(validityStatus)).")
        }

        var signingInfoCF: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInfoCF)
        guard infoStatus == errSecSuccess,
              let signingInfo = signingInfoCF as? [String: Any],
              let signedIdentifier = signingInfo[kSecCodeInfoIdentifier as String] as? String,
              signedIdentifier == expectedBundleIdentifier else {
            throw UpdateError.verificationFailed("Update signing identifier did not match \(expectedBundleIdentifier).")
        }

        if let currentTeamID = currentBundleTeamIdentifier() {
            let requirementString = "identifier \"\(expectedBundleIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(currentTeamID)\""
            var requirement: SecRequirement?
            let reqStatus = SecRequirementCreateWithString(requirementString as CFString, [], &requirement)
            guard reqStatus == errSecSuccess, let requirement else {
                throw UpdateError.verificationFailed("Failed to create Team ID signature requirement (OSStatus \(reqStatus)).")
            }
            let teamValidityStatus = SecStaticCodeCheckValidity(staticCode, checkFlags, requirement)
            guard teamValidityStatus == errSecSuccess else {
                throw UpdateError.verificationFailed("Update signature does not match current Developer ID team (OSStatus \(teamValidityStatus)).")
            }
        }
    }

    private nonisolated static func currentBundleTeamIdentifier() -> String? {
        let currentURL = Bundle.main.bundleURL
        guard currentURL.pathExtension == "app" else { return nil }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(currentURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }

        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any],
              let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String,
              !teamID.isEmpty,
              teamID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return nil
        }
        return teamID
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
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
        case size
        case digest
    }
}

enum UpdateError: LocalizedError {
    case networkError(String)
    case invalidBundle
    case verificationFailed(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .networkError(let msg): return msg
        case .invalidBundle: return "The downloaded update did not contain a valid GmailPushBridge.app bundle."
        case .verificationFailed(let msg): return msg
        case .installFailed(let msg): return msg
        }
    }
}
