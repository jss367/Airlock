@testable import AppBundle
import Foundation
import XCTest

final class UpdateCheckerTest: XCTestCase {
    func testNumericVersionOrderingAndSnapshotBuilds() throws {
        XCTAssertLessThan(try XCTUnwrap(ReleaseVersion("v0.9.9")), try XCTUnwrap(ReleaseVersion("0.10.0")))
        XCTAssertLessThan(try XCTUnwrap(ReleaseVersion("0.11.9")), try XCTUnwrap(ReleaseVersion("0.11.10")))
        XCTAssertEqual(ReleaseVersion("0.11.0 SNAPSHOT"), ReleaseVersion("v0.11.0"))
        for invalid in ["", "latest", "1.2", "1..2", "1.2.3.4", "-1.2.3", "1.2.3-beta", "1.2.3/path"] {
            XCTAssertNil(ReleaseVersion(invalid), invalid)
        }
    }

    func testUpdateAvailableAndRequestConfiguration() async throws {
        let result = try await checkForAirlockUpdate(currentVersion: "0.9.0") { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/jss367/Airlock/releases/latest")
            XCTAssertEqual(request.timeoutInterval, 20)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            return self.response(tag: "v0.10.0")
        }
        XCTAssertTrue(result.isUpdateAvailable)
        XCTAssertEqual(result.release.pageURL.absoluteString, "https://github.com/jss367/Airlock/releases/tag/v0.10.0")
    }

    func testEqualAndNewerInstalledVersionsDoNotOfferDowngrade() async throws {
        for installed in ["0.10.0", "0.10.0 SNAPSHOT", "0.11.0"] {
            let result = try await checkForAirlockUpdate(currentVersion: installed) { _ in self.response() }
            XCTAssertFalse(result.isUpdateAvailable)
        }
    }

    func testFailedChecksNeverReportUpToDate() async {
        let invalidResponses = [
            response(status: 403), response(status: 404), response(status: 429), response(status: 500),
            response(tag: "latest"), response(tag: "v0.10.0 SNAPSHOT"),
            response(draft: true), response(prerelease: true),
            (Data("not json".utf8), response().1),
        ]
        for response in invalidResponses {
            do {
                _ = try await checkForAirlockUpdate(currentVersion: "0.9.0") { _ in response }
                XCTFail("Expected failed update check")
            } catch { /* Failures must reach the UI instead of claiming the app is up to date. */ }
        }
        do {
            _ = try await checkForAirlockUpdate(currentVersion: "0.9.0") { _ in throw URLError(.notConnectedToInternet) }
            XCTFail("Expected network failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    private func response(tag: String = "v0.10.0", status: Int = 200, draft: Bool = false, prerelease: Bool = false) -> (Data, URLResponse) {
        let data = Data("{\"tag_name\":\"\(tag)\",\"draft\":\(draft),\"prerelease\":\(prerelease)}".utf8)
        return (data, HTTPURLResponse(url: URL(string: "https://api.github.com")!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
