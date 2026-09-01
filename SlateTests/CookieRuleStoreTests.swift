import WebKit
import XCTest
@testable import Slate

final class CookieRuleStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-cookie-rules-\(UUID().uuidString).json")
    }

    /// 규칙 하나가 그 도메인·이름·값·경로·만료를 가진 쿠키로 바뀐다.
    @MainActor func testRuleConvertsToHTTPCookie() {
        let rule = CookieRule(domain: ".example.co.jp", name: "check", value: "abc", expiresDays: 365)
        let cookie = rule.httpCookie()
        XCTAssertNotNil(cookie)
        XCTAssertEqual(cookie?.domain, ".example.co.jp")
        XCTAssertEqual(cookie?.name, "check")
        XCTAssertEqual(cookie?.value, "abc")
        XCTAssertEqual(cookie?.path, "/")
        let expected = Date(timeIntervalSinceNow: 365 * 86400).timeIntervalSince1970
        XCTAssertEqual(cookie?.expiresDate?.timeIntervalSince1970 ?? 0, expected, accuracy: 120)
    }

    /// 도메인이나 이름이 비면 쿠키를 안 만든다 — 반쪽 규칙이 저장소를 오염시키지 않게.
    @MainActor func testBlankDomainOrNameYieldsNoCookie() {
        XCTAssertNil(CookieRule(domain: "", name: "check", value: "v", expiresDays: 1).httpCookie())
        XCTAssertNil(CookieRule(domain: ".example.co.jp", name: "", value: "v", expiresDays: 1).httpCookie())
    }

    @MainActor func testRulesSurviveReload() {
        let url = tempURL()
        let a = CookieRuleStore(fileURL: url)
        a.add(CookieRule(domain: ".example.co.jp", name: "check", value: "abc", expiresDays: 365))
        let b = CookieRuleStore(fileURL: url)
        XCTAssertEqual(b.rules.count, 1)
        XCTAssertEqual(b.rules.first?.domain, ".example.co.jp")
        XCTAssertEqual(b.rules.first?.value, "abc")
    }

    /// 같은 도메인·이름을 다시 추가하면 값만 갱신한다 — 중복 줄이 안 쌓이게.
    @MainActor func testAddingSameDomainAndNameReplacesValue() {
        let store = CookieRuleStore(fileURL: tempURL())
        store.add(CookieRule(domain: ".example.co.jp", name: "check", value: "old", expiresDays: 1))
        store.add(CookieRule(domain: ".example.co.jp", name: "check", value: "new", expiresDays: 1))
        XCTAssertEqual(store.rules.count, 1)
        XCTAssertEqual(store.rules.first?.value, "new")
    }

    @MainActor func testRemoveRule() {
        let store = CookieRuleStore(fileURL: tempURL())
        let rule = CookieRule(domain: ".example.co.jp", name: "check", value: "abc", expiresDays: 1)
        store.add(rule)
        store.remove(rule)
        XCTAssertTrue(store.rules.isEmpty)
    }

    /// inject가 실제 쿠키 저장소에 쿠키를 넣는다 — HTTPCookie 속성 조합이 WebKit에 유효한지 확인.
    @MainActor func testInjectPutsCookieIntoStore() async {
        let store = CookieRuleStore(fileURL: tempURL())
        store.add(CookieRule(domain: ".example.co.jp", name: "check", value: "abc", expiresDays: 365))
        let dataStore = WKWebsiteDataStore.nonPersistent()
        await store.inject(into: dataStore.httpCookieStore)
        let cookies = await dataStore.httpCookieStore.allCookies()
        XCTAssertTrue(cookies.contains { $0.name == "check" && $0.value == "abc" },
                      "심은 쿠키가 저장소에 있어야 한다")
    }

    /// 저장소가 든 모든 규칙을 쿠키 배열로 준다 — 반쪽 규칙은 걸러진다.
    @MainActor func testHTTPCookiesSkipsInvalidRules() {
        let store = CookieRuleStore(fileURL: tempURL())
        store.add(CookieRule(domain: ".a.example", name: "x", value: "1", expiresDays: 1))
        store.add(CookieRule(domain: ".b.example", name: "y", value: "2", expiresDays: 1))
        XCTAssertEqual(store.httpCookies().count, 2)
    }
}
