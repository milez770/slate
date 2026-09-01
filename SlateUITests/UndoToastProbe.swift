import XCTest

/// 닫기 토스트 확인: 닫으면 뜨고, 누르면 탭이 돌아온다.
final class UndoToastProbe: XCTestCase {
    func testUndoRestoresTab() {
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

        app.buttons["tabGridButton"].tap()
        let card = app.buttons.matching(identifier: "tabCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        // 접기 애니메이션이 끝나야 격자가 터치를 받는다 — 닫기 버튼이 눌릴 때까지 기다린다.
        let close = app.buttons.matching(identifier: "closeTabButton").firstMatch
        var waited = 0.0
        while !close.isHittable, waited < 6 {
            Thread.sleep(forTimeInterval: 0.5)
            waited += 0.5
        }
        let before = app.buttons.matching(identifier: "tabCard").count

        // isHittable 판정이 격자 전환 직후 불안정하다 — 좌표로 바로 누른다.
        close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let undo = app.buttons["undoCloseButton"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3), "토스트가 안 떴다")
        shot(app, "토스트")
        undo.tap()
        Thread.sleep(forTimeInterval: 2)
        // 마지막 탭을 닫으면 빈 탭이 하나 생기므로, 되돌리면 빈 탭 + 복원 탭이다.
        // 복원 자체는 example.com 카드가 돌아왔는지로 본다.
        XCTAssertTrue(app.buttons.matching(identifier: "tabCard")
            .matching(NSPredicate(format: "label CONTAINS 'example.com'")).firstMatch
            .waitForExistence(timeout: 5), "닫은 탭이 안 돌아왔다")
        _ = before
        // 토스트는 4초 뒤 스스로 사라진다
        Thread.sleep(forTimeInterval: 5)
        XCTAssertFalse(app.buttons["undoCloseButton"].exists, "토스트가 안 사라진다")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
