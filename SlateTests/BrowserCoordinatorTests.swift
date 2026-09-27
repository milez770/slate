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

    /// 유니버설 링크를 다른 앱에 넘기면 WebKit이 이동을 "중단"(102)으로 끝낸다 — 앱은 열렸고
    /// 페이지는 그대로다. 이걸 실패로 치면 앱이 열린 뒤 이 탭에 오류 화면이 뜬다.
    func testAppLinkHandoffIsNotAFailure() {
        let interrupted = NSError(domain: "WebKitErrorDomain", code: 102)
        XCTAssertFalse(BrowserCoordinator.isRealFailure(interrupted))
    }

    /// 콘텐츠 차단기가 문서 자체를 막은 것(104)은 진짜 실패다 — 화면에 알려야 원인을 찾는다.
    func testContentBlockerBlockIsAFailure() {
        let blocked = NSError(domain: "WebKitErrorDomain", code: 104)
        XCTAssertTrue(BrowserCoordinator.isRealFailure(blocked))
    }

    // MARK: - 다른 앱을 여는 주소

    func testWebSchemesStayInWebView() {
        for raw in ["https://a.example/", "http://a.example/", "about:blank", "about:srcdoc",
                    "data:text/html,hi", "blob:https://a.example/uuid", "javascript:void(0)"] {
            XCTAssertTrue(BrowserCoordinator.isWebScheme(URL(string: raw)!), raw)
        }
    }

    func testAppSchemesLeaveWebView() {
        for raw in ["kakaotalk://open", "itms-apps://apps.apple.com/app/id1", "tel:0212345678",
                    "mailto:a@b.example", "intent://x", "twitter://user?id=1"] {
            XCTAssertFalse(BrowserCoordinator.isWebScheme(URL(string: raw)!), raw)
        }
    }

    /// 사용자가 누른 링크·보낸 폼, 또는 화면을 만진 직후의 스크립트 이동만 다른 앱을 열 수 있다.
    /// 손 안 댄 채 스크립트가 시도하는 이동(광고의 앱스토어 넘기기)은 조용히 버린다.
    func testExternalAppOpensOnlyWhenUserInitiated() {
        XCTAssertTrue(BrowserCoordinator.isUserInitiated(type: .linkActivated, touchAge: nil))
        XCTAssertTrue(BrowserCoordinator.isUserInitiated(type: .formSubmitted, touchAge: nil))
        XCTAssertTrue(BrowserCoordinator.isUserInitiated(type: .other, touchAge: 0.5))
        XCTAssertFalse(BrowserCoordinator.isUserInitiated(type: .other, touchAge: nil))
        XCTAssertFalse(BrowserCoordinator.isUserInitiated(type: .other, touchAge: 5))
    }

    // MARK: - 고정 탭이 새 탭으로 돌릴 이동

    /// 누른 링크와, 화면을 만진 뒤 2초 안의 스크립트 이동(카드의 클릭 핸들러가 location을 바꾸는
    /// 사이트)은 돌린다. 폼 전송·뒤로가기·새로고침·손 안 댄 리다이렉트는 제자리.
    func testDetourCoversTapsAndTouchDrivenScriptNavigation() {
        XCTAssertTrue(BrowserCoordinator.shouldDetour(type: .linkActivated, touchAge: nil))
        XCTAssertTrue(BrowserCoordinator.shouldDetour(type: .other, touchAge: 0.3))
        XCTAssertFalse(BrowserCoordinator.shouldDetour(type: .other, touchAge: nil))
        XCTAssertFalse(BrowserCoordinator.shouldDetour(type: .other, touchAge: 4))
        XCTAssertFalse(BrowserCoordinator.shouldDetour(type: .formSubmitted, touchAge: 0.1))
        XCTAssertFalse(BrowserCoordinator.shouldDetour(type: .backForward, touchAge: 0.1))
        XCTAssertFalse(BrowserCoordinator.shouldDetour(type: .reload, touchAge: 0.1))
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

    // MARK: - 클릭 가로채기 되돌리기

    private func intent(_ raw: String, prevented: Bool) -> BrowserCoordinator.ClickIntent {
        BrowserCoordinator.ClickIntent(url: URL(string: raw)!, prevented: prevented, time: Date())
    }

    /// 같은 사이트 링크를 눌렀는데 핸들러가 기본 이동을 막고 딴 사이트로 보내면 가로채기다.
    func testHijackIsRecoveredOnlyForPreventedSameSiteAnchor() {
        let detail = intent("https://example.org/view/2.html", prevented: true)
        XCTAssertTrue(BrowserCoordinator.shouldRecoverHijack(type: .other, target: ad, current: page, intent: detail))
        let notPrevented = intent("https://example.org/view/2.html", prevented: false)
        XCTAssertFalse(BrowserCoordinator.shouldRecoverHijack(type: .other, target: ad, current: page, intent: notPrevented),
                       "기본 이동을 안 막았으면 앵커가 스스로 갈 것이다")
        let external = intent("https://accounts.example/login", prevented: true)
        XCTAssertFalse(BrowserCoordinator.shouldRecoverHijack(type: .other, target: ad, current: page, intent: external),
                       "누른 링크 자체가 딴 사이트면 판단하지 않는다")
        let sameSiteTarget = URL(string: "https://example.org/other")!
        XCTAssertFalse(BrowserCoordinator.shouldRecoverHijack(type: .other, target: sameSiteTarget, current: page, intent: detail),
                       "같은 사이트 안 이동은 라우터의 몫이다")
        XCTAssertFalse(BrowserCoordinator.shouldRecoverHijack(type: .linkActivated, target: ad, current: page, intent: detail),
                       "링크 탭 자체는 가로채기가 아니다")
        XCTAssertFalse(BrowserCoordinator.shouldRecoverHijack(type: .other, target: ad, current: page, intent: nil))
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
        XCTAssertNotNil(tab.loadErrorDetail)
        tab.retryLoad()
        XCTAssertNil(tab.loadError)
        XCTAssertNil(tab.loadErrorDetail)
    }

    /// 오류 화면에 도메인·코드·실패 주소가 같이 떠야 "페이지를 열지 못했다"만 보고 원인을
    /// 추측하지 않는다.
    @MainActor func testFailureRecordsDomainCodeAndURL() {
        let tab = Tab(configuration: WKWebViewConfiguration())
        let url = URL(string: "https://site7.com/videos/123/x/")!
        tab.coordinator.onFail?(NSError(domain: "WebKitErrorDomain", code: 104,
                                       userInfo: [NSURLErrorFailingURLErrorKey: url,
                                                  NSLocalizedDescriptionKey: "콘텐츠 차단기"]))
        XCTAssertEqual(tab.loadError, "콘텐츠 차단기")
        XCTAssertEqual(tab.loadErrorDetail, "WebKitErrorDomain 104 · https://site7.com/videos/123/x/")
    }
}
