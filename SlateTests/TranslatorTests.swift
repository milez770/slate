import XCTest
@testable import Slate

/// 번역 줄. 떠난 문서의 묶음은 번역하지 않고, 줄은 상한을 넘지 않고, 세션이 바뀌어도 묶음을 잃지 않는다.
@MainActor
final class TranslatorTests: XCTestCase {
    /// 받은 문구 끝에 느낌표를 붙여 돌려주는 가짜 번역. 받은 묶음을 기록한다.
    private final class FakeEngine {
        var batches: [[String]] = []
        func perform(_ texts: [String]) async throws -> [String?] {
            batches.append(texts)
            return texts.map { $0 + "!" }
        }
    }

    func testStaleBatchIsReturnedWithoutTranslating() async {
        let translator = Translator()
        let engine = FakeEngine()
        async let stale = translator.translate(["떠난"], source: "ja", isCurrent: { false })
        async let live = translator.translate(["보는"], source: "ja", isCurrent: { true })
        let server = Task { await translator.serve(source: "ja", perform: engine.perform) }
        let (staleResult, liveResult) = await (stale, live)
        server.cancel()
        await server.value
        XCTAssertEqual(staleResult, [nil])
        XCTAssertEqual(liveResult, ["보는!"])
        XCTAssertEqual(engine.batches, [["보는"]], "떠난 문서의 묶음은 번역기에 안 간다")
    }

    func testQueueDropsOldestBatchOverLimit() async {
        let translator = Translator()
        var waiting: [Task<[String?], Never>] = []
        for i in 0...Translator.queueLimit {
            waiting.append(Task { await translator.translate(["\(i)"], source: "ja") })
            await Task.yield()
        }
        // 서버가 없어 아무것도 안 풀린다. 상한을 넘긴 순간 가장 오래된 묶음만 번역 없이 돌아온다.
        let dropped = await waiting[0].value
        XCTAssertEqual(dropped, [nil])
        let engine = FakeEngine()
        let server = Task { await translator.serve(source: "ja", perform: engine.perform) }
        let last = await waiting[Translator.queueLimit].value
        server.cancel()
        await server.value
        XCTAssertEqual(last, ["\(Translator.queueLimit)!"])
        XCTAssertEqual(engine.batches.count, Translator.queueLimit)
    }

    /// 세션이 닫히며 번역이 취소되면 그 묶음은 줄 맨 앞으로 돌아가고, 다음 세션이 이어받는다.
    func testCancelledBatchIsResumedByNextServer() async {
        let translator = Translator()
        async let result = translator.translate(["다음"], source: "ja")
        await translator.serve(source: "ja") { _ in throw CancellationError() }
        let engine = FakeEngine()
        let server = Task { await translator.serve(source: "ja", perform: engine.perform) }
        let value = await result
        server.cancel()
        await server.value
        XCTAssertEqual(value, ["다음!"])
    }

    /// 줄이 빈 채 기다리던 서버도 세션이 닫히면 끝난다 — 안 끝나면 다음 세션이 줄을 못 맡는다.
    func testIdleServerEndsOnCancel() async {
        let translator = Translator()
        let server = Task { await translator.serve(source: "ja") { $0.map { $0 } } }
        try? await Task.sleep(for: .milliseconds(50))
        server.cancel()
        await server.value
        let engine = FakeEngine()
        let next = Task { await translator.serve(source: "ja", perform: engine.perform) }
        let value = await translator.translate(["둘째"], source: "ja")
        next.cancel()
        await next.value
        XCTAssertEqual(value, ["둘째!"])
    }

    /// 원장에 있는 문구는 번역을 기다리지 않고 먼저 보낸다.
    func testCachedTextsAreSentBeforeTranslation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("slate-reply-\(UUID().uuidString)")
        let cache = TranslationCache(url: dir.appendingPathComponent("translations.jsonl"))
        cache.store([("있는", "있음")], source: "ja")
        let translator = Translator()
        var replies: [[[String: Any]]] = []
        let items: [[String: Any]] = [["id": 1, "text": "있는", "lang": "ja"], ["id": 2, "text": "없는", "lang": "ja"]]
        let reply = Task {
            await BrowserCoordinator.translateReply(items, translator: translator, cache: cache) { json in
                replies.append(try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]])
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(replies.count, 1, "번역을 기다리는 동안 원장 문구가 먼저 갔다")
        XCTAssertEqual(replies.first?.first?["id"] as? Int, 1)
        XCTAssertEqual(replies.first?.first?["text"] as? String, "있음")
        let engine = FakeEngine()
        let server = Task { await translator.serve(source: "ja", perform: engine.perform) }
        await reply.value
        server.cancel()
        await server.value
        XCTAssertEqual(replies.count, 2)
        XCTAssertEqual(replies.last?.first?["id"] as? Int, 2)
        XCTAssertEqual(replies.last?.first?["text"] as? String, "없는!")
    }
}
