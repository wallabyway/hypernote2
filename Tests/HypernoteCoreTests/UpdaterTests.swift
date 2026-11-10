import XCTest
@testable import HypernoteCore

final class UpdaterTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(AppVersion.isNewer("0.3.0", than: "0.2.0"))
        XCTAssertTrue(AppVersion.isNewer("v0.10.0", than: "0.9.9"))
        XCTAssertTrue(AppVersion.isNewer("1.0", than: "0.99.1"))
        XCTAssertFalse(AppVersion.isNewer("0.3", than: "0.3.0"))
        XCTAssertFalse(AppVersion.isNewer("0.2.9", than: "0.3.0"))
        XCTAssertFalse(AppVersion.isNewer("0.3.0", than: "0.3.0"))
    }

    func testParsesGitHubRelease() throws {
        let json = #"""
        {"tag_name":"v0.3.0","body":"## What's new","html_url":"https://github.com/wallabyway/hypernote2/releases/tag/v0.3.0",
         "assets":[{"name":"checksums.txt","browser_download_url":"https://example.com/c"},
                   {"name":"Hypernote2-0.3.0.zip","browser_download_url":"https://example.com/Hypernote2-0.3.0.zip"}]}
        """#.data(using: .utf8)!
        let r = try Updater.parse(json)
        XCTAssertEqual(r.version, "0.3.0")
        XCTAssertEqual(r.zipURL.lastPathComponent, "Hypernote2-0.3.0.zip")
        XCTAssertEqual(r.notes, "## What's new")
    }

    func testReleaseWithoutZipIsRejected() {
        let json = #"{"tag_name":"v0.3.0","body":null,"html_url":"https://x.y","assets":[]}"#.data(using: .utf8)!
        XCTAssertThrowsError(try Updater.parse(json))
    }
}
