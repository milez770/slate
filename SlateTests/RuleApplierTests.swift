import WebKit
import XCTest
@testable import Slate

final class RuleApplierTests: XCTestCase {
    @MainActor private func harness() -> ScriptHarness {
        ScriptHarness(scripts: [UserScripts.source(named: "rule-applier")])
    }

    @MainActor func testSelectorRuleRemovesMatchingElements() async throws {
        let html = "<html><body>"
            + "<button data-banner-link=\"https://a.com\">A</button>"
            + "<button data-banner-link=\"https://b.com\">B</button>"
            + "<div id=\"keep\">본문</div></body></html>"
        let h = harness()
        await h.load(html)
        _ = try await h.eval("window.__slateSetRules([{kind:'selector',value:'[data-banner-link]'}]); 1")
        let buttonCount = try await h.count("button")
        XCTAssertEqual(buttonCount, 0)
        let keepCount = try await h.count("#keep")
        XCTAssertEqual(keepCount, 1)
    }

    @MainActor func testImageSourcePrefixRemovesWrapper() async throws {
        let html = "<html><body>"
            + "<button><img src=\"https://cdn1.example/board_uploads/x.png\"></button>"
            + "<a href=\"/x\"><img src=\"https://cdn1.example/black/thumbs/1.jpg\"></a></body></html>"
        let h = harness()
        await h.load(html)
        _ = try await h.eval("window.__slateSetRules([{kind:'imgSrcPrefix',value:'cdn1.example/board_uploads/'}]); 1")
        let buttonCount = try await h.count("button")
        XCTAssertEqual(buttonCount, 0, "광고 경로 이미지는 감싼 버튼째 사라진다")
        let anchorCount = try await h.count("a")
        XCTAssertEqual(anchorCount, 1, "같은 호스트라도 경로가 다르면 남는다")
    }

    @MainActor func testKeepsLargeAncestorWhenImageIsSmallFraction() async throws {
        // 이미지(20x20)를 감싼 a가 400x400짜리 카드 전체다 — 조상이 이미지의 8배를
        // 훌쩍 넘으면 조상 대신 이미지만 지운다.
        let html = "<html><body>"
            + "<a href=\"/card\" style=\"display:block;width:400px;height:400px\">"
            + "<img src=\"https://cdn1.example/board_uploads/x.png\" width=\"20\" height=\"20\">"
            + "<div id=\"card-body\">카드 본문</div></a></body></html>"
        let h = harness()
        await h.load(html)
        _ = try await h.eval("window.__slateSetRules([{kind:'imgSrcPrefix',value:'cdn1.example/board_uploads/'}]); 1")
        let anchorCount = try await h.count("a")
        XCTAssertEqual(anchorCount, 1, "이미지보다 훨씬 큰 조상은 남는다")
        let imgCount = try await h.count("img")
        XCTAssertEqual(imgCount, 0, "이미지 자체는 지워진다")
        let cardBodyCount = try await h.count("#card-body")
        XCTAssertEqual(cardBodyCount, 1, "카드 본문은 살아남는다")
    }

    @MainActor func testInvalidSelectorDoesNotThrow() async throws {
        let h = harness()
        await h.load("<html><body><div id=\"keep\">본문</div></body></html>")
        _ = try await h.eval("window.__slateSetRules([{kind:'selector',value:'>>>'}]); 1")
        let keepCount = try await h.count("#keep")
        XCTAssertEqual(keepCount, 1)
    }

    // 위 세 테스트는 __slateSetRules를 직접 불러 자바스크립트 로직만 검증한다.
    // 아래는 Swift 쪽 경로(SiteRuleStore → Tab.applyStoredRules → evaluateJavaScript)를
    // 실제로 타는지 확인한다 — 자바스크립트 함수를 직접 부르지 않는다.

    @MainActor
    private func tempStore(_ name: String = #function) -> SiteRuleStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-tests-\(name)-\(UUID().uuidString).json")
        return SiteRuleStore(fileURL: url)
    }

    @MainActor
    private func count(_ selector: String, in webView: WKWebView) async throws -> Int {
        let value = try await webView.evaluateJavaScript("document.querySelectorAll(\"" + selector + "\").length")
        return (value as? Int) ?? Int((value as? NSNumber)?.intValue ?? -1)
    }

    @MainActor func testRulesApplyThroughTabOnPageLoad() async throws {
        let host = "rule-applier-swift-path.example"
        let store = tempStore()
        store.add([SiteRule(kind: "selector", value: "[data-banner-link]", added: Date())], host: host)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(
            UserScripts.script(named: "rule-applier", injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        let tab = Tab(configuration: configuration, ruleStore: store)

        let html = "<html><body>"
            + "<button data-banner-link=\"https://a.com\">A</button>"
            + "<button data-banner-link=\"https://b.com\">B</button>"
            + "<div id=\"keep\">본문</div></body></html>"

        await withCheckedContinuation { continuation in
            let base = tab.coordinator.onFinish
            tab.coordinator.onFinish = { webView in
                base?(webView)
                continuation.resume()
            }
            tab.webView.loadHTMLString(html, baseURL: URL(string: "https://" + host + "/")!)
        }

        let buttonCount = try await count("button", in: tab.webView)
        XCTAssertEqual(buttonCount, 0, "Tab이 커밋/로드 완료 시점에 저장된 규칙을 스스로 밀어 넣어야 한다")
        let keepCount = try await count("#keep", in: tab.webView)
        XCTAssertEqual(keepCount, 1)
    }
}
