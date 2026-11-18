import XCTest
@testable import GmailPushBridge

@MainActor
final class UpdateManagerTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(UpdateManager.isVersion("1.4.0", newerThan: "1.3.0"))
        XCTAssertTrue(UpdateManager.isVersion("2.0.0", newerThan: "1.9.9"))
        XCTAssertTrue(UpdateManager.isVersion("1.10.0", newerThan: "1.2.0"))
        XCTAssertTrue(UpdateManager.isVersion("v1.3.1", newerThan: "1.3.0"))
        XCTAssertTrue(UpdateManager.isVersion("V1.3.1", newerThan: "v1.3.0"))
        XCTAssertTrue(UpdateManager.isVersion("1.4.0-beta.1", newerThan: "1.3.0"))
        XCTAssertTrue(UpdateManager.isVersion("1.3.0.1", newerThan: "1.3.0"))

        XCTAssertFalse(UpdateManager.isVersion("1.3.0", newerThan: "1.3.0"))
        XCTAssertFalse(UpdateManager.isVersion("1.3", newerThan: "1.3.0"))
        XCTAssertFalse(UpdateManager.isVersion("1.2.9", newerThan: "1.3.0"))
        XCTAssertFalse(UpdateManager.isVersion("1.3.0", newerThan: "1.3.1"))
        XCTAssertFalse(UpdateManager.isVersion("0.9.0", newerThan: "1.0.0"))
    }

    func testValidDownloadURLs() {
        XCTAssertTrue(UpdateManager.isValidDownloadURL(
            URL(string: "https://github.com/rallendo/gmail-push-bridge/releases/download/v1.3.0/GmailPushBridge.zip")!
        ))
        XCTAssertTrue(UpdateManager.isValidDownloadURL(
            URL(string: "https://objects.githubusercontent.com/github-production-release-asset-2e65be/12345")!
        ))
        XCTAssertTrue(UpdateManager.isValidDownloadURL(
            URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/asset.zip")!
        ))

        XCTAssertFalse(UpdateManager.isValidDownloadURL(
            URL(string: "http://github.com/rallendo/gmail-push-bridge/releases/download/v1.3.0/GmailPushBridge.zip")!
        ))
        XCTAssertFalse(UpdateManager.isValidDownloadURL(
            URL(string: "https://github.com/other/gmail-push-bridge/releases/download/v1.3.0/GmailPushBridge.zip")!
        ))
        XCTAssertFalse(UpdateManager.isValidDownloadURL(
            URL(string: "https://github.com/rallendo/gmail-push-bridge/archive/refs/tags/v1.3.0.zip")!
        ))
        XCTAssertFalse(UpdateManager.isValidDownloadURL(
            URL(string: "https://evil.example.com/GmailPushBridge.zip")!
        ))
    }

    func testValidReleasePageURLs() {
        XCTAssertTrue(UpdateManager.isValidReleasePageURL(
            URL(string: "https://github.com/rallendo/gmail-push-bridge/releases/tag/v1.3.0")!
        ))

        XCTAssertFalse(UpdateManager.isValidReleasePageURL(
            URL(string: "http://github.com/rallendo/gmail-push-bridge/releases/tag/v1.3.0")!
        ))
        XCTAssertFalse(UpdateManager.isValidReleasePageURL(
            URL(string: "https://github.com/other/repo/releases/tag/v1.3.0")!
        ))
        XCTAssertFalse(UpdateManager.isValidReleasePageURL(
            URL(string: "https://evil.example.com/rallendo/gmail-push-bridge/releases")!
        ))
    }

    func testExtractSHA256() {
        let hexA = String(repeating: "a", count: 64)
        let hexB = String(repeating: "B", count: 64)
        let hexC = String(repeating: "c", count: 64)

        // 1. Direct asset digest
        XCTAssertEqual(
            UpdateManager.extractSHA256(
                forAssetNamed: "GmailPushBridge.zip",
                assetDigest: "sha256:\(hexB)",
                releaseBody: nil
            ),
            hexB.lowercased()
        )

        // 2. Invalid assetDigest falls back to release body line matching assetName
        let multiAssetBody = """
        Checksums:
        `\(hexA)`  OtherAsset.zip
        `\(hexC)`  GmailPushBridge.zip
        """
        XCTAssertEqual(
            UpdateManager.extractSHA256(
                forAssetNamed: "GmailPushBridge.zip",
                assetDigest: "sha256:short",
                releaseBody: multiAssetBody,
                allowStandaloneFallback: false
            ),
            hexC
        )

        // 3. Standalone checksum fallback behavior
        let standaloneBody = "SHA256: `\(hexA)`"
        XCTAssertEqual(
            UpdateManager.extractSHA256(
                forAssetNamed: "GmailPushBridge.zip",
                assetDigest: nil,
                releaseBody: standaloneBody,
                allowStandaloneFallback: true
            ),
            hexA
        )
        XCTAssertNil(
            UpdateManager.extractSHA256(
                forAssetNamed: "GmailPushBridge.zip",
                assetDigest: nil,
                releaseBody: standaloneBody,
                allowStandaloneFallback: false
            )
        )

        // 4. No valid SHA-256 present
        XCTAssertNil(
            UpdateManager.extractSHA256(
                forAssetNamed: "GmailPushBridge.zip",
                assetDigest: nil,
                releaseBody: "Bug fixes and performance improvements."
            )
        )
    }

    func testGitHubReleaseDTODecoding() throws {
        let hex = String(repeating: "d", count: 64)
        let json = """
        {
          "id": 42,
          "tag_name": "v1.3.0",
          "name": "Gmail Push Bridge 1.3.0",
          "body": "Release notes",
          "html_url": "https://github.com/rallendo/gmail-push-bridge/releases/tag/v1.3.0",
          "published_at": "2026-11-16T12:00:00Z",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "GmailPushBridge.zip",
              "browser_download_url": "https://github.com/rallendo/gmail-push-bridge/releases/download/v1.3.0/GmailPushBridge.zip",
              "size": 102400,
              "digest": "sha256:\(hex)"
            }
          ]
        }
        """

        let release = try JSONDecoder().decode(GitHubReleaseDTO.self, from: Data(json.utf8))
        XCTAssertEqual(release.id, 42)
        XCTAssertEqual(release.tagName, "v1.3.0")
        XCTAssertEqual(release.name, "Gmail Push Bridge 1.3.0")
        XCTAssertEqual(release.body, "Release notes")
        XCTAssertEqual(release.htmlUrl, "https://github.com/rallendo/gmail-push-bridge/releases/tag/v1.3.0")
        XCTAssertEqual(release.publishedAt, "2026-11-16T12:00:00Z")
        XCTAssertEqual(release.draft, false)
        XCTAssertEqual(release.prerelease, false)
        XCTAssertEqual(release.assets.count, 1)
        XCTAssertEqual(release.assets.first?.name, "GmailPushBridge.zip")
        XCTAssertEqual(release.assets.first?.size, 102400)
        XCTAssertEqual(release.assets.first?.digest, "sha256:\(hex)")
    }

    func testStateFlags() {
        XCTAssertFalse(UpdateManager.State.idle.isChecking)
        XCTAssertFalse(UpdateManager.State.idle.isDownloading)

        XCTAssertTrue(UpdateManager.State.checking.isChecking)
        XCTAssertFalse(UpdateManager.State.checking.isDownloading)

        XCTAssertFalse(UpdateManager.State.downloading(progress: 0.4).isChecking)
        XCTAssertTrue(UpdateManager.State.downloading(progress: 0.4).isDownloading)

        XCTAssertFalse(UpdateManager.State.upToDate(version: "1.3.0").isChecking)
        XCTAssertFalse(UpdateManager.State.failed("oops").isDownloading)
    }
}
