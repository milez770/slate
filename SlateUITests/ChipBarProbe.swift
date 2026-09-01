import XCTest

/// 주소 조각 칩 줄 눈 확인용 임시 테스트.
final class ChipBarProbe: XCTestCase {
    func testChipsAppear() {
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
        address.typeText("https://example.com/list/all-1.html?page=3#12\n")
        Thread.sleep(forTimeInterval: 5)

        // 주소창을 다시 눌러 편집 모드로 — 칩 줄이 떠야 한다
        address.tap()
        Thread.sleep(forTimeInterval: 1.5)
        shot("칩줄")

        // 숫자 든 조각(all-1.html)을 눌러 편집 줄 확인
        let chip = app.buttons["all-1.html"]
        XCTAssertTrue(chip.waitForExistence(timeout: 4), "칩이 안 떴다")
        chip.tap()
        Thread.sleep(forTimeInterval: 1.5)
        shot("편집줄")
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIApplication().screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
