import XCTest
@testable import GmailPushBridge

final class GoogleOAuthTests: XCTestCase {
    func testOAuthTokenSetCodableAndExpiry() throws {
        let expired = OAuthTokenSet(
            accessToken: "access-1",
            refreshToken: "refresh-1",
            expiresAt: Date().addingTimeInterval(-10),
            clientId: "client-id",
            clientSecret: "client-secret"
        )
        XCTAssertTrue(expired.isExpiredOrNearExpiry)

        let nearExpiry = OAuthTokenSet(
            accessToken: "access-2",
            refreshToken: "refresh-2",
            expiresAt: Date().addingTimeInterval(60),
            clientId: "client-id",
            clientSecret: nil
        )
        XCTAssertTrue(nearExpiry.isExpiredOrNearExpiry)

        let valid = OAuthTokenSet(
            accessToken: "access-3",
            refreshToken: "refresh-3",
            expiresAt: Date().addingTimeInterval(600),
            clientId: "client-id",
            clientSecret: "secret-3"
        )
        XCTAssertFalse(valid.isExpiredOrNearExpiry)

        let encoded = try JSONEncoder().encode(valid)
        let decoded = try JSONDecoder().decode(OAuthTokenSet.self, from: encoded)
        XCTAssertEqual(decoded.accessToken, valid.accessToken)
        XCTAssertEqual(decoded.refreshToken, valid.refreshToken)
        XCTAssertEqual(decoded.clientId, valid.clientId)
        XCTAssertEqual(decoded.clientSecret, valid.clientSecret)
        XCTAssertEqual(decoded.expiresAt.timeIntervalSince1970, valid.expiresAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testSanitizeSASLFieldAndBuildXOAuth2SASL() {
        XCTAssertEqual(
            GoogleOAuthManager.sanitizeSASLField("alice@gmail.com \r\n\u{01}\u{7F}"),
            "alice@gmail.com"
        )

        let sasl = GoogleOAuthManager.buildXOAuth2SASL(
            email: "alice@gmail.com\r\n",
            accessToken: "ya29.token \u{01}"
        )
        let decodedData = Data(base64Encoded: sasl)
        XCTAssertNotNil(decodedData)
        let decodedString = decodedData.flatMap { String(data: $0, encoding: .utf8) }
        XCTAssertEqual(decodedString, "user=alice@gmail.com\u{01}auth=Bearer ya29.token\u{01}\u{01}")
    }

    func testPKCEHelpersMatchRFC7636Vector() {
        // RFC 7636 Appendix B test vector
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let expectedChallenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        XCTAssertEqual(GoogleOAuthManager.codeChallenge(for: verifier), expectedChallenge)

        let generated1 = GoogleOAuthManager.generateCodeVerifier()
        let generated2 = GoogleOAuthManager.generateCodeVerifier()
        XCTAssertEqual(generated1.count, 43)
        XCTAssertNotEqual(generated1, generated2)
        XCTAssertFalse(generated1.contains("+"))
        XCTAssertFalse(generated1.contains("/"))
        XCTAssertFalse(generated1.contains("="))
    }

    func testLoopbackRequestParsing() {
        let validRequest = "GET /oauth2callback?code=4%2F0AX4XfWh&state=state123 HTTP/1.1\r\nHost: 127.0.0.1:54321\r\n\r\n"
        let (path, params) = LoopbackCallbackServer.extractRequestPathAndQuery(fromHTTPRequest: validRequest)
        XCTAssertEqual(path, "/oauth2callback")
        XCTAssertEqual(params["code"], "4/0AX4XfWh")
        XCTAssertEqual(params["state"], "state123")

        let errorRequest = "GET /oauth2callback?error=access_denied&state=state123 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let (errPath, errParams) = LoopbackCallbackServer.extractRequestPathAndQuery(fromHTTPRequest: errorRequest)
        XCTAssertEqual(errPath, "/oauth2callback")
        XCTAssertEqual(errParams["error"], "access_denied")
        XCTAssertEqual(errParams["state"], "state123")

        let faviconRequest = "GET /favicon.ico HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let (favPath, favParams) = LoopbackCallbackServer.extractRequestPathAndQuery(fromHTTPRequest: faviconRequest)
        XCTAssertEqual(favPath, "/favicon.ico")
        XCTAssertTrue(favParams.isEmpty)

        let (emptyPath, emptyParams) = LoopbackCallbackServer.extractRequestPathAndQuery(fromHTTPRequest: "")
        XCTAssertEqual(emptyPath, "")
        XCTAssertTrue(emptyParams.isEmpty)
    }

    func testGoogleOAuthErrorDescriptions() {
        let errors: [GoogleOAuthError] = [
            .missingClientId,
            .listenerFailed("port in use"),
            .invalidCallback("missing code"),
            .stateMismatch,
            .tokenExchangeFailed("invalid_grant"),
            .noStoredTokens,
            .timedOut
        ]

        for err in errors {
            XCTAssertNotNil(err.errorDescription)
            XCTAssertFalse(err.errorDescription?.isEmpty ?? true)
        }
    }
}
