import AppKit
import Foundation

struct MailFetchResult: Sendable {
    enum Outcome: Sendable {
        case triggeredAccount(String)
        case triggeredAllAccounts
        case skippedMailNotRunning
        case failed(String)
    }

    let outcome: Outcome
    let timestamp: Date
}

actor AppleMailBridge {
    private static let mailBundleIdentifier = "com.apple.mail"

    /// Checks whether Apple Mail is currently running so we never unexpectedly launch Mail.app.
    nonisolated static func isMailRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == mailBundleIdentifier && !$0.isTerminated
        }
    }

    /// Queries Apple Mail for configured account names (e.g., ["iCloud", "Google"]).
    func fetchAccountNames() async throws -> [String] {
        let script = """
        tell application "Mail"
            get name of every account
        end tell
        """
        let output = try await runOsascript(script)
        return output
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Triggers Apple Mail to check for new mail on the specified account, with optional fallback to all accounts.
    func triggerFetch(
        accountName: String,
        fallbackToAllAccounts: Bool,
        includeSynchronize: Bool
    ) async -> MailFetchResult {
        guard Self.isMailRunning() else {
            return MailFetchResult(outcome: .skippedMailNotRunning, timestamp: Date())
        }

        let trimmedAccount = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        let escapedAccount = Self.escapeAppleScriptString(trimmedAccount)

        let script: String
        if trimmedAccount.isEmpty {
            script = """
            tell application "Mail"
                check for new mail
                return "ALL"
            end tell
            """
        } else {
            let syncLine = includeSynchronize ? "synchronize with targetAccount" : ""
            let fallbackBlock = fallbackToAllAccounts
                ? """
                check for new mail
                return "FALLBACK_ALL"
                """
                : """
                error "Account '\(escapedAccount)' not found in Apple Mail"
                """

            script = """
            tell application "Mail"
                if (exists account "\(escapedAccount)") then
                    set targetAccount to account "\(escapedAccount)"
                    check for new mail for targetAccount
                    \(syncLine)
                    return "ACCOUNT:\(escapedAccount)"
                else
                    \(fallbackBlock)
                end if
            end tell
            """
        }

        do {
            let response = try await runOsascript(script)
            if response.hasPrefix("ACCOUNT:") {
                let matched = String(response.dropFirst("ACCOUNT:".count))
                return MailFetchResult(outcome: .triggeredAccount(matched), timestamp: Date())
            } else {
                return MailFetchResult(outcome: .triggeredAllAccounts, timestamp: Date())
            }
        } catch {
            return MailFetchResult(outcome: .failed(error.localizedDescription), timestamp: Date())
        }
    }

    private func runOsascript(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let outString = String(data: outData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let errString = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: outString)
                } else {
                    let message = errString.isEmpty
                        ? "osascript exited with status \(proc.terminationStatus)"
                        : errString
                    continuation.resume(throwing: NSError(
                        domain: "AppleMailBridge",
                        code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: message]
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func escapeAppleScriptString(_ input: String) -> String {
        input
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
