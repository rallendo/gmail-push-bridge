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
    nonisolated static let mailBundleIdentifier = "com.apple.mail"

    /// Checks whether Apple Mail is currently running so we never unexpectedly launch Mail.app.
    nonisolated static func isMailRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == mailBundleIdentifier && !$0.isTerminated
        }
    }

    nonisolated static func sanitizeAccountName(_ input: String) -> String {
        let stripped = String(input.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        })
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Queries Apple Mail for configured account names (e.g., ["iCloud", "Google"]).
    func fetchAccountNames() async throws -> [String] {
        let script = """
        tell application "Mail"
            set accountNames to name of every account
        end tell
        set prevDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to linefeed
        set joinedNames to accountNames as text
        set AppleScript's text item delimiters to prevDelimiters
        return joinedNames
        """
        let output = try await runOsascript(script)
        return output
            .components(separatedBy: .newlines)
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

        let sanitizedAccount = Self.sanitizeAccountName(accountName)

        let script: String
        let arguments: [String]
        if sanitizedAccount.isEmpty {
            script = """
            on run argv
                set shouldSync to (item 1 of argv is "true")
                tell application "Mail"
                    check for new mail
                    if shouldSync then
                        repeat with acc in every account
                            try
                                synchronize with acc
                            end try
                        end repeat
                    end if
                    return "ALL"
                end tell
            end run
            """
            arguments = [includeSynchronize ? "true" : "false"]
        } else {
            script = """
            on run argv
                set targetName to item 1 of argv
                set shouldFallback to (item 2 of argv is "true")
                set shouldSync to (item 3 of argv is "true")
                tell application "Mail"
                    if (exists account targetName) then
                        set targetAccount to account targetName
                        check for new mail for targetAccount
                        if shouldSync then
                            synchronize with targetAccount
                        end if
                        return "ACCOUNT:" & targetName
                    else if shouldFallback then
                        check for new mail
                        if shouldSync then
                            repeat with acc in every account
                                try
                                    synchronize with acc
                                end try
                            end repeat
                        end if
                        return "FALLBACK_ALL"
                    else
                        error "Account '" & targetName & "' not found in Apple Mail"
                    end if
                end tell
            end run
            """
            arguments = [
                sanitizedAccount,
                fallbackToAllAccounts ? "true" : "false",
                includeSynchronize ? "true" : "false"
            ]
        }

        do {
            let response = try await runOsascript(script, arguments: arguments)
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

    private func runOsascript(_ script: String, arguments: [String] = []) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script] + arguments

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
}
