import XCTest

/// 뷰포트·키보드 계약 검증. 페이지가 보는 뷰포트가 하단 바를 인지하고,
/// 포커스된 인풋이 키보드에 가려지지 않아야 한다.
final class ViewportUITests: XCTestCase {
    private static var server: TestServer!
    private var app: XCUIApplication!

    private static let pages: [String: String] = [
        // 문서 자체가 스크롤되는 일반 페이지.
        "/tall": """
        <!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">
        <body style="margin:0">
        <div style="height:4000px;background:#eee"></div>
        <p style="margin:0;padding:8px;font-size:20px">ENDMARK</p>
        </body>
        """,
        // 뷰포트 높이에 몸을 맞추고 내부에서 스크롤하는 페이지 — m.youtube.com 류.
        "/app": """
        <!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">
        <html style="height:100%"><body style="margin:0;height:100%;overflow:hidden">
        <div style="height:100%;overflow-y:scroll;-webkit-overflow-scrolling:touch">
        <div style="height:4000px;background:#eee"></div>
        <p style="margin:0;padding:8px;font-size:20px">ENDMARK</p>
        </div>
        </body></html>
        """,
        // 화면 아래쪽에 로그인 인풋이 있는 페이지.
        "/login": """
        <!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">
        <body style="margin:0">
        <div style="height:65vh;background:#eee"></div>
        <form>
        <input placeholder="userid" style="font-size:16px;width:80%;padding:12px;box-sizing:border-box">
        <input type="password" placeholder="userpw" style="font-size:16px;width:80%;padding:12px;box-sizing:border-box">
        </form>
        <div style="height:30vh"></div>
        </body>
        """,
        // 글꼴이 작아 포커스 시 자동 확대가 걸리는 로그인 페이지.
        "/login-zoom": """
        <!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">
        <body style="margin:0">
        <div style="height:65vh;background:#eee"></div>
        <form>
        <input placeholder="userid" style="font-size:12px;width:80%;padding:10px;box-sizing:border-box">
        <input type="password" placeholder="userpw" style="font-size:12px;width:80%;padding:10px;box-sizing:border-box">
        </form>
        <div style="height:30vh"></div>
        </body>
        """,
        // viewport meta가 없는 옛날 사이트 — 980px 레이아웃이라 포커스 시 크게 확대된다.
        "/login-legacy": """
        <!doctype html>
        <body style="margin:0">
        <div style="height:300px;background:#eee"></div>
        <table align="center"><tr><td>
        <form>
        <input placeholder="userid" style="font-size:12px;width:180px;padding:4px">
        <input type="password" placeholder="userpw" style="font-size:12px;width:180px;padding:4px">
        </form>
        </td></tr></table>
        <div style="height:600px"></div>
        </body>
        """,
        // 뷰포트 높이에 몸을 맞춘 페이지의 내부 스크롤러 안에 로그인 폼이 있는 변형.
        "/login-app": """
        <!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">
        <html style="height:100%"><body style="margin:0;height:100%;overflow:hidden">
        <div style="height:100%;overflow-y:scroll;-webkit-overflow-scrolling:touch">
        <div style="height:65vh;background:#eee"></div>
        <form>
        <input placeholder="userid" style="font-size:12px;width:80%;padding:10px;box-sizing:border-box">
        <input type="password" placeholder="userpw" style="font-size:12px;width:80%;padding:10px;box-sizing:border-box">
        </form>
        <div style="height:60vh"></div>
        </div>
        </body></html>
        """,
        // 광고 묶음 안에 지금은 빈 칸이 있고, 나중에 그 칸이 콘텐츠로 채워지는 페이지.
        "/ad-lazy": """
        <!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">
        <body style="margin:0">
        <div id="ads">
        <button data-ad style="display:block;width:300px;height:90px">AD1</button>
        <button data-ad style="display:block;width:300px;height:90px">AD2</button>
        <div id="later"></div>
        </div>
        <p id="main">MAINCONTENT</p>
        <script>
        setTimeout(function () {
          var ads = document.querySelectorAll("[data-ad]");
          for (var i = 0; i < ads.length; i++) if (window.__slateKill) window.__slateKill(ads[i]);
        }, 700);
        setTimeout(function () {
          document.getElementById("later").textContent = "LATECONTENT";
        }, 3000);
        </script>
        </body>
        """,
    ]

    /// 광고 묶음을 접을 때, 그 안에 나중에 채워지는 칸이 있으면 콘텐츠가 갇히면 안 된다.
    func testLateContentInsideAdBlockStaysVisible() {
        open("/ad-lazy")
        let main = app.webViews.staticTexts["MAINCONTENT"]
        XCTAssertTrue(main.waitForExistence(timeout: 10))
        // 광고가 접히면 본문이 화면 위쪽으로 올라온다.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(app.webViews.staticTexts["AD1"].isHittable, "광고가 화면에 그대로 보인다")
        // 나중에 채워진 콘텐츠는 보여야 한다.
        let late = app.webViews.staticTexts["LATECONTENT"]
        XCTAssertTrue(late.waitForExistence(timeout: 10), "접힌 묶음 안에 갇혀 안 보인다")
        XCTAssertTrue(late.isHittable, "나중에 채워진 콘텐츠가 접힌 채로 남아 있다")
    }

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

    private func open(_ path: String) {
        let address = app.textFields["addressTextField"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        // 시작 애니메이션 중 탭이 빗나가 포커스가 안 잡히는 일이 있다 — 키보드가 뜰 때까지 재시도.
        Thread.sleep(forTimeInterval: 1)
        var attempts = 0
        while !app.keyboards.firstMatch.exists, attempts < 3 {
            address.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
            attempts += 1
        }
        XCTAssertTrue(app.keyboards.firstMatch.exists, "주소창에 포커스를 잡지 못했다")
        address.typeText("http://localhost:\(Self.server.port)\(path)\n")
    }

    /// 끝 마커가 하단 바 위로 완전히 드러날 때까지 스크롤이 되는지 잰다.
    /// 더 밀어도 마커 위치가 안 움직일 때(스크롤 한계)까지 민 뒤 최종 위치로 판정한다.
    private func assertScrollReachesEnd(path: String, file: StaticString = #filePath, line: UInt = #line) {
        open(path)
        let end = app.webViews.staticTexts["ENDMARK"]
        var lastMaxY = CGFloat.greatestFiniteMagnitude
        var stuck = 0
        for _ in 0..<25 {
            app.swipeUp(velocity: .fast)
            Thread.sleep(forTimeInterval: 0.8)
            guard end.exists else { continue }
            let maxY = end.frame.maxY
            if maxY <= app.frame.maxY - 20 { break }        // 다 드러남
            if maxY >= lastMaxY - 1 { stuck += 1 } else { stuck = 0 }
            lastMaxY = maxY
            if stuck >= 2 { break }                          // 더 밀어도 안 움직임
        }
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(end.exists, "끝 마커가 화면에 나타나지 않았다", file: file, line: line)
        let gap = app.frame.maxY - end.frame.maxY
        XCTAssertGreaterThan(gap, 20, "스크롤 한계에서 콘텐츠 끝(maxY \(end.frame.maxY))이 화면 바닥(\(app.frame.maxY)) 아래 — 끝까지 못 내림", file: file, line: line)
    }

    func testDocumentScrollReachesEnd() {
        assertScrollReachesEnd(path: "/tall")
    }

    func testViewportSizedPageScrollReachesEnd() {
        assertScrollReachesEnd(path: "/app")
    }

    private func assertLoginInputAboveKeyboard(path: String, file: StaticString = #filePath, line: UInt = #line) {
        open(path)
        let field = app.webViews.textFields["userid"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), file: file, line: line)
        field.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), file: file, line: line)
        // 포커스 스크롤·확대가 끝나길 기다린다.
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(field.exists, file: file, line: line)
        let fieldBottom = field.frame.maxY
        let keyboardTop = keyboard.frame.minY
        XCTAssertLessThanOrEqual(fieldBottom, keyboardTop + 1, "인풋 바닥(\(fieldBottom))이 키보드 상단(\(keyboardTop)) 아래 — 키보드에 가려짐", file: file, line: line)
        // 하단 바는 키보드 위에 떠 있다 — 인풋이 키보드 위까지만 올라오고 바 뒤에 숨는 경우도 가림이다.
        let bar = app.textFields["addressTextField"]
        if bar.exists {
            let barTop = bar.frame.minY
            XCTAssertLessThanOrEqual(fieldBottom, barTop + 1, "인풋 바닥(\(fieldBottom))이 주소창 바 상단(\(barTop)) 아래 — 바에 가려짐", file: file, line: line)
        }
    }

    func testLoginInputStaysAboveKeyboard() {
        assertLoginInputAboveKeyboard(path: "/login")
    }

    func testZoomedLoginInputStaysAboveKeyboard() {
        assertLoginInputAboveKeyboard(path: "/login-zoom")
    }

    func testViewportSizedLoginInputStaysAboveKeyboard() {
        assertLoginInputAboveKeyboard(path: "/login-app")
    }

    func testLegacyLoginInputStaysAboveKeyboard() {
        assertLoginInputAboveKeyboard(path: "/login-legacy")
    }
}
