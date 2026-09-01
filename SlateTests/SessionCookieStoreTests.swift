import WebKit
import XCTest
@testable import Slate

final class SessionCookieStoreTests: XCTestCase {
    @MainActor private func makeStore(_ name: String = #function) -> SessionCookieStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-session-cookies-\(name)-\(UUID().uuidString).plist")
        return SessionCookieStore(fileURL: url)
    }

    private func sessionCookie(name: String = "sid", domain: String = "a.example") -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: "v-\(name)", .domain: domain, .path: "/"])!
    }

    private func persistentCookie() -> HTTPCookie {
        HTTPCookie(properties: [.name: "keep", .value: "v", .domain: "a.example", .path: "/",
                                .expires: Date().addingTimeInterval(86_400)])!
    }

    func testFilterKeepsOnlySessionCookies() {
        let filtered = SessionCookieStore.sessionCookies(from: [sessionCookie(), persistentCookie()])
        XCTAssertEqual(filtered.map(\.name), ["sid"])
    }

    @MainActor func testSaveLoadRoundtrip() {
        let store = makeStore()
        store.save([sessionCookie(name: "sid"), sessionCookie(name: "auth", domain: "b.example")])
        let loaded = store.loadCookies()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(Set(loaded.map(\.name)), ["sid", "auth"])
        XCTAssertTrue(loaded.allSatisfy(\.isSessionOnly), "되살린 쿠키도 세션 쿠키여야 한다")
        XCTAssertEqual(loaded.first { $0.name == "sid" }?.value, "v-sid")
        XCTAssertEqual(loaded.first { $0.name == "auth" }?.domain, "b.example")
    }

    /// 만료일 있는 쿠키는 WebKit이 스스로 보존한다 — 파일에 섞이면 안 된다.
    @MainActor func testPersistentCookieIsNotSaved() {
        let store = makeStore()
        store.save([persistentCookie()])
        XCTAssertTrue(store.loadCookies().isEmpty)
    }

    @MainActor func testLoadWithoutFileReturnsEmpty() {
        XCTAssertTrue(makeStore().loadCookies().isEmpty)
    }

    /// 저장해 둔 세션 쿠키가 실제 쿠키 저장소에 들어간다.
    @MainActor func testRestoreInjectsIntoCookieStore() async {
        let store = makeStore()
        store.save([sessionCookie(name: "sid")])
        // 데이터 저장소를 변수로 잡아둔다 — httpCookieStore만 쥐면 저장소가 먼저 해제돼
        // 쿠키가 사라진다.
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let cookieStore = dataStore.httpCookieStore
        await store.restore(into: cookieStore)
        let cookies = await cookieStore.allCookies()
        XCTAssertTrue(cookies.contains { $0.name == "sid" && $0.domain == "a.example" })
        _ = dataStore
    }
}
