import XCTest

/// 격자에서 카드를 끌어 순서를 바꾼다. 짧게 누르는 탭 전환·닫기는 그대로 살아 있어야 한다.
final class TabReorderTests: XCTestCase {
    private static var server: TestServer!
    private var app: XCUIApplication!

    private static func page(_ title: String, _ color: String) -> String {
        """
        <!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <body style="margin:0;background:\(color);height:100vh"></body>
        """
    }

    private static let pages: [String: String] = [
        "/a": page("에이", "#c0392b"),
        "/b": page("비", "#2980b9"),
        "/c": page("씨", "#27ae60"),
    ]

    override class func setUp() {
        super.setUp()
        server = try! TestServer(pages: pages)
        precondition(server.start(), "테스트 서버가 5초 안에 준비되지 않았다")
    }

    override class func tearDown() {
        server.stop()
        super.tearDown()
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testDragReordersCards() {
        openInNewTab("/a")
        openInNewTab("/b")
        openInNewTab("/c")

        XCTAssertTrue(openGrid(), "격자가 안 열렸다")

        let before = cardHosts()
        XCTAssertGreaterThanOrEqual(before.count, 3, "카드가 3장 이상이어야 한다: \(before)")

        // 첫 카드를 마지막 카드 자리로 끈다.
        let cards = app.buttons.matching(identifier: "tabCard")
        let first = cards.element(boundBy: 0)
        let last = cards.element(boundBy: cards.count - 1)
        first.press(forDuration: 1.0, thenDragTo: last, withVelocity: .slow, thenHoldForDuration: 1.0)
        Thread.sleep(forTimeInterval: 2)

        let after = cardHosts()
        XCTAssertNotEqual(before, after, "순서가 그대로다: \(before)")
    }

    /// 드래그를 붙인 뒤에도 짧게 누르면 탭이 열려야 한다.
    func testTapStillPicksTab() {
        openInNewTab("/a")
        openInNewTab("/b")
        XCTAssertTrue(openGrid(), "격자가 안 열렸다")
        app.buttons.matching(identifier: "tabCard").element(boundBy: 0).tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(app.textFields["addressTextField"].waitForExistence(timeout: 5),
                      "카드를 눌렀는데 브라우저 화면으로 안 돌아왔다")
    }

    /// 드래그를 붙인 뒤에도 닫기 버튼이 눌려야 한다.
    func testCloseButtonStillWorks() {
        openInNewTab("/a")
        openInNewTab("/b")
        XCTAssertTrue(openGrid(), "격자가 안 열렸다")
        let before = app.buttons.matching(identifier: "tabCard").count
        app.buttons.matching(identifier: "closeTabButton").element(boundBy: 0).tap()
        Thread.sleep(forTimeInterval: 2)
        let after = app.buttons.matching(identifier: "tabCard").count
        XCTAssertEqual(after, before - 1, "닫기가 안 먹었다 (\(before) → \(after))")
    }

    /// 격자를 연다. 새 탭을 막 만든 직후엔 첫 탭이 먹지 않는 일이 있어 한 번 더 시도한다.
    @discardableResult
    private func openGrid() -> Bool {
        let card = app.buttons.matching(identifier: "tabCard").firstMatch
        for _ in 0..<3 {
            app.buttons["tabGridButton"].tap()
            if card.waitForExistence(timeout: 5) {
                Thread.sleep(forTimeInterval: 1)
                return true
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    private func cardHosts() -> [String] {
        let cards = app.buttons.matching(identifier: "tabCard")
        return (0..<cards.count).map { cards.element(boundBy: $0).label }
    }

    private func openInNewTab(_ path: String) {
        let address = app.textFields["addressTextField"]
        XCTAssertTrue(address.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1)
        var attempts = 0
        while !app.keyboards.firstMatch.exists, attempts < 3 {
            address.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
            attempts += 1
        }
        address.typeText("http://localhost:\(Self.server.port)\(path)\n")
        Thread.sleep(forTimeInterval: 4)
        XCTAssertTrue(openGrid(), "새 탭을 만들려는데 격자가 안 열렸다")
        app.buttons["newTabButton"].tap()
        Thread.sleep(forTimeInterval: 2)
    }
}
