import XCTest
@testable import Slate

/// edge-swipe-guard.js: 화면 끝에서 시작한 손가락 동작은 페이지 스크립트에 가지 않고, 안쪽 동작은 그대로 간다.
@MainActor
final class EdgeSwipeGuardTests: XCTestCase {
    private func dispatch(_ type: String, x: Int) -> String {
        """
        (function(){var e=new Event('\(type)',{bubbles:true,cancelable:true});
        Object.defineProperty(e,'touches',{value:\(type == "touchend" ? "[]" : "[{clientX:\(x),clientY:300}]")});
        document.body.dispatchEvent(e);return 1;})()
        """
    }

    func testTouchFromScreenEdgeDoesNotReachPage() async throws {
        let h = ScriptHarness(scripts: [UserScripts.source(named: "edge-swipe-guard")])
        await h.load("<html><body style='height:2000px'>page</body></html>")
        _ = try await h.eval("""
            window.__seen=[];['touchstart','touchmove','touchend'].forEach(function(t){
              window.addEventListener(t,function(){window.__seen.push(t)},{passive:true});});1
            """)
        for type in ["touchstart", "touchmove", "touchend"] { _ = try await h.eval(dispatch(type, x: 5)) }
        let fromEdge = try await h.eval("window.__seen.join(',')") as? String
        XCTAssertEqual(fromEdge, "", "끝에서 시작한 밀기는 페이지가 못 받는다")

        for type in ["touchstart", "touchmove", "touchend"] { _ = try await h.eval(dispatch(type, x: 200)) }
        let fromInside = try await h.eval("window.__seen.join(',')") as? String
        XCTAssertEqual(fromInside, "touchstart,touchmove,touchend", "안쪽에서 시작한 동작은 그대로 받는다")
    }
}
