import XCTest

/// 공개용 스크린샷 촬영. 실제 사이트를 열므로 평소 테스트에서는 건너뛰고,
/// TEST_RUNNER_SCREENSHOTS=1 을 준 실행에서만 돈다. 결과는 xcresult 첨부로 남는다 —
/// `xcrun xcresulttool export attachments`로 꺼낸다.
///
/// 자동 번역은 실행 인자로 끈다 — 시뮬레이터는 Translation을 지원하지 않아 시스템
/// 번역 시트가 떠 화면을 덮는다. 입력은 전부 ASCII — 한글은 typeText로 못 친다.
final class ScreenshotCaptureTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SCREENSHOTS"] == "1")
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-slate.translate.auto", "NO"]
        app.launch()
    }

    func testCaptureAll() throws {
        // 1. 브라우징 — 위키백과
        open("https://ko.wikipedia.org", expectHost: "wikipedia.org")
        Thread.sleep(forTimeInterval: 5)
        shoot("browse")

        // 2. 페이지 내 찾기 — 깃허브 저장소 페이지에서 slate 찾기
        newTab(open: "https://github.com/milez770/slate", expectHost: "github.com")
        Thread.sleep(forTimeInterval: 5)
        tapMenu("페이지에서 찾기")
        app.typeText("slate")
        Thread.sleep(forTimeInterval: 2)
        shoot("find")
        app.buttons["findDoneButton"].tap()
        Thread.sleep(forTimeInterval: 1)

        // 3. 탭 하나 더 열고 격자
        newTab(open: "https://www.naver.com", expectHost: "naver.com")
        Thread.sleep(forTimeInterval: 5)
        expandBar()
        app.buttons["tabGridButton"].tap()
        let cards = app.buttons.matching(identifier: "tabCard")
        for _ in 0..<10 where cards.count < 3 { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertGreaterThanOrEqual(cards.count, 3, "격자에 카드 3개가 안 보인다")
        Thread.sleep(forTimeInterval: 1)
        let dump = XCTAttachment(string: app.debugDescription)
        dump.name = "tabs_hierarchy"
        dump.lifetime = .keepAlways
        add(dump)
        shoot("tabs")
        app.buttons["tabCard"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1)

        // 4. 방문 기록 타임라인
        tapMenu("방문 기록")
        Thread.sleep(forTimeInterval: 1.5)
        shoot("timeline")
        app.swipeDown(velocity: .fast)
        Thread.sleep(forTimeInterval: 1)

        // 5. 설정
        tapMenu("설정")
        Thread.sleep(forTimeInterval: 1.5)
        shoot("settings")
    }

    private func shoot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 페이지 스크롤로 하단 바가 접혀 있으면(호스트 캡슐만 남음) 펼친다.
    private func expandBar() {
        guard !app.buttons["moreButton"].exists else { return }
        let collapsed = app.otherElements["collapsedBar"]
        if collapsed.exists {
            collapsed.tap()
        } else if app.staticTexts.matching(identifier: "collapsedBar").firstMatch.exists {
            app.staticTexts.matching(identifier: "collapsedBar").firstMatch.tap()
        }
        _ = app.buttons["moreButton"].waitForExistence(timeout: 3)
    }

    private func tapMenu(_ item: String) {
        expandBar()
        app.buttons["moreButton"].tap()
        let button = app.buttons[item]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "메뉴 항목 없음: \(item)")
        button.tap()
    }

    private func newTab(open url: String, expectHost: String) {
        expandBar()
        app.buttons["tabGridButton"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        app.buttons["newTabButton"].tap()
        Thread.sleep(forTimeInterval: 1)
        // 새 탭은 주소창이 이미 포커스돼 있다.
        if !app.keyboards.firstMatch.waitForExistence(timeout: 3) {
            app.textFields["addressTextField"].tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
        }
        app.typeText(url + "\n")
        assertLoaded(expectHost)
    }

    private func open(_ url: String, expectHost: String) {
        let address = app.textFields["addressTextField"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        var attempts = 0
        while !app.keyboards.firstMatch.exists, attempts < 3 {
            address.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
            attempts += 1
        }
        XCTAssertTrue(app.keyboards.firstMatch.exists, "주소창에 포커스를 잡지 못했다")
        app.typeText(url + "\n")
        assertLoaded(expectHost)
    }

    /// 주소창 표시값(host)으로 의도한 페이지가 열렸는지 검증한다 — 입력이 새면 즉시 실측값과
    /// 함께 실패한다.
    private func assertLoaded(_ host: String) {
        let address = app.textFields["addressTextField"]
        var shown = ""
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.5)
            shown = (address.value as? String) ?? ""
            if shown.contains(host) {
                dismissKeyboardIfNeeded()
                return
            }
        }
        XCTFail("의도한 호스트 \(host)가 아니라 '\(shown)'이 열렸다")
    }

    /// 제출 직후 페이지 로드가 뷰 갱신을 일으키면 주소창 포커스가 다시 잡히는 일이 있다 —
    /// 키보드가 남아 있으면 취소 버튼으로 접는다.
    private func dismissKeyboardIfNeeded() {
        for _ in 0..<3 {
            guard app.keyboards.firstMatch.exists else { return }
            let cancel = app.buttons["cancelButton"]
            if cancel.exists { cancel.tap() }
            Thread.sleep(forTimeInterval: 1)
        }
    }
}
