import XCTest
@testable import Slate

final class BlockingModeStoreTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "slate-blocking-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @MainActor func testDefaultIsFull() {
        let store = BlockingModeStore(defaults: defaults())
        XCTAssertEqual(store.mode(for: URL(string: "https://site7.com/a")), .full)
        XCTAssertEqual(store.mode(for: nil), .full)
    }

    /// 사이트 단위는 등록 도메인이다 — www·m 같은 서브도메인이 달라도 같은 사이트.
    @MainActor func testModeIsSharedAcrossSubdomains() {
        let store = BlockingModeStore(defaults: defaults())
        store.set(.networkOnly, for: URL(string: "https://www.site7.com/list")!)
        XCTAssertEqual(store.mode(for: URL(string: "https://m.site7.com/detail/1")), .networkOnly)
        XCTAssertEqual(store.mode(for: URL(string: "https://other.example/")), .full)
        XCTAssertEqual(store.sites, ["site7.com"])
    }

    /// 전부 차단으로 돌리면 저장에서 빠진다 — 기본값은 적지 않는다.
    @MainActor func testSettingFullRemovesEntry() {
        let store = BlockingModeStore(defaults: defaults())
        let url = URL(string: "https://site7.com/")!
        store.set(.off, for: url)
        XCTAssertEqual(store.mode(for: url), .off)
        store.set(.full, for: url)
        XCTAssertTrue(store.sites.isEmpty)
    }

    @MainActor func testModesSurviveRestart() {
        let d = defaults()
        let a = BlockingModeStore(defaults: d)
        a.set(.off, for: URL(string: "https://site7.com/")!)
        a.set(.networkOnly, for: URL(string: "https://video.example.co.kr/x")!)
        let b = BlockingModeStore(defaults: d)
        XCTAssertEqual(b.mode(for: URL(string: "https://site7.com/")), .off)
        XCTAssertEqual(b.mode(for: URL(string: "https://www.example.co.kr/")), .networkOnly)
    }
}
