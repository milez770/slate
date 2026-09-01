import XCTest
@testable import Slate

@MainActor
final class FindInPageTests: XCTestCase {
    private func makeHarness() -> ScriptHarness {
        ScriptHarness(scripts: [UserScripts.source(named: "find-in-page")])
    }

    private let page = """
    <html><body>
      <p>사과 바나나 사과 Apple apple</p>
      <div>사과즙</div>
      <script>var 사과 = 1; // 스크립트 속 사과는 안 잡혀야 한다</script>
      <p style="display:none">숨은 사과</p>
    </body></html>
    """

    func testCountsVisibleMatchesOnly() async throws {
        let harness = makeHarness()
        await harness.load(page)
        // 보이는 사과: 문단 2 + 사과즙 1 = 3. 스크립트·숨김은 제외.
        let count = try await harness.eval("window.__slateFind('사과')") as? Int
        XCTAssertEqual(count, 3)
    }

    func testCaseInsensitive() async throws {
        let harness = makeHarness()
        await harness.load(page)
        let count = try await harness.eval("window.__slateFind('apple')") as? Int
        XCTAssertEqual(count, 2)
    }

    func testGotoWrapsAround() async throws {
        let harness = makeHarness()
        await harness.load(page)
        _ = try await harness.eval("window.__slateFind('사과')")
        let last = try await harness.eval("window.__slateFindGoto(2)") as? Int
        XCTAssertEqual(last, 2)
        let wrapped = try await harness.eval("window.__slateFindGoto(3)") as? Int
        XCTAssertEqual(wrapped, 0, "끝을 넘으면 처음으로 감는다")
        let backWrapped = try await harness.eval("window.__slateFindGoto(-1)") as? Int
        XCTAssertEqual(backWrapped, 2, "처음에서 뒤로 가면 끝으로 감는다")
    }

    func testEmptyQueryAndClear() async throws {
        let harness = makeHarness()
        await harness.load(page)
        let empty = try await harness.eval("window.__slateFind('')") as? Int
        XCTAssertEqual(empty, 0)
        _ = try await harness.eval("window.__slateFind('사과')")
        _ = try await harness.eval("window.__slateFindClear()")
        let after = try await harness.eval("window.__slateFindGoto(0)") as? Int
        XCTAssertEqual(after, -1, "지운 뒤에는 이동할 대상이 없다")
    }

    func testNoMatches() async throws {
        let harness = makeHarness()
        await harness.load(page)
        let count = try await harness.eval("window.__slateFind('포도')") as? Int
        XCTAssertEqual(count, 0)
    }

    /// 현재 일치 하이라이트는 이동할 때마다 정확히 한 범위만 담아야 한다 — 지난 일치에
    /// 불이 남는 회귀를 막는다.
    func testCurrentHighlightHoldsExactlyOneRange() async throws {
        let harness = makeHarness()
        await harness.load(page)
        _ = try await harness.eval("window.__slateFind('사과')")
        _ = try await harness.eval("window.__slateFindGoto(0)")
        _ = try await harness.eval("window.__slateFindGoto(1)")
        let size = try await harness.eval("CSS.highlights.get('slate-find-current').size") as? Int
        XCTAssertEqual(size, 1)
    }

    func testHighlightAPIAvailable() async throws {
        let harness = makeHarness()
        await harness.load(page)
        // 하이라이트가 실제로 등록되는지 — CSS Custom Highlight API가 이 WebKit에 있는지 겸사 확인.
        _ = try await harness.eval("window.__slateFind('사과')")
        let registered = try await harness.eval("CSS.highlights.has('slate-find')") as? Bool
        XCTAssertEqual(registered, true)
    }
}
