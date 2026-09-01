import XCTest

/// JS 라우터가 링크를 가로채는 페이지에서 붙박이 우회가 도는지.
final class StickySpaProbe: XCTestCase {
    private static var server: TestServer!

    private static let pages: [String: String] = [
        // 링크 클릭을 JS가 먹고 pushState로만 움직이는 SPA 흉내.
        "/spa": """
        <!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">
        <body style="margin:0;font-size:28px;padding:40px">
        <p id="state">LIST</p>
        <a id="item" href="/detail/123.html" style="display:block;padding:30px 0">ITEMLINK</a>
        <script>
        document.getElementById('item').addEventListener('click', function (e) {
          e.preventDefault();
          history.pushState({}, '', '/detail/123.html');
          document.getElementById('state').textContent = 'DETAIL';
        });
        </script>
        </body>
        """,
        "/detail/123.html": """
        <!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">
        <body style="font-size:28px;padding:40px"><p>DETAILPAGE</p></body>
        """,
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

    func testSpaClickDetoursToNewTab() {
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
        address.typeText("http://localhost:\(Self.server.port)/spa\n")
        Thread.sleep(forTimeInterval: 4)

        // 붙박이를 먼저 켠다 — 클릭보다 앞서야 한다. 한 번 클릭해 주소가 옮겨가면
        // 다음 클릭은 같은 주소라 쪽 넘김으로 판정돼 통과된다.
        app.buttons["moreButton"].tap()
        Thread.sleep(forTimeInterval: 1)
        app.buttons["이 탭 붙박이"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1)
        app.webViews.links["ITEMLINK"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 4)
        XCTAssertTrue(app.webViews.staticTexts["DETAILPAGE"].waitForExistence(timeout: 6),
                      "새 탭에 상세 페이지가 안 열렸다")
        app.buttons["tabGridButton"].tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertGreaterThanOrEqual(app.buttons.matching(identifier: "tabCard").count, 2,
                                    "새 탭이 안 생겼다")
    }
}
