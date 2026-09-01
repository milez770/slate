import XCTest
@testable import Slate

@MainActor
final class TranslationCacheTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-translation-cache-\(UUID().uuidString)")
            .appendingPathComponent("translations.json")
    }

    func testStoreLookupAndPersist() {
        let url = tempURL()
        let cache = TranslationCache(url: url)
        XCTAssertNil(cache.lookup("こんにちは", source: "ja"))
        cache.store([("こんにちは", "안녕하세요")], source: "ja")
        XCTAssertEqual(cache.lookup("こんにちは", source: "ja"), "안녕하세요")
        XCTAssertNil(cache.lookup("こんにちは", source: "zh-Hans"), "원어가 다르면 다른 항목")
        cache.save()
        let reloaded = TranslationCache(url: url)
        XCTAssertEqual(reloaded.lookup("こんにちは", source: "ja"), "안녕하세요")
    }

    func testTrimsWhenOverLimit() {
        let cache = TranslationCache(url: tempURL())
        let pairs = (0...TranslationCache.limit).map { (String($0), "t") }
        cache.store(pairs, source: "ja")
        XCTAssertLessThanOrEqual(cache.count, TranslationCache.limit / 2 + 1)
    }
}
