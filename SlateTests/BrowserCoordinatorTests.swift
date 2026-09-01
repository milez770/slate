import WebKit
import XCTest
@testable import Slate

final class BrowserCoordinatorTests: XCTestCase {
    /// 로딩 중 다른 링크를 누르면 앞선 로드가 취소 오류로 끝난다 — 이걸 실패로 치면
    /// 멀쩡한 이동마다 오류 화면이 뜬다.
    func testCancelledLoadIsNotAFailure() {
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        XCTAssertFalse(BrowserCoordinator.isRealFailure(cancelled))
    }

    func testNetworkErrorsAreFailures() {
        for code in [NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost, NSURLErrorTimedOut] {
            let error = NSError(domain: NSURLErrorDomain, code: code)
            XCTAssertTrue(BrowserCoordinator.isRealFailure(error), "코드 \(code)는 실패로 봐야 한다")
        }
    }

    /// 취소는 NSURLErrorDomain의 -999만이다. 다른 도메인의 같은 번호는 걸러선 안 된다.
    func testSameCodeInOtherDomainIsAFailure() {
        let error = NSError(domain: "WebKitErrorDomain", code: NSURLErrorCancelled)
        XCTAssertTrue(BrowserCoordinator.isRealFailure(error))
    }

    func testPanelTitleShowsHost() {
        XCTAssertEqual(BrowserCoordinator.panelTitle(for: URL(string: "https://site7.com/x?y=1")), "site7.com")
    }

    func testPanelTitleFallsBackWithoutHost() {
        XCTAssertEqual(BrowserCoordinator.panelTitle(for: nil), "이 페이지")
        XCTAssertEqual(BrowserCoordinator.panelTitle(for: URL(string: "about:blank")), "이 페이지")
    }

    // MARK: - 광고 신호 직후 이동 차단

    private let ad = URL(string: "https://ad-network.example/land")!
    private let page = URL(string: "https://example.org/view/1.html")!

    func testBlocksScriptNavigationRightAfterAdIntent() {
        XCTAssertTrue(BrowserCoordinator.shouldBlockNavigation(type: .other, target: ad, current: page,
                                                               adIntentAge: 0.2))
    }

    func testAllowsScriptNavigationAfterWindowPasses() {
        XCTAssertFalse(BrowserCoordinator.shouldBlockNavigation(type: .other, target: ad, current: page,
                                                                adIntentAge: 5))
    }

    func testAllowsNavigationWithoutAdIntent() {
        XCTAssertFalse(BrowserCoordinator.shouldBlockNavigation(type: .other, target: ad, current: page,
                                                                adIntentAge: nil),
                       "신호가 없던 페이지의 정상 리다이렉트(OAuth 등)는 건드리지 않는다")
    }

    func testAllowsSameSiteNavigation() {
        let sameSite = URL(string: "https://cdn.example.org/gallery.js")!
        XCTAssertFalse(BrowserCoordinator.shouldBlockNavigation(type: .other, target: sameSite, current: page,
                                                                adIntentAge: 0.2))
    }

    /// 화면을 덮은 낚시 앵커: 광고 신호와 같은 제스처(1초 안)의 링크 탭만 자른다.
    func testBlocksLinkTapOnlyWithinSameGesture() {
        XCTAssertTrue(BrowserCoordinator.shouldBlockNavigation(type: .linkActivated, target: ad, current: page,
                                                               adIntentAge: 0.5))
        XCTAssertFalse(BrowserCoordinator.shouldBlockNavigation(type: .linkActivated, target: ad, current: page,
                                                                adIntentAge: 2))
    }

    func testFormAndBackForwardAreNeverBlocked() {
        XCTAssertFalse(BrowserCoordinator.shouldBlockNavigation(type: .formSubmitted, target: ad, current: page,
                                                                adIntentAge: 0.1))
        XCTAssertFalse(BrowserCoordinator.shouldBlockNavigation(type: .backForward, target: ad, current: page,
                                                                adIntentAge: 0.1))
    }

    func testRegistrableDomainKeepsShortSecondLevel() {
        XCTAssertEqual(BrowserCoordinator.registrableDomain("www.example.co.kr"), "example.co.kr")
        XCTAssertEqual(BrowserCoordinator.registrableDomain("a.b.example.org"), "example.org")
        XCTAssertEqual(BrowserCoordinator.registrableDomain("example.org"), "example.org")
    }

    @MainActor func testFailureSetsLoadErrorAndStartClearsIt() {
        let tab = Tab(configuration: WKWebViewConfiguration())
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                            userInfo: [NSLocalizedDescriptionKey: "인터넷 연결이 오프라인 상태입니다"])
        tab.coordinator.onFail?(error)
        XCTAssertEqual(tab.loadError, "인터넷 연결이 오프라인 상태입니다")

        tab.coordinator.onStart?()
        XCTAssertNil(tab.loadError, "새 로드가 시작되면 앞선 오류는 지운다")
    }

    /// 커밋 전에 실패하면 lastURL이 비어 주소창이 플레이스홀더로 남는다 — 주소를 고쳐
    /// 다시 시도할 수가 없으므로 실패한 주소를 주소창에 남긴다.
    @MainActor func testFailureKeepsAddressInBar() {
        let tab = Tab(configuration: WKWebViewConfiguration())
        let url = URL(string: "https://slate-load-failure-test.invalid/")!
        tab.coordinator.onFail?(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost,
                                       userInfo: [NSURLErrorFailingURLErrorKey: url]))
        XCTAssertEqual(tab.lastURL, url)
    }

    @MainActor func testRetryClearsError() {
        let tab = Tab(configuration: WKWebViewConfiguration())
        tab.coordinator.onFail?(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        XCTAssertNotNil(tab.loadError)
        tab.retryLoad()
        XCTAssertNil(tab.loadError)
    }
}
