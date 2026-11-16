import AppKit
import CryptoKit
import Foundation
import Network

struct OAuthTokenSet: Codable, Sendable {
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
        let trimmedSecret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretOrNil = (trimmedSecret?.isEmpty == false) ? trimmedSecret : nil

        let codeVerifier = Self.generateCodeVerifier()
        let codeChallenge = Self.codeChallenge(for: codeVerifier)
        let expectedState = Self.generateRandomURLSafeString(byteCount: 16)

        // 1. Start ephemeral loopback listener on 127.0.0.1:<ephemeral_port>
        let callbackSession = try LoopbackCallbackServer()
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
        guard callbackParams["state"] == expectedState else {
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
            clientSecret: secretOrNil
        )

        guard let refreshToken = tokenResponse.refresh_token, !refreshToken.isEmpty else {
            throw GoogleOAuthError.tokenExchangeFailed("Google did not return a refresh_token. Try signing in again.")
        }

        // 6. Fetch user's email address from Google UserInfo if available
        let fetchedEmail = try? await fetchUserEmail(accessToken: tokenResponse.access_token)
        let resolvedEmail = fetchedEmail ?? loginHintEmail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !resolvedEmail.isEmpty else {
            throw GoogleOAuthError.invalidCallback("Could not determine Gmail address; please enter your Gmail address in Settings.")
        }

        let tokenSet = OAuthTokenSet(
            accessToken: tokenResponse.access_token,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expires_in)),
            clientId: trimmedClientId,
            clientSecret: secretOrNil
        )

        try KeychainStore.saveOAuthTokens(tokenSet, for: resolvedEmail)
        return OAuthSignInResult(email: resolvedEmail, tokens: tokenSet)
    }

    /// Returns a valid (non-expired) access token for the given account, refreshing automatically if needed.
    func validAccessToken(for email: String) async throws -> String {
        guard var tokens = KeychainStore.loadOAuthTokens(for: email) else {
            throw GoogleOAuthError.noStoredTokens
        }

        if !tokens.isExpiredOrNearExpiry {
            return tokens.accessToken
        }

        let refreshed = try await refreshAccessToken(tokens: tokens)
        tokens.accessToken = refreshed.access_token
        tokens.expiresAt = Date().addingTimeInterval(TimeInterval(refreshed.expires_in))
        if let newRefresh = refreshed.refresh_token, !newRefresh.isEmpty {
            tokens.refreshToken = newRefresh
        }
        try KeychainStore.saveOAuthTokens(tokens, for: email)
        return tokens.accessToken
    }

    /// Builds the base64-encoded SASL XOAUTH2 string for IMAP `AUTHENTICATE XOAUTH2 <base64>`.
    nonisolated static func buildXOAuth2SASL(email: String, accessToken: String) -> String {
        let raw = "user=\(email)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}"
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
        if let secret = tokens.clientSecret, !secret.isEmpty {
            params["client_secret"] = secret
        }
        return try await postTokenRequest(params: params)
    }

    private func postTokenRequest(params: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
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

    private func fetchUserEmail(accessToken: String) async throws -> String? {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let info = try JSONDecoder().decode(UserInfoResponse.self, from: data)
        return info.email
    }

    // MARK: - PKCE Helpers

    private static func generateCodeVerifier() -> String {
        generateRandomURLSafeString(byteCount: 32)
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func generateRandomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Ephemeral Loopback Callback Server (127.0.0.1)

private actor LoopbackCallbackServer {
    private let queue = DispatchQueue(label: "com.gmailpushbridge.oauth.loopback")
    private var listener: NWListener?
    private var callbackContinuation: CheckedContinuation<[String: String], Error>?

    init() throws {}

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let nwListener = try NWListener(using: parameters)
        self.listener = nwListener

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
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
        listener?.cancel()
        listener = nil
    }

    private func expireIfPending() {
        if let cont = callbackContinuation {
            callbackContinuation = nil
            cont.resume(throwing: GoogleOAuthError.timedOut)
        }
    }

    private func handleIncomingConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            let requestText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let queryParams = Self.extractQueryParameters(fromHTTPRequest: requestText)

            // Ignore favicon requests
            guard requestText.contains("/oauth2callback") else {
                connection.cancel()
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

            let responseHeader = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
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

    private static func extractQueryParameters(fromHTTPRequest request: String) -> [String: String] {
        guard let firstLine = request.split(separator: "\r\n").first ?? request.split(separator: "\n").first else {
            return [:]
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return [:] }
        let pathAndQuery = String(parts[1])
        guard let components = URLComponents(string: "http://127.0.0.1\(pathAndQuery)"),
              let items = components.queryItems else {
            return [:]
        }
        var dict: [String: String] = [:]
        for item in items {
            if let value = item.value {
                dict[item.name] = value
            }
        }
        return dict
    }
}
