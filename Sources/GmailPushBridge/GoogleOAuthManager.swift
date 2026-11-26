import AppKit
import CryptoKit
import Foundation
import Network
import Security

struct OAuthTokenSet: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var clientId: String
    var clientSecret: String?

    var isExpiredOrNearExpiry: Bool {
        Date().addingTimeInterval(120) >= expiresAt
    }
}

struct OAuthSignInResult: Sendable {
    let email: String
    let tokens: OAuthTokenSet
}

enum GoogleOAuthError: LocalizedError {
    case missingClientId
    case missingClientSecret
    case listenerFailed(String)
    case invalidCallback(String)
    case stateMismatch
    case tokenExchangeFailed(String)
    case noStoredTokens
    case timedOut

    var errorDescription: String? {
        switch self {
        case .missingClientId:
            return "Enter a Google OAuth Desktop Client ID first."
        case .missingClientSecret:
            return "Enter your Google OAuth Client Secret (or click 'Import client_secret.json…') before signing in."
        case .listenerFailed(let msg):
            return "Could not start local OAuth callback listener: \(msg)"
        case .invalidCallback(let msg):
            return "OAuth callback error: \(msg)"
        case .stateMismatch:
            return "OAuth state mismatch (CSRF check failed)."
        case .tokenExchangeFailed(let msg):
            return "Google token exchange failed: \(msg)"
        case .noStoredTokens:
            return "No OAuth tokens stored in Keychain. Please click 'Sign in with Google'."
        case .timedOut:
            return "Timed out waiting for Google sign-in in browser."
        }
    }
}

actor GoogleOAuthManager {
    static let shared = GoogleOAuthManager()

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
        let refresh_token: String?
        let token_type: String?
    }

    private struct TokenErrorResponse: Decodable {
        let error: String?
        let error_description: String?
    }

    private struct UserInfoResponse: Decodable {
        let email: String?
        let email_verified: Bool?
    }

    private var inFlightRefreshes: [String: Task<String, Error>] = [:]
    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    nonisolated static func resolveClientSecret(explicit: String?, stored: @autoclosure () -> String?) -> String? {
        if let explicitTrimmed = explicit?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitTrimmed.isEmpty {
            return explicitTrimmed
        }
        if let storedTrimmed = stored()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !storedTrimmed.isEmpty {
            return storedTrimmed
        }
        return nil
    }

    /// Starts the interactive browser OAuth 2.0 + PKCE flow (supports Passkeys / Touch ID in Safari/Chrome).
    func signInWithBrowser(
        clientId: String,
        clientSecret: String?,
        loginHintEmail: String?
    ) async throws -> OAuthSignInResult {
        let trimmedClientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientId.isEmpty else {
            throw GoogleOAuthError.missingClientId
        }
        guard let resolvedSecret = Self.resolveClientSecret(
            explicit: clientSecret,
            stored: KeychainStore.loadOAuthClientSecret(forClientId: trimmedClientId)
        ) else {
            throw GoogleOAuthError.missingClientSecret
        }

        let codeVerifier = Self.generateCodeVerifier()
        let codeChallenge = Self.codeChallenge(for: codeVerifier)
        let expectedState = Self.generateRandomURLSafeString(byteCount: 16)

        // 1. Start ephemeral loopback listener on 127.0.0.1:<ephemeral_port>
        let callbackSession = try LoopbackCallbackServer(expectedState: expectedState)
        let port = try await callbackSession.start()
        let redirectURI = "http://127.0.0.1:\(port)/oauth2callback"

        // 2. Construct Google OAuth 2.0 Authorization URL
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "client_id", value: trimmedClientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            // https://mail.google.com/ is required for IMAP XOAUTH2; email lets us auto-fill the Gmail address
            URLQueryItem(name: "scope", value: "https://mail.google.com/ email"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: expectedState)
        ]
        if let hint = loginHintEmail?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            queryItems.append(URLQueryItem(name: "login_hint", value: hint))
        }
        components.queryItems = queryItems

        guard let authURL = components.url else {
            await callbackSession.stop()
            throw GoogleOAuthError.invalidCallback("Failed to build Google authorization URL")
        }

        // 3. Open the user's default browser
        _ = await MainActor.run {
            NSWorkspace.shared.open(authURL)
        }

        // 4. Wait for the loopback redirect
        let callbackParams: [String: String]
        do {
            callbackParams = try await callbackSession.waitForCallback(timeoutSeconds: 180)
        } catch {
            await callbackSession.stop()
            throw error
        }
        await callbackSession.stop()

        if let oauthErr = callbackParams["error"] {
            throw GoogleOAuthError.invalidCallback(oauthErr)
        }
        guard let callbackState = callbackParams["state"],
              Self.constantTimeEqual(callbackState, expectedState) else {
            throw GoogleOAuthError.stateMismatch
        }
        guard let code = callbackParams["code"], !code.isEmpty else {
            throw GoogleOAuthError.invalidCallback("Missing authorization code in callback")
        }

        // 5. Exchange code for access_token + refresh_token
        let tokenResponse = try await exchangeCodeForTokens(
            code: code,
            codeVerifier: codeVerifier,
            redirectURI: redirectURI,
            clientId: trimmedClientId,
            clientSecret: resolvedSecret
        )

        guard let refreshToken = tokenResponse.refresh_token, !refreshToken.isEmpty else {
            throw GoogleOAuthError.tokenExchangeFailed("Google did not return a refresh_token. Try signing in again.")
        }

        // 6. Fetch and verify user's email address from Google UserInfo
        let resolvedEmail = try await fetchUserEmail(accessToken: tokenResponse.access_token)

        let tokenSet = OAuthTokenSet(
            accessToken: tokenResponse.access_token,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expires_in)),
            clientId: trimmedClientId,
            clientSecret: resolvedSecret
        )

        try KeychainStore.saveOAuthTokens(tokenSet, for: resolvedEmail)
        try? KeychainStore.saveOAuthClientSecret(resolvedSecret, forClientId: trimmedClientId)
        return OAuthSignInResult(email: resolvedEmail, tokens: tokenSet)
    }

    /// Returns a valid (non-expired) access token for the given account, refreshing automatically if needed.
    func validAccessToken(for email: String) async throws -> String {
        let key = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let existing = inFlightRefreshes[key] {
            return try await existing.value
        }

        guard let tokens = KeychainStore.loadOAuthTokens(for: key) else {
            throw GoogleOAuthError.noStoredTokens
        }

        if !tokens.isExpiredOrNearExpiry {
            return tokens.accessToken
        }

        let task = Task<String, Error> {
            var updatedTokens = tokens
            if updatedTokens.clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                updatedTokens.clientSecret = KeychainStore.loadOAuthClientSecret(forClientId: updatedTokens.clientId)
            }
            let refreshed = try await self.refreshAccessToken(tokens: updatedTokens)
            updatedTokens.accessToken = refreshed.access_token
            updatedTokens.expiresAt = Date().addingTimeInterval(TimeInterval(refreshed.expires_in))
            if let newRefresh = refreshed.refresh_token, !newRefresh.isEmpty {
                updatedTokens.refreshToken = newRefresh
            }
            try KeychainStore.saveOAuthTokens(updatedTokens, for: key)
            return updatedTokens.accessToken
        }

        inFlightRefreshes[key] = task
        defer { inFlightRefreshes[key] = nil }
        return try await task.value
    }

    /// Best-effort revocation of an OAuth token at Google's revocation endpoint.
    func revokeToken(_ token: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: "https://oauth2.googleapis.com/revoke") else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formURLEncodedBody(["token": trimmed])

        _ = try? await urlSession.data(for: request)
    }

    nonisolated static func sanitizeSASLField(_ value: String) -> String {
        String(value.unicodeScalars.filter { scalar in
            scalar.value > 0x20 && scalar.value != 0x7F
        })
    }

    /// Builds the base64-encoded SASL XOAUTH2 string for IMAP `AUTHENTICATE XOAUTH2 <base64>`.
    nonisolated static func buildXOAuth2SASL(email: String, accessToken: String) -> String {
        let cleanEmail = sanitizeSASLField(email)
        let cleanToken = sanitizeSASLField(accessToken)
        let raw = "user=\(cleanEmail)\u{01}auth=Bearer \(cleanToken)\u{01}\u{01}"
        return Data(raw.utf8).base64EncodedString()
    }

    // MARK: - HTTP Requests to Google OAuth Endpoints

    private func exchangeCodeForTokens(
        code: String,
        codeVerifier: String,
        redirectURI: String,
        clientId: String,
        clientSecret: String?
    ) async throws -> TokenResponse {
        var params: [String: String] = [
            "code": code,
            "client_id": clientId,
            "code_verifier": codeVerifier,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code"
        ]
        if let clientSecret, !clientSecret.isEmpty {
            params["client_secret"] = clientSecret
        }
        return try await postTokenRequest(params: params)
    }

    private func refreshAccessToken(tokens: OAuthTokenSet) async throws -> TokenResponse {
        var params: [String: String] = [
            "client_id": tokens.clientId,
            "refresh_token": tokens.refreshToken,
            "grant_type": "refresh_token"
        ]
        if let secret = Self.resolveClientSecret(
            explicit: tokens.clientSecret,
            stored: KeychainStore.loadOAuthClientSecret(forClientId: tokens.clientId)
        ) {
            params["client_secret"] = secret
        }
        return try await postTokenRequest(params: params)
    }

    nonisolated static func formURLEncodedBody(_ params: [String: String]) -> Data {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encodedPairs = params
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
        return Data(encodedPairs.joined(separator: "&").utf8)
    }

    nonisolated static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else { return false }
        var diff: UInt8 = 0
        for index in 0..<lhsBytes.count {
            diff |= lhsBytes[index] ^ rhsBytes[index]
        }
        return diff == 0
    }

    private func postTokenRequest(params: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formURLEncodedBody(params)

        let (data, response) = try await urlSession.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        if (200..<300).contains(statusCode) {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } else {
            if let errResp = try? JSONDecoder().decode(TokenErrorResponse.self, from: data) {
                let detail = [errResp.error, errResp.error_description].compactMap { $0 }.joined(separator: ": ")
                throw GoogleOAuthError.tokenExchangeFailed(detail.isEmpty ? "HTTP \(statusCode)" : detail)
            }
            let rawText = String(data: data, encoding: .utf8) ?? "HTTP \(statusCode)"
            throw GoogleOAuthError.tokenExchangeFailed(rawText)
        }
    }

    private func fetchUserEmail(accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
            throw GoogleOAuthError.tokenExchangeFailed("Failed to verify Google account email (HTTP \(statusCode)).")
        }
        let info = try JSONDecoder().decode(UserInfoResponse.self, from: data)
        guard info.email_verified == true,
              let email = info.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else {
            throw GoogleOAuthError.invalidCallback("Google did not return a verified email address for this account.")
        }
        return email
    }

    // MARK: - PKCE Helpers

    nonisolated static func generateCodeVerifier() -> String {
        generateRandomURLSafeString(byteCount: 32)
    }

    nonisolated static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func generateRandomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            fatalError("SecRandomCopyBytes failed with OSStatus \(status)")
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Ephemeral Loopback Callback Server (127.0.0.1)

actor LoopbackCallbackServer {
    private static let maxRequestBytes = 8192
    private static let headerDelimiterCRLF = Data("\r\n\r\n".utf8)
    private static let headerDelimiterLF = Data("\n\n".utf8)

    private let queue = DispatchQueue(label: "com.gmailpushbridge.oauth.loopback")
    private let expectedState: String
    private var listener: NWListener?
    private var boundPort: UInt16?
    private var callbackContinuation: CheckedContinuation<[String: String], Error>?

    init(expectedState: String) throws {
        self.expectedState = expectedState
    }

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let nwListener = try NWListener(using: parameters)
        self.listener = nwListener

        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            final class ResumeGuard: @unchecked Sendable {
                var resumed = false
            }
            let guardBox = ResumeGuard()

            nwListener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                Task {
                    await self.handleIncomingConnection(connection)
                }
            }

            nwListener.stateUpdateHandler = { state in
                guard !guardBox.resumed else { return }
                switch state {
                case .ready:
                    if let port = nwListener.port?.rawValue {
                        guardBox.resumed = true
                        continuation.resume(returning: port)
                    }
                case .failed(let error):
                    guardBox.resumed = true
                    continuation.resume(throwing: GoogleOAuthError.listenerFailed(error.localizedDescription))
                default:
                    break
                }
            }

            nwListener.start(queue: queue)
        }
        self.boundPort = port
        return port
    }

    func waitForCallback(timeoutSeconds: Int) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            self.callbackContinuation = continuation
            queue.asyncAfter(deadline: .now() + .seconds(timeoutSeconds)) { [weak self] in
                Task {
                    await self?.expireIfPending()
                }
            }
        }
    }

    func stop() {
        if let cont = callbackContinuation {
            callbackContinuation = nil
            cont.resume(throwing: GoogleOAuthError.invalidCallback("OAuth callback listener stopped."))
        }
        listener?.cancel()
        listener = nil
        boundPort = nil
    }

    private func expireIfPending() {
        if let cont = callbackContinuation {
            callbackContinuation = nil
            cont.resume(throwing: GoogleOAuthError.timedOut)
        }
    }

    private func handleIncomingConnection(_ connection: NWConnection) {
        let expectedPort = self.boundPort
        connection.start(queue: queue)
        receiveRequestData(on: connection, buffer: Data(), expectedPort: expectedPort)
    }

    private nonisolated func receiveRequestData(on connection: NWConnection, buffer: Data, expectedPort: UInt16?) {
        let remaining = Self.maxRequestBytes - buffer.count
        guard remaining > 0 else {
            connection.cancel()
            return
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let data, !data.isEmpty {
                accumulated.append(data)
            }

            let hasHeaderEnd = accumulated.range(of: Self.headerDelimiterCRLF) != nil
                || accumulated.range(of: Self.headerDelimiterLF) != nil

            if !hasHeaderEnd && !isComplete && accumulated.count < Self.maxRequestBytes {
                self.receiveRequestData(on: connection, buffer: accumulated, expectedPort: expectedPort)
                return
            }

            let requestText = String(data: accumulated, encoding: .utf8) ?? ""
            let parsed = Self.parseHTTPRequest(requestText, expectedPort: expectedPort)

            // Ignore favicon or unrelated paths
            guard parsed.path == "/oauth2callback" else {
                connection.cancel()
                return
            }

            let securityHeaders = "Cache-Control: no-store\r\nPragma: no-cache\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\n"

            guard parsed.method == "GET", parsed.hostValid else {
                let badBody = """
                <!DOCTYPE html><html><head><meta charset="utf-8"><title>Invalid OAuth Request</title></head>
                <body style="font-family:-apple-system,sans-serif;padding:40px;text-align:center;">
                <h2>Invalid OAuth Request</h2><p>Unsupported HTTP method or Host header.</p></body></html>
                """
                let badResponse = "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(badBody.utf8.count)\r\n\(securityHeaders)Connection: close\r\n\r\n\(badBody)"
                connection.send(content: Data(badResponse.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }

            let queryParams = parsed.query
            let hasCodeOrError = (queryParams["code"]?.isEmpty == false) || (queryParams["error"]?.isEmpty == false)
            let stateMatches = queryParams["state"].map { GoogleOAuthManager.constantTimeEqual($0, self.expectedState) } ?? false
            guard stateMatches, hasCodeOrError else {
                let badBody = """
                <!DOCTYPE html><html><head><meta charset="utf-8"><title>Invalid OAuth Callback</title></head>
                <body style="font-family:-apple-system,sans-serif;padding:40px;text-align:center;">
                <h2>Invalid OAuth Callback</h2><p>State mismatch or missing parameters; waiting for valid sign-in.</p></body></html>
                """
                let badResponse = "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(badBody.utf8.count)\r\n\(securityHeaders)Connection: close\r\n\r\n\(badBody)"
                connection.send(content: Data(badResponse.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }

            let isSuccess = queryParams["code"] != nil
            let html = isSuccess
                ? """
                <!DOCTYPE html><html><head><meta charset="utf-8"><title>Gmail Push Bridge</title>
                <style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;background:#f5f5f7;color:#1d1d1f}
                .card{background:#fff;padding:32px 40px;border-radius:14px;box-shadow:0 4px 20px rgba(0,0,0,0.08);text-align:center;max-width:420px}
                h2{margin:0 0 8px;color:#1d1d1f}p{margin:0;color:#6e6e73;font-size:14px}</style></head>
                <body><div class="card"><h2>✓ Signed in to Gmail Push Bridge</h2><p>You can close this browser tab and return to the app.</p></div></body></html>
                """
                : """
                <!DOCTYPE html><html><head><meta charset="utf-8"><title>Sign-in Error</title></head>
                <body style="font-family:-apple-system,sans-serif;padding:40px;text-align:center;">
                <h2>Sign-in was not completed</h2><p>You can close this tab and try again from Gmail Push Bridge.</p></body></html>
                """

            let responseHeader = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\n\(securityHeaders)Connection: close\r\n\r\n\(html)"
            connection.send(content: Data(responseHeader.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })

            Task {
                await self.deliverCallbackParams(queryParams)
            }
        }
    }

    private func deliverCallbackParams(_ params: [String: String]) {
        if let cont = callbackContinuation {
            callbackContinuation = nil
            cont.resume(returning: params)
        }
    }

    nonisolated static func parseHTTPRequest(
        _ request: String,
        expectedPort: UInt16?
    ) -> (method: String, path: String, query: [String: String], hostValid: Bool) {
        let normalized = request.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard let firstLine = lines.first, !firstLine.isEmpty else {
            return ("", "", [:], false)
        }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            return ("", "", [:], false)
        }
        let method = String(parts[0]).uppercased()
        let pathAndQuery = String(parts[1])
        guard pathAndQuery.hasPrefix("/"),
              let components = URLComponents(string: "http://127.0.0.1\(pathAndQuery)") else {
            return (method, "", [:], false)
        }
        var dict: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value {
                dict[item.name] = value
            }
        }

        var hostHeader: String?
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            if let colonIdx = line.firstIndex(of: ":") {
                let headerName = line[..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
                if headerName == "host" {
                    hostHeader = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces).lowercased()
                    break
                }
            }
        }

        let hostValid: Bool
        if let hostHeader {
            if let expectedPort {
                hostValid = (hostHeader == "127.0.0.1:\(expectedPort)")
            } else if hostHeader == "127.0.0.1" {
                hostValid = true
            } else if hostHeader.hasPrefix("127.0.0.1:") {
                let portPart = hostHeader.dropFirst("127.0.0.1:".count)
                hostValid = !portPart.isEmpty && portPart.allSatisfy(\.isNumber)
            } else {
                hostValid = false
            }
        } else {
            hostValid = false
        }

        return (method, components.path, dict, hostValid)
    }

    nonisolated static func extractRequestPathAndQuery(fromHTTPRequest request: String) -> (String, [String: String]) {
        let parsed = parseHTTPRequest(request, expectedPort: nil)
        return (parsed.path, parsed.query)
    }
}
