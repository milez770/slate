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

    @MainActor func testPersistenceRoundtrip() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-history-roundtrip-\(UUID().uuidString).json")
        let a = HistoryStore(fileURL: url)
        let tab = UUID()
        a.record(url: URL(string: "https://a.example")!, tabID: tab)
        a.updateTitle("에이", url: URL(string: "https://a.example")!, tabID: tab)

        let b = HistoryStore(fileURL: url)
        XCTAssertEqual(b.visits.count, 1)
        XCTAssertEqual(b.visits[0].title, "에이")
        XCTAssertEqual(b.visits[0].tabID, tab)
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
