import XCTest

/// 고정 표시 눈 확인용 임시 테스트.
final class StickyBadgeProbe: XCTestCase {
    func testBadges() {
        let app = XCUIApplication()
        app.launch()
        if !app.textFields["addressTextField"].waitForExistence(timeout: 10) {
            app.buttons["newTabButton"].tap()
        }
        let address = app.textFields["addressTextField"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        if !app.keyboards.firstMatch.exists { address.tap() }
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
        address.typeText("https://example.com\n")
        Thread.sleep(forTimeInterval: 4)

        // 고정 켜기
        app.buttons["moreButton"].tap()
        Thread.sleep(forTimeInterval: 1)
        app.buttons["이 탭 고정"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1)
        shot(app, "주소창표시")

        // 고정 탭에서 링크를 여러 번 눌러 갈라진 탭을 쌓는다 — 매번 고정 탭으로 되돌아가 다시 누른다
        for _ in 0..<4 {
            let link = app.webViews.links["Learn more"].firstMatch
            guard link.waitForExistence(timeout: 5) else { break }
            link.tap()
            Thread.sleep(forTimeInterval: 4)
            app.buttons["tabGridButton"].tap()
            Thread.sleep(forTimeInterval: 1.5)
            let parentCard = app.buttons.matching(identifier: "tabCard").firstMatch
            parentCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 2)
        }
        // 두 번째 고정 그룹을 만든다 — 선반이 눌러앉는지 본다
        app.buttons["tabGridButton"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        app.buttons["newTabButton"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        let address2 = app.textFields["addressTextField"]
        if !app.keyboards.firstMatch.exists { address2.tap() }
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
        address2.typeText("https://www.wikipedia.org\n")
        Thread.sleep(forTimeInterval: 5)
        app.buttons["moreButton"].tap()
        Thread.sleep(forTimeInterval: 1)
        app.buttons["이 탭 고정"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1)

        app.buttons["tabGridButton"].tap()
        Thread.sleep(forTimeInterval: 2)
        shot(app, "격자표시")
        XCTAssertGreaterThanOrEqual(app.buttons.matching(identifier: "tabCard").count, 2,
                                    "고정 탭에서 링크를 눌렀는데 새 탭이 안 생겼다")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
