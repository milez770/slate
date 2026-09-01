import XCTest
@testable import Slate

final class PopupGuardTests: XCTestCase {
    @MainActor private func harness() -> ScriptHarness {
        ScriptHarness(scripts: [UserScripts.source(named: "popup-guard")])
    }

    private let page = "<html><body><a id=\"same\" href=\"https://site7.com/page2\">같은 사이트</a>"
        + "<a id=\"ext\" href=\"https://ads.example.net/x\" target=\"_blank\">외부</a><div id=\"box\">본문</div></body></html>"

    @MainActor func testScriptOpenOfExternalSiteGetsFakeWindowInsteadOfNull() async throws {
        let h = harness()
        await h.load(page)
        let result = try await h.eval("var w = window.open('https://ads.example.net/pop'); w && !w.closed && typeof w.focus === 'function' && (w.location.href = 'x', true)")
        XCTAssertEqual(result as? Bool, true, "광고 스크립트가 실패로 판단하지 않도록 가짜 창을 돌려준다")
    }

    @MainActor func testSyntheticClickOnExternalAnchorIsCancelled() async throws {
        let h = harness()
        await h.load(page)
        let prevented = try await h.eval("""
            var a = document.getElementById('ext'); var ev = new MouseEvent('click', {bubbles: true, cancelable: true});
            var dispatched = a.dispatchEvent(ev); !dispatched
        """)
        XCTAssertEqual(prevented as? Bool, true, "스크립트가 만든 클릭으로 외부 앵커를 누르면 취소된다")
    }

    @MainActor func testDetachedExternalAnchorClickDoesNothing() async throws {
        let h = harness()
        await h.load(page)
        let stillHere = try await h.eval("""
            var a = document.createElement('a'); a.href = 'https://ads.example.net/pop'; a.target = '_blank'; a.click();
            location.href.indexOf('site7.com') !== -1
        """)
        XCTAssertEqual(stillHere as? Bool, true)
    }

    @MainActor func testSyntheticClickOnSameSiteAnchorStillFires() async throws {
        let h = harness()
        await h.load(page)
        let fired = try await h.eval("""
            var hit = false; document.getElementById('same').addEventListener('click', function (e) { hit = true; e.preventDefault(); });
            document.getElementById('same').dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true})); hit
        """)
        XCTAssertEqual(fired as? Bool, true, "같은 사이트 앵커의 클릭은 건드리지 않는다")
    }

    @MainActor func testSameSiteOpenIsNotFaked() async throws {
        let h = harness()
        await h.load(page)
        // 팝업 자동 열기가 꺼진 WKWebView에서 진짜 window.open은 null을 돌려준다 — 가짜 창이 아니라는 증거다.
        let result = try await h.eval("window.open('https://site7.com/other') === null")
        XCTAssertEqual(result as? Bool, true)
    }
}
