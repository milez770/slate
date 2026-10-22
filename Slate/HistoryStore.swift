import Foundation
import Observation
import os

/// 방문 기록 한 줄. 탭 ID로 병렬(어느 탭), prevVisitID로 리니어(같은 탭 안 직전),
/// parentVisitID로 가지(이 탭을 낳은 방문 — 되살리기 연결)를 복원한다.
struct Visit: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var date: Date
    var url: URL
    var title: String?
    let tabID: UUID
    var prevVisitID: UUID?
    var parentVisitID: UUID?
}

/// 같은 탭에서 연속으로 이어진 방문 묶음. 타임라인 카드 하나가 이것 하나다.
struct HistoryRun: Identifiable {
    let tabID: UUID
    /// 시간 오름차순.
    var visits: [Visit]
    var id: UUID { visits.last!.id }
    var last: Visit { visits.last! }
    var first: Visit { visits.first! }
}

@MainActor
@Observable
final class HistoryStore {
    static let shared = HistoryStore(fileURL: defaultFileURL())
    private static let logger = Logger(subsystem: "com.wonseon.slate", category: "history")
    /// 같은 탭이라도 이 시간 넘게 비면 카드를 끊는다.
    nonisolated static let runGap: TimeInterval = 3600
    /// 연속 변경을 한 번의 쓰기로 모으는 시간.
    nonisolated static let saveDelay: Duration = .seconds(1)
    /// 방문 수 상한. 원장 전체가 메모리에 살고 타임라인이 통째로 읽는다. 넘으면 오래된 방문부터
    /// 지워 상한의 90%로 맞춘다 — 방문 하나 늘 때마다 하나씩 지우지 않게.
    nonisolated static let visitLimit = 20_000

    /// 방문 기록 파일. 줄마다 방문 하나 또는 지운 방문 ID 목록 하나인 덧붙이기 로그다 — 바뀐
    /// 방문만 끝에 붙인다. 저장마다 원장 전체를 JSON으로 만들면 방문 수에 비례하는 메모리를
    /// 매번 새로 잡아(5만 개면 70MB 남짓), 메모리가 빠듯한 순간 할당이 실패해 앱이 죽는다.
    private let fileURL: URL
    /// 옛 형식(방문 배열 하나를 통째로 담은 history.json). 읽어 들인 뒤 새 파일을 다 쓰면 지운다.
    private let legacyURL: URL
    /// 방문별 CloudKit 시스템 필드가 사는 폴더. 파일 이름은 방문 ID. history.jsonl과 따로 두어
    /// 방문 하나가 바뀌어도 이 덩어리들을 다시 쓰지 않는다.
    private let recordsDirectory: URL
    /// 시간 오름차순.
    private(set) var visits: [Visit] = []
    /// 탭별로 다음 첫 방문에 붙일 부모 방문. 되살린 탭의 새 카드를 옛 카드에 잇는 데 쓴다.
    @ObservationIgnored private var pendingParents: [UUID: UUID] = [:]
    /// 이 기기에서 방문이 바뀔 때 알린다. 동기화 층이 받아 올릴 목록에 넣는다. 서버에서
    /// 받아 반영한 변경에는 부르지 않는다 — 그대로 되돌려 보내는 꼴이 된다.
    @ObservationIgnored var onLocalChange: ((_ saved: [UUID], _ deleted: [UUID]) -> Void)?
    /// 옛 history.json에 방문과 함께 들어 있던 시스템 필드. 배경에서 파일로 옮기는 동안만 여기서 읽는다.
    @ObservationIgnored private var legacyRecordData: [UUID: Data] = [:]
    /// 다음 쓰기에 실을 방문. 고친 것과 지운 것.
    @ObservationIgnored private var changedIDs: Set<UUID> = []
    @ObservationIgnored private var deletedIDs: Set<UUID> = []
    /// 파일을 원장 전체로 새로 써야 한다. 옛 줄이 쌓였거나 전부 지웠을 때.
    @ObservationIgnored private var needsRewrite = false
    /// 파일에 쌓인 줄 수. 다시 쓸 때를 정하는 기준.
    @ObservationIgnored private var linesOnDisk = 0
    @ObservationIgnored private var flushScheduled = false
    /// 마지막 쓰기. 쓰기는 하나씩 차례로 한다 — 다시 쓰기와 덧붙이기가 엇갈리면 붙인 줄이 지워진다.
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// 옛 파일을 읽어 들였고 아직 지우지 않았다.
    @ObservationIgnored private var legacyPending = false
    @ObservationIgnored private var legacyWritten = false
    @ObservationIgnored private let writer = VisitLogWriter()

    init(fileURL: URL) {
        self.fileURL = fileURL
        let dir = fileURL.deletingLastPathComponent()
        legacyURL = dir.appendingPathComponent("history.json")
        recordsDirectory = dir.appendingPathComponent("history-records", isDirectory: true)
        load()
    }

    static func defaultFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.jsonl")
    }

    /// 조각(#…)만 다른 주소는 같은 방문으로 본다 — 페이지 안 이동은 새 줄이 아니다.
    nonisolated static func stripFragment(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }

    /// 방문을 찍는다. 같은 탭의 마지막 방문과 주소가 같으면(새로고침·조각 이동·재시작 복원)
    /// 새 줄 대신 그 줄의 시각만 갱신한다. replacing은 페이지가 뒤로가기 항목을 새로 만들지 않고
    /// 주소만 고친 경우(history.replaceState)다 — 그 탭의 마지막 방문을 새 주소로 고친다.
    @discardableResult
    func record(url: URL, tabID: UUID, date: Date = Date(), replacing: Bool = false) -> Visit? {
        guard url.scheme == "http" || url.scheme == "https" else { return nil }
        if let index = visits.lastIndex(where: { $0.tabID == tabID }),
           replacing || Self.stripFragment(visits[index].url) == Self.stripFragment(url) {
            visits[index].date = date
            visits[index].url = url
            markChanged([visits[index].id])
            onLocalChange?([visits[index].id], [])
            return visits[index]
        }
        let visit = Visit(id: UUID(), date: date, url: url, title: nil, tabID: tabID,
                          prevVisitID: lastVisit(tabID: tabID)?.id,
                          parentVisitID: pendingParents.removeValue(forKey: tabID))
        visits.append(visit)
        markChanged([visit.id])
        onLocalChange?([visit.id], [])
        trimToLimit()
        return visit
    }

    /// 페이지 제목은 로드보다 늦게 온다 — 그 탭의 마지막 방문이 같은 주소일 때만 채운다.
    func updateTitle(_ title: String, url: URL, tabID: UUID) {
        guard !title.isEmpty,
              let index = visits.lastIndex(where: { $0.tabID == tabID }),
              Self.stripFragment(visits[index].url) == Self.stripFragment(url),
              visits[index].title != title else { return }
        visits[index].title = title
        markChanged([visits[index].id])
        onLocalChange?([visits[index].id], [])
    }

    /// tabID 탭의 다음 첫 방문에 부모 방문을 붙인다. 방문이 찍히기 전에 탭이 죽으면 그냥 버려진다.
    func setParent(_ parentVisitID: UUID, forNextVisitIn tabID: UUID) {
        pendingParents[tabID] = parentVisitID
    }

    func lastVisit(tabID: UUID) -> Visit? {
        visits.last { $0.tabID == tabID }
    }

    func visit(id: UUID) -> Visit? {
        visits.first { $0.id == id }
    }

    func remove(_ visit: Visit) {
        remove(ids: [visit.id])
    }

    /// 방문 여러 개를 한 번에 지운다. 타임라인의 그룹 삭제가 쓴다.
    func remove(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let targets = Set(ids)
        visits.removeAll { targets.contains($0.id) }
        SnapshotStore.shared.delete(ids)
        deleteRecordData(ids)
        markDeleted(ids)
        onLocalChange?([], ids)
    }

    func removeAll() {
        let removed = visits.map(\.id)
        visits.removeAll()
        SnapshotStore.shared.deleteAll()
        legacyRecordData.removeAll()
        try? FileManager.default.removeItem(at: recordsDirectory)
        needsRewrite = true
        scheduleFlush()
        onLocalChange?([], removed)
    }

    // MARK: - 동기화

    /// 서버에서 받은 방문을 반영한다. 같은 id가 있으면 갈아 끼우고 없으면 끼워 넣는다.
    /// 이 경로는 onLocalChange를 부르지 않는다 — 받은 걸 그대로 되돌려 보내지 않는다.
    func mergeFromServer(_ incoming: [Visit]) {
        guard !incoming.isEmpty else { return }
        for visit in incoming {
            if let index = visits.firstIndex(where: { $0.id == visit.id }) {
                visits[index] = visit
            } else {
                visits.append(visit)
            }
        }
        // 원장은 시간 오름차순이 전제다 — 다른 기기 것이 섞이면 순서가 깨진다.
        visits.sort { $0.date < $1.date }
        markChanged(incoming.map(\.id))
        trimToLimit()
    }

    /// 서버에서 지워진 방문을 이 기기에서도 지운다.
    func removeFromServer(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let targets = Set(ids)
        visits.removeAll { targets.contains($0.id) }
        SnapshotStore.shared.delete(ids)
        deleteRecordData(ids)
        markDeleted(ids)
    }

    /// 동기화 층이 올릴 레코드를 만들 때 쓴다.
    func visit(withID id: UUID) -> Visit? {
        visits.first { $0.id == id }
    }

    /// 방문의 CloudKit 시스템 필드. 이걸 실어 보내야 서버가 같은 레코드의 갱신으로 알아본다.
    func recordData(for id: UUID) -> Data? {
        if let data = try? Data(contentsOf: recordsDirectory.appendingPathComponent(id.uuidString)) {
            return data
        }
        return legacyRecordData[id]
    }

    /// 서버가 준 레코드의 시스템 필드를 방문 옆 파일로 둔다. history.json은 건드리지 않는다.
    func setLastKnownRecord(_ data: Data?, forVisit id: UUID) {
        legacyRecordData.removeValue(forKey: id)
        let url = recordsDirectory.appendingPathComponent(id.uuidString)
        guard let data else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try FileManager.default.createDirectory(at: recordsDirectory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("setLastKnownRecord(): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deleteRecordData(_ ids: [UUID]) {
        for id in ids {
            legacyRecordData.removeValue(forKey: id)
            try? FileManager.default.removeItem(at: recordsDirectory.appendingPathComponent(id.uuidString))
        }
    }

    /// 이 기기에 쌓인 방문 전부를 올릴 대상으로 내놓는다. 동기화를 처음 켤 때 쓴다.
    var allIDs: [UUID] { visits.map(\.id) }

    /// history.jsonl 크기(바이트). 설정 화면 표시용.
    var fileSize: Int {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
    }

    /// 방문들을 카드 묶음으로 접는다. 같은 탭의 연속 방문이 한 묶음, 간격이 gap을 넘으면
    /// 끊는다. 결과는 마지막 방문 시각 내림차순 — 타임라인이 그대로 그린다.
    nonisolated static func runs(from visits: [Visit], gap: TimeInterval = HistoryStore.runGap) -> [HistoryRun] {
        var finished: [HistoryRun] = []
        var current: [UUID: HistoryRun] = [:]
        for visit in visits.sorted(by: { $0.date < $1.date }) {
            if var run = current[visit.tabID] {
                if visit.date.timeIntervalSince(run.last.date) > gap {
                    finished.append(run)
                    current[visit.tabID] = HistoryRun(tabID: visit.tabID, visits: [visit])
                } else {
                    run.visits.append(visit)
                    current[visit.tabID] = run
                }
            } else {
                current[visit.tabID] = HistoryRun(tabID: visit.tabID, visits: [visit])
            }
        }
        finished.append(contentsOf: current.values)
        return finished.sorted { $0.last.date > $1.last.date }
    }

    // MARK: - 저장

    /// 파일에 적힌 방문 한 줄. 옛 파일은 방문마다 CloudKit 시스템 필드를 base64로 품고 있다.
    private struct StoredVisit: Decodable {
        let id: UUID
        var date: Date
        var url: URL
        var title: String?
        let tabID: UUID
        var prevVisitID: UUID?
        var parentVisitID: UUID?
        var lastKnownRecordData: Data?

        var visit: Visit {
            Visit(id: id, date: date, url: url, title: title, tabID: tabID,
                  prevVisitID: prevVisitID, parentVisitID: parentVisitID)
        }
    }

    /// 파일 한 줄. 지운 방문 ID 목록이거나 방문 하나다.
    private struct LogLine: Decodable {
        var deleted: [UUID]?
        var visit: Visit?

        private enum CodingKeys: String, CodingKey { case deleted }

        init(from decoder: Decoder) throws {
            deleted = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([UUID].self, forKey: .deleted)
            if deleted == nil { visit = try Visit(from: decoder) }
        }
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL, options: .alwaysMapped) {
            readLog(data)
        } else {
            adoptLegacyFile()
        }
        trimToLimit()
    }

    /// 줄을 차례로 반영한다. 같은 방문이 여러 번 나오면 뒤 줄이 이긴다.
    private func readLog(_ data: Data) {
        let decoder = JSONDecoder()
        var order: [UUID] = []
        var byID: [UUID: Visit] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            // 쓰다 죽어 반만 남은 줄은 건너뛴다.
            guard let entry = try? decoder.decode(LogLine.self, from: line) else { continue }
            linesOnDisk += 1
            if let deleted = entry.deleted {
                for id in deleted { byID.removeValue(forKey: id) }
            } else if let visit = entry.visit {
                if byID.updateValue(visit, forKey: visit.id) == nil { order.append(visit.id) }
            }
        }
        // 같은 시각이면 파일에 먼저 나온 쪽이 앞이다.
        visits = order.compactMap { byID.removeValue(forKey: $0) }
            .enumerated()
            .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map(\.element)
    }

    /// 옛 history.json을 읽는다. 새 파일을 통째로 한 번 쓰고, 시스템 필드도 다 옮긴 뒤에 지운다.
    private func adoptLegacyFile() {
        guard let data = try? Data(contentsOf: legacyURL) else { return }
        guard let decoded = try? JSONDecoder().decode([StoredVisit].self, from: data) else {
            Self.logger.error("load(): history.json decode failed")
            return
        }
        visits = decoded.map(\.visit)
        for stored in decoded {
            if let blob = stored.lastKnownRecordData { legacyRecordData[stored.id] = blob }
        }
        legacyPending = true
        needsRewrite = true
        scheduleFlush()
        if !legacyRecordData.isEmpty { migrateLegacyRecordData() }
    }

    /// 옛 파일에서 뽑은 시스템 필드를 배경에서 파일로 옮긴다.
    private func migrateLegacyRecordData() {
        let pending = legacyRecordData
        let directory = recordsDirectory
        Self.logger.log("시스템 필드 \(pending.count)개를 history-records/로 옮긴다")
        Task { @MainActor [weak self] in
            await Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for (id, blob) in pending {
                    try? blob.write(to: directory.appendingPathComponent(id.uuidString), options: .atomic)
                }
            }.value
            guard let self else { return }
            for id in pending.keys { self.legacyRecordData.removeValue(forKey: id) }
            // 옛 파일을 지울 수 있는지 쓰기 회차가 판단한다.
            self.scheduleFlush()
        }
    }

    /// 상한을 넘었으면 오래된 방문부터 지운다. 다른 기기에서도 지워진다.
    private func trimToLimit() {
        guard visits.count > Self.visitLimit else { return }
        let excess = visits.count - Self.visitLimit * 9 / 10
        let oldest = visits.sorted { $0.date < $1.date }.prefix(excess).map(\.id)
        Self.logger.log("방문 상한을 넘어 오래된 \(oldest.count)개를 지운다")
        remove(ids: Array(oldest))
    }

    // MARK: - 쓰기

    private func markChanged(_ ids: [UUID]) {
        for id in ids {
            deletedIDs.remove(id)
            changedIDs.insert(id)
        }
        scheduleFlush()
    }

    private func markDeleted(_ ids: [UUID]) {
        for id in ids {
            changedIDs.remove(id)
            deletedIDs.insert(id)
        }
        scheduleFlush()
    }

    /// 변경을 모아 잠시 뒤 배경에서 쓴다.
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard let self else { return }
            self.flushScheduled = false
            await self.flush()
        }
    }

    /// 모아 둔 변경을 지금 쓴다. 백그라운드로 빠질 때 부른다 — iOS가 앱을 죽여도 마지막 방문이 남는다.
    func flush() async {
        let previous = flushTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.drain()
        }
        flushTask = task
        await task.value
    }

    /// 바뀐 방문만 덧붙인다. 옛 줄이 살아 있는 방문의 두 배를 넘으면 원장 전체로 한 번 다시 쓴다.
    /// 쓰기에 실패하면 다음 회차가 전체를 다시 쓴다 — 덧붙이지 못한 줄을 잃지 않게.
    private func drain() async {
        while needsRewrite || !changedIDs.isEmpty || !deletedIDs.isEmpty {
            if needsRewrite {
                needsRewrite = false
                changedIDs.removeAll()
                deletedIDs.removeAll()
                let snapshot = visits
                guard await writer.rewrite(snapshot, to: fileURL) else {
                    needsRewrite = true
                    return
                }
                linesOnDisk = snapshot.count
                legacyWritten = true
            } else {
                let changed = changedIDs
                let deleted = Array(deletedIDs)
                changedIDs.removeAll()
                deletedIDs.removeAll()
                let rows = visits.filter { changed.contains($0.id) }
                guard await writer.append(rows, deleted: deleted, to: fileURL) else {
                    needsRewrite = true
                    return
                }
                linesOnDisk += rows.count + (deleted.isEmpty ? 0 : 1)
                if linesOnDisk > max(visits.count * 2, 1_000) { needsRewrite = true }
            }
        }
        if legacyPending, legacyWritten, legacyRecordData.isEmpty {
            try? FileManager.default.removeItem(at: legacyURL)
            legacyPending = false
        }
    }
}

/// 방문 기록 파일을 쓰는 배경 일꾼. 덧붙이기와 전체 다시 쓰기 둘뿐이다.
actor VisitLogWriter {
    private static let logger = Logger(subsystem: "com.wonseon.slate", category: "history-log")

    private struct Deletion: Encodable {
        let deleted: [UUID]
    }

    func append(_ visits: [Visit], deleted: [UUID], to url: URL) -> Bool {
        do {
            var data = try Self.lines(visits[...])
            if !deleted.isEmpty {
                data.append(try JSONEncoder().encode(Deletion(deleted: deleted)))
                data.append(LineLog.newline)
            }
            try LineLog.append(data, to: url)
            return true
        } catch {
            Self.logger.error("append: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 원장 전체로 파일을 새로 쓴다. 천 줄씩 만들어 쓴다 — 한 번에 만들면 원장 크기만큼 잡는다.
    func rewrite(_ visits: [Visit], to url: URL) -> Bool {
        do {
            try LineLog.rewrite(url) { handle in
                var start = 0
                while start < visits.count {
                    let end = min(start + 1000, visits.count)
                    try handle.write(contentsOf: Self.lines(visits[start..<end]))
                    start = end
                }
            }
            return true
        } catch {
            Self.logger.error("rewrite: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func lines(_ visits: ArraySlice<Visit>) throws -> Data {
        let encoder = JSONEncoder()
        var data = Data()
        for visit in visits {
            data.append(try encoder.encode(visit))
            data.append(LineLog.newline)
        }
        return data
    }

}
