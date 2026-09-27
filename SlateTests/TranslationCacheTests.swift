import XCTest
@testable import Slate

@MainActor
final class TranslationCacheTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-translation-cache-\(UUID().uuidString)")
            .appendingPathComponent("translations.jsonl")
    }

    private func lineCount(_ url: URL) -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        return data.split(separator: UInt8(ascii: "\n")).count
    }

    func testStoreLookupAndPersist() async {
        let url = tempURL()
        let cache = TranslationCache(url: url)
        XCTAssertNil(cache.lookup("こんにちは", source: "ja"))
        cache.store([("こんにちは", "안녕하세요")], source: "ja")
        XCTAssertEqual(cache.lookup("こんにちは", source: "ja"), "안녕하세요")
        XCTAssertNil(cache.lookup("こんにちは", source: "zh-Hans"), "원어가 다르면 다른 항목")
        await cache.flush()
        let reloaded = TranslationCache(url: url)
        XCTAssertEqual(reloaded.lookup("こんにちは", source: "ja"), "안녕하세요")
    }

    /// 저장은 새 항목만 파일 끝에 붙인다 — 두 번 저장하면 줄이 셋, 전체를 다시 쓰지 않는다.
    func testAppendsOnlyNewEntries() async {
        let url = tempURL()
        let cache = TranslationCache(url: url)
        cache.store([("一", "하나")], source: "zh-Hans")
        await cache.flush()
        XCTAssertEqual(lineCount(url), 1)
        cache.store([("二", "둘"), ("三", "셋")], source: "zh-Hans")
        await cache.flush()
        XCTAssertEqual(lineCount(url), 3)
        let reloaded = TranslationCache(url: url)
        XCTAssertEqual(reloaded.count, 3)
        XCTAssertEqual(reloaded.lookup("三", source: "zh-Hans"), "셋")
    }

    /// 같은 문구를 다시 번역하면 뒤 줄이 앞 줄을 덮는다.
    func testLaterLineWins() async {
        let url = tempURL()
        let cache = TranslationCache(url: url)
        cache.store([("猫", "고양이")], source: "ja")
        await cache.flush()
        cache.store([("猫", "냥이")], source: "ja")
        await cache.flush()
        XCTAssertEqual(TranslationCache(url: url).lookup("猫", source: "ja"), "냥이")
    }

    func testTrimsWhenOverLimitAndRewritesFile() async {
        let url = tempURL()
        let cache = TranslationCache(url: url)
        let pairs = (0...TranslationCache.limit).map { (String($0), "t") }
        cache.store(pairs, source: "ja")
        XCTAssertLessThanOrEqual(cache.count, TranslationCache.limit / 2 + 1)
        await cache.flush()
        XCTAssertEqual(lineCount(url), cache.count, "잘라냈으면 파일도 남은 항목만큼만")
    }

    /// 쓰다 죽어 마지막 줄이 반만 남았어도 앞 줄은 읽고, 다음 저장은 새 줄에서 시작한다.
    func testSurvivesTruncatedLastLine() async throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[\"ja\\u0001犬\",\"개\"]\n[\"ja\\u0001鳥\",\"새".utf8).write(to: url)
        let cache = TranslationCache(url: url)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.lookup("犬", source: "ja"), "개")
        cache.store([("魚", "물고기")], source: "ja")
        await cache.flush()
        let reloaded = TranslationCache(url: url)
        XCTAssertEqual(reloaded.lookup("犬", source: "ja"), "개")
        XCTAssertEqual(reloaded.lookup("魚", source: "ja"), "물고기")
    }

    /// 옛 translations.json(사전 통짜)이 있으면 읽어 들이고, 새 파일을 쓴 뒤 옛 파일을 지운다.
    func testAdoptsLegacyDictionaryFile() async throws {
        let url = tempURL()
        let legacy = url.deletingLastPathComponent().appendingPathComponent("translations.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(["ja\u{1}水": "물"]).write(to: legacy)
        let cache = TranslationCache(url: url)
        XCTAssertEqual(cache.lookup("水", source: "ja"), "물")
        await cache.flush()
        XCTAssertEqual(lineCount(url), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }
}
