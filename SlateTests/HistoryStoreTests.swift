import XCTest
@testable import Slate

final class HistoryStoreTests: XCTestCase {
    @MainActor private func makeStore(_ name: String = #function) -> HistoryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-history-\(name)-\(UUID().uuidString).json")
        return HistoryStore(fileURL: url)
    }

    @MainActor func testRecordAppendsWithPrevLink() {
        let store = makeStore()
        let tab = UUID()
        let a = store.record(url: URL(string: "https://a.example")!, tabID: tab)
        let b = store.record(url: URL(string: "https://b.example")!, tabID: tab)
        XCTAssertEqual(store.visits.count, 2)
        XCTAssertNil(a?.prevVisitID)
        XCTAssertEqual(b?.prevVisitID, a?.id, "같은 탭 직전 방문이 사슬로 걸린다")
    }

    @MainActor func testNonWebSchemeIsIgnored() {
        let store = makeStore()
        store.record(url: URL(string: "about:blank")!, tabID: UUID())
        XCTAssertTrue(store.visits.isEmpty)
    }

    @MainActor func testReloadUpdatesDateInsteadOfNewLine() {
        let store = makeStore()
        let tab = UUID()
        let url = URL(string: "https://a.example/page")!
        store.record(url: url, tabID: tab, date: Date(timeIntervalSince1970: 100))
        store.record(url: url, tabID: tab, date: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(store.visits.count, 1, "새로고침은 새 줄이 아니다")
        XCTAssertEqual(store.visits[0].date, Date(timeIntervalSince1970: 200))
    }

    @MainActor func testFragmentOnlyChangeIsNotNewLine() {
        let store = makeStore()
        let tab = UUID()
        store.record(url: URL(string: "https://a.example/page")!, tabID: tab)
        store.record(url: URL(string: "https://a.example/page#section")!, tabID: tab)
        XCTAssertEqual(store.visits.count, 1, "페이지 안 이동은 새 줄이 아니다")
    }

    @MainActor func testRevisitAfterOtherPageIsNewLine() {
        let store = makeStore()
        let tab = UUID()
        let a = URL(string: "https://a.example")!
        store.record(url: a, tabID: tab)
        store.record(url: URL(string: "https://b.example")!, tabID: tab)
        store.record(url: a, tabID: tab)
        XCTAssertEqual(store.visits.count, 3, "뒤로 갔다 온 재방문은 시간순 줄로 남는다")
    }

    @MainActor func testSameURLInDifferentTabsAreSeparate() {
        let store = makeStore()
        let url = URL(string: "https://a.example")!
        store.record(url: url, tabID: UUID())
        store.record(url: url, tabID: UUID())
        XCTAssertEqual(store.visits.count, 2)
    }

    @MainActor func testTitleFillsMatchingLastVisitOnly() {
        let store = makeStore()
        let tab = UUID()
        store.record(url: URL(string: "https://a.example")!, tabID: tab)
        store.record(url: URL(string: "https://b.example")!, tabID: tab)
        store.updateTitle("비", url: URL(string: "https://b.example")!, tabID: tab)
        store.updateTitle("에이", url: URL(string: "https://a.example")!, tabID: tab)
        XCTAssertNil(store.visits[0].title, "마지막 방문과 주소가 다르면 안 채운다")
        XCTAssertEqual(store.visits[1].title, "비")
    }

    @MainActor func testPendingParentConsumedOnce() {
        let store = makeStore()
        let oldTab = UUID(), newTab = UUID()
        let parent = store.record(url: URL(string: "https://a.example")!, tabID: oldTab)
        store.setParent(parent!.id, forNextVisitIn: newTab)
        let first = store.record(url: URL(string: "https://b.example")!, tabID: newTab)
        let second = store.record(url: URL(string: "https://c.example")!, tabID: newTab)
        XCTAssertEqual(first?.parentVisitID, parent?.id)
        XCTAssertNil(second?.parentVisitID, "부모는 첫 방문에만 붙는다")
    }

    @MainActor func testRemoveAndRemoveAll() {
        let store = makeStore()
        let tab = UUID()
        let a = store.record(url: URL(string: "https://a.example")!, tabID: tab)
        store.record(url: URL(string: "https://b.example")!, tabID: tab)
        store.remove(a!)
        XCTAssertEqual(store.visits.count, 1)
        store.removeAll()
        XCTAssertTrue(store.visits.isEmpty)
    }

    /// 시험마다 다른 폴더를 쓴다 — history.jsonl 옆의 history-records/까지 격리하기 위해.
    private func isolatedFileURL(_ name: String = #function) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-history-\(name)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.jsonl")
    }

    private func lineCount(_ url: URL) throws -> Int {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count
    }

    @MainActor func testPersistenceRoundtrip() async {
        let url = isolatedFileURL()
        let a = HistoryStore(fileURL: url)
        let tab = UUID()
        a.record(url: URL(string: "https://a.example")!, tabID: tab)
        a.updateTitle("에이", url: URL(string: "https://a.example")!, tabID: tab)
        await a.flush()

        let b = HistoryStore(fileURL: url)
        XCTAssertEqual(b.visits.count, 1)
        XCTAssertEqual(b.visits[0].title, "에이")
        XCTAssertEqual(b.visits[0].tabID, tab)
    }

    /// 방문마다 원장 전체를 다시 쓰지 않는다 — 모아서 잠시 뒤에 쓰고, 백그라운드 진입 때는 바로 쓴다.
    @MainActor func testSaveIsDeferredUntilFlushOrDelay() async throws {
        let url = isolatedFileURL()
        let a = HistoryStore(fileURL: url)
        a.record(url: URL(string: "https://a.example")!, tabID: UUID())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "기록 직후에는 아직 파일이 없다")
        await a.flush()
        XCTAssertEqual(HistoryStore(fileURL: url).visits.count, 1, "flush는 바로 쓴다")
        a.record(url: URL(string: "https://b.example")!, tabID: UUID())
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(HistoryStore(fileURL: url).visits.count, 2, "가만히 두면 잠시 뒤 스스로 쓴다")
    }

    /// CloudKit 시스템 필드는 history.jsonl 밖의 방문별 파일에 산다.
    @MainActor func testRecordDataLivesBesideHistoryNotInside() async throws {
        let url = isolatedFileURL()
        let a = HistoryStore(fileURL: url)
        let visit = a.record(url: URL(string: "https://a.example")!, tabID: UUID())!
        let blob = Data([1, 2, 3, 4])
        a.setLastKnownRecord(blob, forVisit: visit.id)
        XCTAssertEqual(a.recordData(for: visit.id), blob)
        await a.flush()
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(json.contains(blob.base64EncodedString()), "history.jsonl에는 시스템 필드가 없다")
        XCTAssertFalse(json.contains("lastKnownRecordData"))
        XCTAssertEqual(HistoryStore(fileURL: url).recordData(for: visit.id), blob, "다시 열어도 파일에서 읽는다")
        a.setLastKnownRecord(nil, forVisit: visit.id)
        XCTAssertNil(a.recordData(for: visit.id))
    }

    @MainActor func testRemoveDeletesRecordData() {
        let a = HistoryStore(fileURL: isolatedFileURL())
        let visit = a.record(url: URL(string: "https://a.example")!, tabID: UUID())!
        a.setLastKnownRecord(Data([9]), forVisit: visit.id)
        a.remove(visit)
        XCTAssertNil(a.recordData(for: visit.id))
    }

    /// 옛 history.json(방문 안에 lastKnownRecordData가 든 형식)은 읽자마자 필드를 쓸 수 있고,
    /// 배경에서 파일로 옮긴 뒤 새 파일에 다시 쓰고 옛 파일은 지운다.
    @MainActor func testLegacyRecordDataIsReadThenMigrated() async throws {
        let url = isolatedFileURL()
        let legacyURL = url.deletingLastPathComponent().appendingPathComponent("history.json")
        let id = UUID(), tab = UUID()
        let blob = Data([7, 7, 7])
        let legacy = """
        [{"id":"\(id.uuidString)","date":0,"url":"https://a.example/","tabID":"\(tab.uuidString)",
          "lastKnownRecordData":"\(blob.base64EncodedString())"}]
        """
        try legacy.write(to: legacyURL, atomically: true, encoding: .utf8)
        let a = HistoryStore(fileURL: url)
        XCTAssertEqual(a.visits.count, 1)
        XCTAssertEqual(a.recordData(for: id), blob, "옮기기 전에도 읽힌다")
        try await Task.sleep(for: .milliseconds(1800))
        let recordFile = url.deletingLastPathComponent().appendingPathComponent("history-records/\(id.uuidString)")
        XCTAssertEqual(try Data(contentsOf: recordFile), blob, "파일로 옮겨졌다")
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(json.contains("lastKnownRecordData"), "새 파일에는 시스템 필드가 없다")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path), "옛 파일은 지웠다")
        XCTAssertEqual(HistoryStore(fileURL: url).visits.map(\.id), [id], "새 파일에서 다시 읽힌다")
    }

    // MARK: - 덧붙이기 로그

    /// 방문 하나가 바뀌면 그 줄 하나만 붙인다 — 저장마다 원장 전체를 다시 만들지 않는다.
    @MainActor func testSavingOneChangeAppendsOneLine() async throws {
        let url = isolatedFileURL()
        let a = HistoryStore(fileURL: url)
        let tab = UUID()
        for i in 0..<500 { a.record(url: URL(string: "https://a.example/\(i)")!, tabID: tab) }
        await a.flush()
        XCTAssertEqual(try lineCount(url), 500)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        a.updateTitle("제목", url: URL(string: "https://a.example/499")!, tabID: tab)
        await a.flush()
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        XCTAssertEqual(try lineCount(url), 501)
        XCTAssertLessThan(after - before, 1024, "한 줄만 붙었다")
        let b = HistoryStore(fileURL: url)
        XCTAssertEqual(b.visits.count, 500)
        XCTAssertEqual(b.visits.last?.title, "제목", "뒤 줄이 이긴다")
    }

    @MainActor func testDeletionSurvivesReload() async {
        let url = isolatedFileURL()
        let a = HistoryStore(fileURL: url)
        let tab = UUID()
        let first = a.record(url: URL(string: "https://a.example")!, tabID: tab)!
        a.record(url: URL(string: "https://b.example")!, tabID: tab)
        await a.flush()
        a.remove(first)
        await a.flush()
        XCTAssertEqual(HistoryStore(fileURL: url).visits.map(\.url), [URL(string: "https://b.example")!])
    }

    @MainActor func testRemoveAllSurvivesReload() async {
        let url = isolatedFileURL()
        let a = HistoryStore(fileURL: url)
        a.record(url: URL(string: "https://a.example")!, tabID: UUID())
        await a.flush()
        a.removeAll()
        await a.flush()
        XCTAssertTrue(HistoryStore(fileURL: url).visits.isEmpty)
    }

    /// 같은 방문을 계속 고치면 옛 줄이 쌓인다. 일정 수를 넘으면 원장 전체로 한 번 다시 써 줄을 줄인다.
    @MainActor func testOldLinesAreCompacted() async throws {
        let url = isolatedFileURL()
        let a = HistoryStore(fileURL: url)
        let tab = UUID()
        let page = URL(string: "https://a.example")!
        a.record(url: page, tabID: tab)
        for i in 0..<1100 {
            a.updateTitle("제목 \(i)", url: page, tabID: tab)
            await a.flush()
        }
        XCTAssertLessThan(try lineCount(url), 200, "다시 써서 줄이 줄었다")
        let b = HistoryStore(fileURL: url)
        XCTAssertEqual(b.visits.count, 1)
        XCTAssertEqual(b.visits[0].title, "제목 1099")
    }

    /// 쓰다 죽어 끝 줄이 반만 남아도 앞 줄은 읽히고, 다음 줄은 새 줄에서 시작한다.
    @MainActor func testSurvivesTruncatedLastLine() async throws {
        let url = isolatedFileURL()
        let a = HistoryStore(fileURL: url)
        let tab = UUID()
        a.record(url: URL(string: "https://a.example")!, tabID: tab)
        await a.flush()
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\":\"".utf8))
        try handle.close()
        let b = HistoryStore(fileURL: url)
        XCTAssertEqual(b.visits.count, 1)
        b.record(url: URL(string: "https://b.example")!, tabID: tab)
        await b.flush()
        XCTAssertEqual(HistoryStore(fileURL: url).visits.count, 2)
    }

    /// 상한을 넘으면 오래된 방문부터 지워 상한의 90%로 맞춘다.
    @MainActor func testOldestVisitsAreDroppedOverLimit() async {
        let url = isolatedFileURL()
        let a = HistoryStore(fileURL: url)
        let tab = UUID()
        let start = Date(timeIntervalSince1970: 1_000_000)
        for i in 0...HistoryStore.visitLimit {
            a.record(url: URL(string: "https://a.example/\(i)")!, tabID: tab, date: start.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(a.visits.count, HistoryStore.visitLimit * 9 / 10)
        XCTAssertEqual(a.visits.first?.url, URL(string: "https://a.example/\(HistoryStore.visitLimit / 10 + 1)")!)
        XCTAssertEqual(a.visits.last?.url, URL(string: "https://a.example/\(HistoryStore.visitLimit)")!)
        await a.flush()
        XCTAssertEqual(HistoryStore(fileURL: url).visits.count, HistoryStore.visitLimit * 9 / 10)
    }

    /// replaceState는 새 방문이 아니다 — 그 탭의 마지막 방문 주소를 고친다.
    @MainActor func testReplacingUpdatesLastVisitInPlace() {
        let store = HistoryStore(fileURL: isolatedFileURL())
        let tab = UUID()
        let first = store.record(url: URL(string: "https://a.example/watch?v=1")!, tabID: tab)!
        store.record(url: URL(string: "https://a.example/watch?v=1&t=30")!, tabID: tab, replacing: true)
        XCTAssertEqual(store.visits.count, 1)
        XCTAssertEqual(store.visits[0].id, first.id)
        XCTAssertEqual(store.visits[0].url, URL(string: "https://a.example/watch?v=1&t=30")!)
        store.record(url: URL(string: "https://a.example/watch?v=2")!, tabID: tab)
        XCTAssertEqual(store.visits.count, 2, "replaceState가 아니면 새 방문")
    }

    // MARK: - 카드 접기 (runs)

    func testRunsGroupConsecutiveVisitsPerTab() {
        let tabA = UUID(), tabB = UUID()
        let visits = [
            visit(tab: tabA, at: 0, "https://a1.example"),
            visit(tab: tabB, at: 10, "https://b1.example"),
            visit(tab: tabA, at: 20, "https://a2.example"),
        ]
        let runs = HistoryStore.runs(from: visits)
        XCTAssertEqual(runs.count, 2, "탭이 번갈아 나와도 탭별로 묶인다")
        XCTAssertEqual(runs[0].visits.map(\.url.absoluteString), ["https://a1.example", "https://a2.example"])
        XCTAssertEqual(runs[1].visits.map(\.url.absoluteString), ["https://b1.example"])
    }

    func testRunsSplitOnGap() {
        let tab = UUID()
        let visits = [
            visit(tab: tab, at: 0, "https://a.example"),
            visit(tab: tab, at: 100, "https://b.example"),
            visit(tab: tab, at: 100 + HistoryStore.runGap + 1, "https://c.example"),
        ]
        let runs = HistoryStore.runs(from: visits)
        XCTAssertEqual(runs.count, 2, "간격이 벌어지면 같은 탭이라도 카드를 끊는다")
        XCTAssertEqual(runs[0].visits.count, 1)
        XCTAssertEqual(runs[1].visits.count, 2)
    }

    func testRunsOrderedByLastVisitDescending() {
        let tabA = UUID(), tabB = UUID()
        let visits = [
            visit(tab: tabA, at: 0, "https://a.example"),
            visit(tab: tabB, at: 50, "https://b.example"),
        ]
        let runs = HistoryStore.runs(from: visits)
        XCTAssertEqual(runs[0].tabID, tabB, "마지막 방문이 늦은 카드가 위")
        XCTAssertEqual(runs[1].tabID, tabA)
    }

    private func visit(tab: UUID, at seconds: TimeInterval, _ url: String) -> Visit {
        Visit(id: UUID(), date: Date(timeIntervalSince1970: seconds), url: URL(string: url)!,
              title: nil, tabID: tab, prevVisitID: nil, parentVisitID: nil)
    }
}
