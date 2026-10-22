import WebKit
import XCTest
@testable import Slate

/// 로드 없는 주소 변화를 pushState(새 뒤로가기 항목)와 replaceState(항목 그대로)로 가른다.
@MainActor
final class TabURLChangeTests: XCTestCase {
    func testReplaceStateIsReportedAsReplacedAndPushStateIsNot() async throws {
        let tab = Tab()
        var changes: [(URL, Bool)] = []
        tab.onURLChange = { changes.append(($0, $1)) }
        let finished = expectation(description: "load")
        let base = tab.coordinator.onFinish
        tab.coordinator.onFinish = { base?($0); finished.fulfill() }
        // 네트워크 없이 https 문서를 띄운다. 일반 로드처럼 뒤로가기 항목이 생긴다.
        tab.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://site.test/start")!),
                                         responseHTML: "<html><body>page</body></html>")
        await fulfillment(of: [finished], timeout: 10)

        _ = try await tab.webView.evaluateJavaScript("history.replaceState({}, '', '/start?t=30'); 0")
        try await waitUntil { changes.count == 1 }
        XCTAssertEqual(changes[0].0.absoluteString, "https://site.test/start?t=30")
        XCTAssertTrue(changes[0].1, "replaceState는 항목을 그대로 둔다")

        _ = try await tab.webView.evaluateJavaScript("history.pushState({}, '', '/next'); 0")
        try await waitUntil { changes.count == 2 }
        XCTAssertEqual(changes[1].0.absoluteString, "https://site.test/next")
        XCTAssertFalse(changes[1].1, "pushState는 새 항목이다")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(condition())
    }
}
