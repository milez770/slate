import WebKit
import XCTest
@testable import Slate

/// sticky-detour.js: 고정 탭의 페이지 안 층. 시험 환경에는 메시지 핸들러가 없으므로 페이지가
/// window.webkit을 흉내 내 새 탭 요청을 배열에 쌓는다.
@MainActor
final class StickyDetourTests: XCTestCase {
    private func harness() -> ScriptHarness {
        ScriptHarness(scripts: [UserScripts.source(named: "sticky-detour")])
    }

    /// 목록 페이지. 페이지 자신의 click 리스너(bubble)가 preventDefault로 실제 이동을 막고,
    /// 우리 capture 리스너가 앞서 멈추면 이 리스너는 안 돈다.
    private let page = """
    <html><body>
      <a id="detail" href="/detail/123.html">상세</a>
      <a id="next" href="/list/2.html">다음 쪽</a>
      <a id="page2" href="/albums/page/2/">목록 2쪽</a>
      <a id="post" href="/nyako-88-photos-2/">글</a>
      <a id="ext" href="https://other.example/x">외부</a>
      <script>
        window.webkit = { messageHandlers: { slateStickyOpen: { postMessage: function (u) { window.__opened.push(u); } } } };
        window.__opened = [];
        window.__pageSaw = [];
        window.__pops = 0;
        document.addEventListener('click', function (e) { window.__pageSaw.push(e.target.id); e.preventDefault(); });
        window.addEventListener('popstate', function () { window.__pops += 1; });
      </script>
    </body></html>
    """

    private func load(_ h: ScriptHarness) async {
        await h.load(page, host: "site7.com")
        _ = try? await h.eval("history.replaceState(null, '', '/list/1.html'); window.__slateSticky = true; 1")
    }

    func testDetailLinkClickOpensNewTabAndStopsPage() async throws {
        let h = harness()
        await load(h)
        _ = try await h.eval("document.getElementById('detail').click(); 1")
        let opened = try await h.eval("JSON.stringify(window.__opened)") as? String
        XCTAssertEqual(opened, "[\"https://site7.com/detail/123.html\"]")
        let saw = try await h.eval("JSON.stringify(window.__pageSaw)") as? String
        XCTAssertEqual(saw, "[]", "우리가 먼저 멈춰 페이지 리스너는 못 본다")
    }

    func testPaginationClickPassesThrough() async throws {
        let h = harness()
        await load(h)
        _ = try await h.eval("document.getElementById('next').click(); 1")
        let opened = try await h.eval("window.__opened.length") as? Int
        XCTAssertEqual(opened, 0)
        let saw = try await h.eval("JSON.stringify(window.__pageSaw)") as? String
        XCTAssertEqual(saw, "[\"next\"]", "쪽 넘김은 페이지가 그대로 처리한다")
    }

    /// 1쪽은 꼬리가 없고 2쪽부터 /page/N이 붙는 목록: 첫 화면에서 2쪽 링크는 제자리, 글은 새 탭.
    func testPageSuffixLinkStaysInPlaceFromFirstPage() async throws {
        let h = harness()
        await load(h)
        _ = try? await h.eval("history.replaceState(null, '', '/home1/'); 1")
        _ = try await h.eval("document.getElementById('page2').click(); document.getElementById('post').click(); 1")
        let opened = try await h.eval("JSON.stringify(window.__opened)") as? String
        XCTAssertEqual(opened, "[\"https://site7.com/nyako-88-photos-2/\"]")
        let saw = try await h.eval("JSON.stringify(window.__pageSaw)") as? String
        XCTAssertEqual(saw, "[\"page2\"]")
    }

    func testExternalLinkAlsoDetours() async throws {
        let h = harness()
        await load(h)
        _ = try await h.eval("document.getElementById('ext').click(); 1")
        let opened = try await h.eval("JSON.stringify(window.__opened)") as? String
        XCTAssertEqual(opened, "[\"https://other.example/x\"]")
    }

    func testNothingHappensWhenNotSticky() async throws {
        let h = harness()
        await load(h)
        _ = try await h.eval("window.__slateSticky = false; document.getElementById('detail').click(); 1")
        let opened = try await h.eval("window.__opened.length") as? Int
        XCTAssertEqual(opened, 0)
        let saw = try await h.eval("JSON.stringify(window.__pageSaw)") as? String
        XCTAssertEqual(saw, "[\"detail\"]")
    }

    /// SPA 라우터가 pushState로 상세로 넘어가면 주소 변경을 삼키고 새 탭을 연 뒤, 라우터가 원래
    /// 화면을 되살리게 popstate를 쏜다.
    func testPushStateToDetailOpensNewTabAndStaysOnList() async throws {
        let h = harness()
        await load(h)
        _ = try await h.eval("history.pushState({}, '', '/detail/777.html'); 1")
        let opened = try await h.eval("JSON.stringify(window.__opened)") as? String
        XCTAssertEqual(opened, "[\"https://site7.com/detail/777.html\"]")
        let path = try await h.eval("location.pathname") as? String
        XCTAssertEqual(path, "/list/1.html", "주소는 원래 페이지 그대로")
        try await Task.sleep(for: .milliseconds(300))
        let pops = try await h.eval("window.__pops") as? Int
        XCTAssertEqual(pops, 1, "라우터가 되살리게 popstate를 한 번 쏜다")
    }

    func testPushStateToNextPageStaysInPlace() async throws {
        let h = harness()
        await load(h)
        _ = try await h.eval("history.pushState({}, '', '/list/2.html'); 1")
        try await Task.sleep(for: .milliseconds(300))
        let opened = try await h.eval("window.__opened.length") as? Int
        XCTAssertEqual(opened, 0)
        let path = try await h.eval("location.pathname") as? String
        XCTAssertEqual(path, "/list/2.html")
        let pops = try await h.eval("window.__pops") as? Int
        XCTAssertEqual(pops, 0)
    }
}
