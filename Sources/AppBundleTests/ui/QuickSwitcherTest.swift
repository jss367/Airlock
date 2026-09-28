@testable import AppBundle
import Foundation
import XCTest

final class QuickSwitcherTest: XCTestCase {
    func testWebSearchUrlKeepsQuerySyntaxCharacters() {
        for query in ["c++", "AT&T", "a=b", "50% off", "what is #1?"] {
            let url = webSearchUrl(query: query)
            let q = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .percentEncodedQueryItems?.first { $0.name == "q" }?.value?.removingPercentEncoding
            assertEquals(q, query)
        }
        assertEquals(webSearchUrl(query: "c++")?.absoluteString, "https://google.com/search?q=c%2B%2B")
    }
}
