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

    private let fileURL: URL
    /// 방문별 CloudKit 시스템 필드가 사는 폴더. 파일 이름은 방문 ID. history.json과 따로 두어
    /// 방문 하나가 바뀌어도 이 덩어리들을 다시 쓰지 않는다.
    private let recordsDirectory: URL
    /// 시간 오름차순 append만 한다.
    private(set) var visits: [Visit] = []
    /// 탭별로 다음 첫 방문에 붙일 부모 방문. 되살린 탭의 새 카드를 옛 카드에 잇는 데 쓴다.
    @ObservationIgnored private var pendingParents: [UUID: UUID] = [:]
    /// 이 기기에서 방문이 바뀔 때 알린다. 동기화 층이 받아 올릴 목록에 넣는다. 서버에서
    /// 받아 반영한 변경에는 부르지 않는다 — 그대로 되돌려 보내는 꼴이 된다.
    @ObservationIgnored var onLocalChange: ((_ saved: [UUID], _ deleted: [UUID]) -> Void)?
    /// 옛 history.json에 방문과 함께 들어 있던 시스템 필드. 배경에서 파일로 옮기는 동안만 여기서 읽는다.
    @ObservationIgnored private var legacyRecordData: [UUID: Data] = [:]
    @ObservationIgnored private var saveScheduled = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let writer = JSONFileWriter()

    init(fileURL: URL) {
        self.fileURL = fileURL
        recordsDirectory = fileURL.deletingLastPathComponent()
            .appendingPathComponent("history-records", isDirectory: true)
        load()
    }

    static func defaultFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    /// 조각(#…)만 다른 주소는 같은 방문으로 본다 — 페이지 안 이동은 새 줄이 아니다.
    nonisolated static func stripFragment(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }

    /// 방문을 찍는다. 같은 탭의 마지막 방문과 주소가 같으면(새로고침·조각 이동·재시작 복원)
    /// 새 줄 대신 그 줄의 시각만 갱신한다.
    @discardableResult
    func record(url: URL, tabID: UUID, date: Date = Date()) -> Visit? {
        guard url.scheme == "http" || url.scheme == "https" else { return nil }
        if let index = visits.lastIndex(where: { $0.tabID == tabID }),
           Self.stripFragment(visits[index].url) == Self.stripFragment(url) {
            visits[index].date = date
            visits[index].url = url
            save()
            onLocalChange?([visits[index].id], [])
            return visits[index]
        }
        let visit = Visit(id: UUID(), date: date, url: url, title: nil, tabID: tabID,
                          prevVisitID: lastVisit(tabID: tabID)?.id,
                          parentVisitID: pendingParents.removeValue(forKey: tabID))
        visits.append(visit)
        save()
        onLocalChange?([visit.id], [])
        return visit
    }

    /// 페이지 제목은 로드보다 늦게 온다 — 그 탭의 마지막 방문이 같은 주소일 때만 채운다.
    func updateTitle(_ title: String, url: URL, tabID: UUID) {
        guard !title.isEmpty,
              let index = visits.lastIndex(where: { $0.tabID == tabID }),
              Self.stripFragment(visits[index].url) == Self.stripFragment(url),
              visits[index].title != title else { return }
        visits[index].title = title
        save()
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
        save()
        onLocalChange?([], ids)
    }

    func removeAll() {
        let removed = visits.map(\.id)
        visits.removeAll()
        SnapshotStore.shared.deleteAll()
        legacyRecordData.removeAll()
        try? FileManager.default.removeItem(at: recordsDirectory)
        save()
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
        save()
    }

    /// 서버에서 지워진 방문을 이 기기에서도 지운다.
    func removeFromServer(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let targets = Set(ids)
        visits.removeAll { targets.contains($0.id) }
        SnapshotStore.shared.delete(ids)
        deleteRecordData(ids)
        save()
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

    /// history.json 크기(바이트). 설정 화면 표시용.
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

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode([StoredVisit].self, from: data) else {
            Self.logger.error("load(): history.json decode failed")
            return
        }
        visits = decoded.map(\.visit)
        for stored in decoded {
            if let blob = stored.lastKnownRecordData { legacyRecordData[stored.id] = blob }
        }
        if !legacyRecordData.isEmpty { migrateLegacyRecordData() }
    }

    /// 옛 파일에서 뽑은 시스템 필드를 배경에서 파일로 옮긴다. 끝나면 history.json을 가벼운 형식으로 다시 쓴다.
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
            self.save()
        }
    }

    /// 변경을 모아 잠시 뒤 배경에서 쓴다. 방문마다 원장 전체를 메인 스레드에서 다시 쓰지 않는다.
    private func save() {
        generation += 1
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard let self else { return }
            self.saveScheduled = false
            await self.flush()
        }
    }

    /// 지금 상태를 바로 쓴다. 백그라운드로 빠질 때 부른다 — iOS가 앱을 죽여도 마지막 방문이 남는다.
    func flush() async {
        await writer.write(visits, generation: generation, to: fileURL)
    }
}
