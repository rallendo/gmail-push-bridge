import Foundation

enum LaunchAgentError: LocalizedError {
    case untrustedBundleLocation(String)
    case invalidExecutablePath

    var errorDescription: String? {
        switch self {
        case .untrustedBundleLocation(let path):
            return "Move GmailPushBridge.app into /Applications (or ~/Applications) before enabling Start at Login. Current location: \(path)"
        case .invalidExecutablePath:
            return "Unable to locate a valid executable inside the application bundle."
        }
    }
}

struct LaunchAgentManager {
    static let label = "com.gmailpushbridge.app"

    static var plistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library")
            .appendingPathComponent("LaunchAgents")
            .appendingPathComponent("\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    nonisolated static func isApprovedApplicationPath(_ rawPath: String) -> Bool {
        let standardizedPath = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().standardizedFileURL.path
        let userAppsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications")
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path

        return standardizedPath.hasPrefix("/Applications/") || standardizedPath.hasPrefix("\(userAppsPath)/")
    }

    nonisolated static func isApprovedApplicationLocation(bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        guard bundleURL.pathExtension == "app",
              let values = try? bundleURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink == false else {
            return false
        }
        return isApprovedApplicationPath(bundleURL.path)
    }

    static func setEnabled(_ enabled: Bool, allowNonStandardLocation: Bool = false) throws {
        let fm = FileManager.default
        if enabled {
            let bundleURL = Bundle.main.bundleURL
            guard allowNonStandardLocation || isApprovedApplicationLocation(bundleURL: bundleURL) else {
                throw LaunchAgentError.untrustedBundleLocation(bundleURL.path)
            }

            guard let execURL = Bundle.main.executableURL,
                  let execValues = try? execURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  execValues.isRegularFile == true,
                  execValues.isSymbolicLink == false else {
                throw LaunchAgentError.invalidExecutablePath
            }

            let launchAgentsDir = plistURL.deletingLastPathComponent()
            try fm.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

            let plistDict: [String: Any] = [
                "Label": label,
                "ProgramArguments": [execURL.path],
                "RunAtLoad": true,
                "KeepAlive": true,
                "ProcessType": "Interactive"
            ]

            let data = try PropertyListSerialization.data(
                fromPropertyList: plistDict,
                format: .xml,
                options: 0
            )
            try data.write(to: plistURL, options: .atomic)
        } else {
            if fm.fileExists(atPath: plistURL.path) {
                try fm.removeItem(at: plistURL)
            }
        }
    }
}
