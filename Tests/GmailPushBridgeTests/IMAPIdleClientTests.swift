import XCTest
@testable import GmailPushBridge

final class IMAPIdleClientTests: XCTestCase {
    private final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [IMAPClientEvent] = []

        func append(_ event: IMAPClientEvent) {
            lock.lock()
            _events.append(event)
            lock.unlock()
        }

        func snapshot() -> [IMAPClientEvent] {
            lock.lock()
            let copy = _events
            lock.unlock()
            return copy
        }

        func removeAll() {
            lock.lock()
            _events.removeAll()
            lock.unlock()
        }
    }

    private func makeConfiguration(
        host: String = AppSettings.defaultGmailIMAPHost,
        port: UInt16 = AppSettings.defaultGmailIMAPPort,
        email: String = "user@gmail.com",
        credentialMode: IMAPCredentialMode = .appPassword("abcd efgh"),
        mailbox: String = "INBOX",
        idleRenewalMinutes: Int = 14
    ) -> IMAPConfiguration {
        IMAPConfiguration(
            host: host,
            port: port,
            email: email,
            credentialMode: credentialMode,
            mailbox: mailbox,
            idleRenewalMinutes: idleRenewalMinutes
        )
    }

    func testParseUntaggedNumber() {
        XCTAssertEqual(IMAPIdleClient.parseUntaggedNumber(line: "* 42 EXISTS", keyword: "EXISTS"), 42)
        XCTAssertEqual(IMAPIdleClient.parseUntaggedNumber(line: "* 0 exists", keyword: "EXISTS"), 0)
        XCTAssertEqual(IMAPIdleClient.parseUntaggedNumber(line: "* 7 EXPUNGE", keyword: "EXPUNGE"), 7)
        XCTAssertEqual(IMAPIdleClient.parseUntaggedNumber(line: "* 3 expunge", keyword: "EXPUNGE"), 3)

        XCTAssertNil(IMAPIdleClient.parseUntaggedNumber(line: "* 42 RECENT", keyword: "EXISTS"))
        XCTAssertNil(IMAPIdleClient.parseUntaggedNumber(line: "A001 42 EXISTS", keyword: "EXISTS"))
        XCTAssertNil(IMAPIdleClient.parseUntaggedNumber(line: "* abc EXISTS", keyword: "EXISTS"))
        XCTAssertNil(IMAPIdleClient.parseUntaggedNumber(line: "* EXISTS", keyword: "EXISTS"))
    }

    func testParseUntaggedFetchFlags() {
        XCTAssertEqual(
            IMAPIdleClient.parseUntaggedFetchFlags(line: "* 3 FETCH (FLAGS (\\Seen))"),
            "* 3 FETCH FLAGS (\\Seen)"
        )
        XCTAssertEqual(
            IMAPIdleClient.parseUntaggedFetchFlags(line: "* 12 FETCH (UID 999 FLAGS (\\Seen \\Flagged \\Answered))"),
            "* 12 FETCH FLAGS (\\Seen \\Flagged \\Answered)"
        )
        XCTAssertEqual(
            IMAPIdleClient.parseUntaggedFetchFlags(line: "* 5 FETCH (FLAGS (\\seen \\deleted \\draft))"),
            "* 5 FETCH FLAGS (\\Seen \\Deleted \\Draft)"
        )
        XCTAssertEqual(
            IMAPIdleClient.parseUntaggedFetchFlags(line: "* 4 FETCH (FLAGS ($NotJunk \\Seen CustomTag))"),
            "* 4 FETCH FLAGS (\\Seen)"
        )
        XCTAssertEqual(
            IMAPIdleClient.parseUntaggedFetchFlags(line: "* 7 FETCH (FLAGS ())"),
            "* 7 FETCH FLAGS (cleared)"
        )
        XCTAssertEqual(
            IMAPIdleClient.parseUntaggedFetchFlags(line: "* 8 FETCH (FLAGS   (\\Flagged))"),
            "* 8 FETCH FLAGS (\\Flagged)"
        )

        XCTAssertNil(IMAPIdleClient.parseUntaggedFetchFlags(line: "* 8 FETCH (UID 10)"))
        XCTAssertNil(IMAPIdleClient.parseUntaggedFetchFlags(line: "* 8 FETCH (FLAGS (\\Seen"))
        XCTAssertNil(IMAPIdleClient.parseUntaggedFetchFlags(line: "A001 FETCH (FLAGS (\\Seen))"))
        XCTAssertNil(IMAPIdleClient.parseUntaggedFetchFlags(line: "* abc FETCH (FLAGS (\\Seen))"))
    }

    func testEscapeIMAPQuoted() {
        XCTAssertEqual(IMAPIdleClient.escapeIMAPQuoted("plain@gmail.com"), "plain@gmail.com")
        XCTAssertEqual(IMAPIdleClient.escapeIMAPQuoted(#"a\b"c"#), #"a\\b\"c"#)
        XCTAssertEqual(IMAPIdleClient.escapeIMAPQuoted("user\r\nLOGOUT\0\t\u{7F}"), "userLOGOUT")
    }

    func testConnectionStateSummariesAndIsIdling() {
        XCTAssertEqual(IMAPConnectionState.disconnected.summaryText, "Disconnected")
        XCTAssertFalse(IMAPConnectionState.disconnected.isIdling)

        XCTAssertEqual(IMAPConnectionState.connecting.summaryText, "Connecting to Gmail IMAP…")
        XCTAssertFalse(IMAPConnectionState.connecting.isIdling)

        XCTAssertEqual(IMAPConnectionState.authenticating.summaryText, "Authenticating…")
        XCTAssertFalse(IMAPConnectionState.authenticating.isIdling)

        XCTAssertEqual(IMAPConnectionState.selectingMailbox("INBOX").summaryText, "Selecting INBOX…")
        XCTAssertFalse(IMAPConnectionState.selectingMailbox("INBOX").isIdling)

        let idling = IMAPConnectionState.idling(mailbox: "INBOX", existsCount: 5)
        XCTAssertEqual(idling.summaryText, "Connected • IDLE on INBOX (5 msgs)")
        XCTAssertTrue(idling.isIdling)

        XCTAssertEqual(
            IMAPConnectionState.reconnecting(attempt: 2, delaySeconds: 4).summaryText,
            "Reconnecting (#2 in 4s)…"
        )
        XCTAssertEqual(IMAPConnectionState.authFailed("Bad token").summaryText, "Auth Failed: Bad token")
        XCTAssertEqual(IMAPConnectionState.error("Timeout").summaryText, "Error: Timeout")
    }

    func testUntrustedHostRejectedBeforeConnecting() {
        let expectation = expectation(description: "Untrusted host emits authFailed")
        let recorder = EventRecorder()

        let client = IMAPIdleClient { event in
            if case .stateChanged(let state) = event {
                recorder.append(event)
                if case .authFailed = state {
                    expectation.fulfill()
                }
            }
        }

        let badConfig = makeConfiguration(host: "attacker.example.com", port: 993)
        client.start(with: badConfig)

        wait(for: [expectation], timeout: 2.0)
        let states: [IMAPConnectionState] = recorder.snapshot().compactMap {
            if case .stateChanged(let state) = $0 { return state }
            return nil
        }

        XCTAssertTrue(states.contains(.authFailed("Untrusted IMAP host: attacker.example.com:993")))
        client.stop()
    }

    func testStateMachineLoginSelectIdleSyncAndRenewal() {
        let recorder = EventRecorder()
        let client = IMAPIdleClient { event in
            recorder.append(event)
        }
        defer { client.stop() }

        let config = makeConfiguration(credentialMode: .appPassword(#"abcd\ef"gh"#))
        client.configureForTesting(config)

        // 1. Server greeting -> LOGIN
        client.receiveRawDataForTesting(Data("* OK Gimap ready for requests from 1.2.3.4\r\n".utf8))
        XCTAssertEqual(client.sentCommandsForTesting.last, "A0001 LOGIN \"user@gmail.com\" \"abcd\\\\ef\\\"gh\"\r\n")
        XCTAssertTrue(recorder.snapshot().contains { if case .stateChanged(.authenticating) = $0 { return true }; return false })

        // 2. LOGIN OK -> SELECT
        recorder.removeAll()
        client.receiveRawDataForTesting(Data("A0001 OK user@gmail.com authenticated (Success)\r\n".utf8))
        XCTAssertEqual(client.sentCommandsForTesting.last, "A0002 SELECT \"INBOX\"\r\n")
        XCTAssertTrue(recorder.snapshot().contains { if case .stateChanged(.selectingMailbox("INBOX")) = $0 { return true }; return false })

        // 3. Initial SELECT EXISTS + OK -> IDLE (should NOT fire false-positive newMailDetected)
        recorder.removeAll()
        client.receiveRawDataForTesting(Data("* 10 EXISTS\r\n* 0 RECENT\r\nA0002 OK [READ-WRITE] INBOX selected.\r\n".utf8))
        XCTAssertEqual(client.sentCommandsForTesting.last, "A0003 IDLE\r\n")
        XCTAssertTrue(recorder.snapshot().contains { if case .inboxCountUpdated(10) = $0 { return true }; return false })
        XCTAssertFalse(recorder.snapshot().contains { if case .newMailDetected = $0 { return true }; return false })

        // 4. IDLE continuation -> .idling
        recorder.removeAll()
        client.receiveRawDataForTesting(Data("+ idling\r\n".utf8))
        XCTAssertTrue(recorder.snapshot().contains {
            if case .stateChanged(.idling(mailbox: "INBOX", existsCount: 10)) = $0 { return true }
            return false
        })

        // 5. New mail EXISTS while idling
        recorder.removeAll()
        client.receiveRawDataForTesting(Data("* 11 EXISTS\r\n".utf8))
        XCTAssertTrue(recorder.snapshot().contains { if case .inboxCountUpdated(11) = $0 { return true }; return false })
        XCTAssertTrue(recorder.snapshot().contains {
            if case .stateChanged(.idling(mailbox: "INBOX", existsCount: 11)) = $0 { return true }
            return false
        })
        XCTAssertTrue(recorder.snapshot().contains { if case .newMailDetected(existsCount: 11) = $0 { return true }; return false })

        // 6. Decreased EXISTS while idling -> mailboxSyncDetected
        recorder.removeAll()
        client.receiveRawDataForTesting(Data("* 10 EXISTS\r\n".utf8))
        XCTAssertTrue(recorder.snapshot().contains { if case .inboxCountUpdated(10) = $0 { return true }; return false })
        XCTAssertTrue(recorder.snapshot().contains {
            if case .mailboxSyncDetected(let reason) = $0 {
                return reason == "Gmail IDLE (* 10 EXISTS, was 11)"
            }
            return false
        })

        // 7. EXPUNGE while idling -> decrements count and emits mailboxSyncDetected
        recorder.removeAll()
        client.receiveRawDataForTesting(Data("* 5 EXPUNGE\r\n".utf8))
        XCTAssertTrue(recorder.snapshot().contains { if case .inboxCountUpdated(9) = $0 { return true }; return false })
        XCTAssertTrue(recorder.snapshot().contains {
            if case .stateChanged(.idling(mailbox: "INBOX", existsCount: 9)) = $0 { return true }
            return false
        })
        XCTAssertTrue(recorder.snapshot().contains {
            if case .mailboxSyncDetected(let reason) = $0 {
                return reason == "Gmail IDLE (* 5 EXPUNGE)"
            }
            return false
        })

        // 8. FETCH FLAGS while idling -> emits mailboxSyncDetected
        recorder.removeAll()
        client.receiveRawDataForTesting(Data("* 3 FETCH (FLAGS (\\Seen))\r\n".utf8))
        XCTAssertTrue(recorder.snapshot().contains {
            if case .mailboxSyncDetected(let reason) = $0 {
                return reason == "Gmail IDLE (* 3 FETCH FLAGS (\\Seen))"
            }
            return false
        })

        // 9. IDLE renewal cycle
        client.triggerIdleRenewalForTesting()
        XCTAssertEqual(client.sentCommandsForTesting.last, "DONE\r\n")
        client.receiveRawDataForTesting(Data("A0003 OK IDLE terminated (Success)\r\n".utf8))
        XCTAssertEqual(client.sentCommandsForTesting.last, "A0004 IDLE\r\n")

        recorder.removeAll()
        client.receiveRawDataForTesting(Data("+ idling\r\n".utf8))
        XCTAssertTrue(recorder.snapshot().contains {
            if case .stateChanged(.idling(mailbox: "INBOX", existsCount: 9)) = $0 { return true }
            return false
        })

        // 10. Chunked TCP line buffering
        recorder.removeAll()
        client.receiveRawDataForTesting(Data("* 12 EX".utf8))
        XCTAssertTrue(recorder.snapshot().isEmpty)
        client.receiveRawDataForTesting(Data("ISTS\r\n".utf8))
        XCTAssertTrue(recorder.snapshot().contains { if case .inboxCountUpdated(12) = $0 { return true }; return false })
        XCTAssertTrue(recorder.snapshot().contains { if case .newMailDetected(existsCount: 12) = $0 { return true }; return false })
    }

    func testAuthenticationContinuationAndFailure() {
        let recorder = EventRecorder()
        let client = IMAPIdleClient { event in
            recorder.append(event)
        }
        defer { client.stop() }

        client.configureForTesting(makeConfiguration())
        client.receiveRawDataForTesting(Data("* OK Gimap ready\r\n".utf8))

        // SASL error continuation during login sends empty CRLF
        client.receiveRawDataForTesting(Data("+ eyJzdGF0dXMiOiI0MDAifQ==\r\n".utf8))
        XCTAssertEqual(client.sentCommandsForTesting.last, "\r\n")

        // Subsequent NO fails authentication
        client.receiveRawDataForTesting(Data("A0001 NO [AUTHENTICATIONFAILED] Invalid credentials\r\n".utf8))
        XCTAssertTrue(recorder.snapshot().contains {
            if case .stateChanged(.authFailed(let detail)) = $0 {
                return detail.contains("A0001 NO [AUTHENTICATIONFAILED] Invalid credentials")
            }
            return false
        })
    }
}
