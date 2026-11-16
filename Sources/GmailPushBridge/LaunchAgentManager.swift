import Foundation

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

    static func setEnabled(_ enabled: Bool) throws {
        let fm = FileManager.default
        if enabled {
            let executablePath = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
            let launchAgentsDir = plistURL.deletingLastPathComponent()
            try fm.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

            let plistDict: [String: Any] = [
                "Label": label,
                "ProgramArguments": [executablePath],
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
