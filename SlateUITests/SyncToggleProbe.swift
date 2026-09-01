import XCTest

/// 동기화 껐다 켰을 때 죽는지 재현.
final class SyncToggleProbe: XCTestCase {
    func testToggleOffOn() {
        let app = XCUIApplication()
        app.launch()
        if !app.textFields["addressTextField"].waitForExistence(timeout: 10) {
            app.buttons["newTabButton"].tap()
        }
        _ = app.textFields["addressTextField"].waitForExistence(timeout: 10)
        Thread.sleep(forTimeInterval: 2)

        // 빈 탭은 주소창에 키보드가 떠 있고 그동안 하단 바가 편집 모드다 — 닫고 시작한다.
        if app.buttons["cancelButton"].exists { app.buttons["cancelButton"].tap(); Thread.sleep(forTimeInterval: 1) }
        if !app.buttons["moreButton"].waitForExistence(timeout: 5) {
            let dump = XCTAttachment(string: app.debugDescription)
            dump.name = "계층"
            dump.lifetime = .keepAlways
            add(dump)
            XCTFail("moreButton 없음")
        }
        app.buttons["moreButton"].tap()
        Thread.sleep(forTimeInterval: 1)
        app.buttons["설정"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1)

        let toggle = app.switches.matching(NSPredicate(format: "label CONTAINS '동기화'")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "동기화 스위치를 못 찾았다")
        toggle.tap()   // 끄기
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(app.state, .runningForeground, "끄는 순간 죽었다")
        toggle.tap()   // 켜기
        Thread.sleep(forTimeInterval: 5)
        XCTAssertEqual(app.state, .runningForeground, "켜는 순간 죽었다")
        // 한 번 더 왕복
        toggle.tap()
        Thread.sleep(forTimeInterval: 2)
        toggle.tap()
        Thread.sleep(forTimeInterval: 5)
        XCTAssertEqual(app.state, .runningForeground, "두 번째 왕복에서 죽었다")
    }
}
