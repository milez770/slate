import WebKit
import XCTest
@testable import Slate

/// ad-stubs.js: 광고 스크립트 껍데기와 감지 라이브러리 무력화.
@MainActor
final class AdStubsTests: XCTestCase {
    private func harness() -> ScriptHarness {
        ScriptHarness(scripts: [UserScripts.source(named: "ad-stubs")])
    }

    func testAdsbygoogleLooksLoadedAndSlotsAreFilled() async throws {
        let h = harness()
        await h.load("""
            <html><body>
              <ins class="adsbygoogle" data-ad-width="300" data-ad-height="250" style="display:block"></ins>
            </body></html>
        """)
        let loaded = try await h.eval("window.adsbygoogle.loaded === true && window.google_ad_status === 1") as? Bool
        XCTAssertEqual(loaded, true)
        let status = try await h.eval("document.querySelector('ins').getAttribute('data-ad-status')") as? String
        XCTAssertEqual(status, "filled")
        let height = try await h.eval("document.querySelector('ins').offsetHeight") as? Int
        XCTAssertEqual(height, 250, "광고 자리가 빈 높이 0으로 남지 않는다")
    }

    func testLateInsertedSlotIsFilled() async throws {
        let h = harness()
        await h.load("<html><body></body></html>")
        _ = try await h.eval("""
            var ins = document.createElement('ins'); ins.className = 'adsbygoogle'; ins.style.display = 'block';
            document.body.appendChild(ins); 1
        """)
        try await Task.sleep(for: .milliseconds(100))
        let status = try await h.eval("document.querySelector('ins').getAttribute('data-adsbygoogle-status')") as? String
        XCTAssertEqual(status, "done")
    }

    func testGoogletagQueueRunsCallbacksAndPubadsChains() async throws {
        let h = harness()
        await h.load("<html><body></body></html>")
        let ran = try await h.eval("""
            var ran = 0;
            googletag.cmd.push(function () { ran = 1; googletag.pubads().enableSingleRequest().collapseEmptyDivs(); });
            googletag.defineSlot('/x', [300, 250], 'div').addService(googletag.pubads());
            googletag.enableServices(); googletag.display('div');
            ran === 1 && googletag.apiReady === true
        """) as? Bool
        XCTAssertEqual(ran, true)
    }

    /// BlockAdBlock·FuckAdBlock를 쓰는 감지기는 "감지 안 됨" 콜백만 받는다.
    func testAdblockDetectorLibrariesReportNotDetected() async throws {
        let h = harness()
        await h.load("<html><body></body></html>")
        _ = try await h.eval("""
            window.__result = 'none';
            fuckAdBlock.onDetected(function () { window.__result = 'detected'; })
                       .onNotDetected(function () { window.__result = 'clean'; });
            blockAdBlock.on(true, function () { window.__result = 'detected'; });
            window.fuckAdBlock = 'overwritten'; 1
        """)
        try await Task.sleep(for: .milliseconds(100))
        let result = try await h.eval("window.__result") as? String
        XCTAssertEqual(result, "clean")
        let intact = try await h.eval("typeof window.fuckAdBlock === 'object'") as? Bool
        XCTAssertEqual(intact, true, "진짜 라이브러리가 자기 인스턴스로 갈아 끼우지 못한다")
    }
}
