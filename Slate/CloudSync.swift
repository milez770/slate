import CloudKit
import Foundation
import os

/// 방문 기록을 각 사용자의 iCloud(private database)에 넣고 기기 사이를 맞춘다. 데이터는
/// 그 사람 계정에 들어가므로 개발자는 볼 수 없다. 주소·제목은 encryptedValues로 올린다 —
/// 기기에서 암호화되고, 고급 데이터 보호를 켠 계정에서는 종단간 암호화가 된다.
///
/// 로컬 저장은 그대로 history.jsonl이다. 이 층은 변경분을 올리고 내려받아 원장에 반영만 한다.
/// 레코드의 시스템 필드는 HistoryStore가 방문별 파일(history-records/)로 들고 있다.
@MainActor
final class CloudSync: NSObject {
    static let shared = CloudSync()
    private static let logger = Logger(subsystem: "com.wonseon.slate", category: "cloudsync")
    private static let containerID = "iCloud.com.wonseon.slate"
    private static let enabledKey = "slate.icloud.sync"
    /// 방문 레코드를 담는 존. 기본 존은 변경 추적이 안 되므로 따로 판다.
    static let zoneName = "slate"
    static let visitRecordType: CKRecord.RecordType = "Visit"
    static let rulesRecordType: CKRecord.RecordType = "SiteRules"

    private let history: HistoryStore
    private let ruleStore: SiteRuleStore
    private let defaults: UserDefaults
    private let stateURL: URL
    /// 규칙 레코드의 서버 시스템 필드. 호스트별로 들고 있어야 갱신으로 인식된다.
    private var ruleRecordMeta: [String: Data] = [:]
    private var ruleMetaURL: URL {
        stateURL.deletingLastPathComponent().appendingPathComponent("sync-rules-meta.plist")
    }
    private var engine: CKSyncEngine?
    /// 아직 안 쓴 엔진 상태. 상태는 바뀔 때마다 통째로 오고 올릴 목록이 길수록 크다 — 1초 모아
    /// 마지막 것만 쓴다.
    private var pendingState: CKSyncEngine.State.Serialization?
    private var stateSaveScheduled = false

    private static var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName) }
    private static func recordID(_ visitID: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: visitID.uuidString, zoneID: zoneID)
    }

    init(history: HistoryStore = .shared, ruleStore: SiteRuleStore = .shared,
         defaults: UserDefaults = .standard, stateURL: URL = CloudSync.defaultStateURL()) {
        self.history = history
        self.ruleStore = ruleStore
        self.defaults = defaults
        self.stateURL = stateURL
        super.init()
        if let data = try? Data(contentsOf: ruleMetaURL),
           let decoded = try? PropertyListDecoder().decode([String: Data].self, from: data) {
            ruleRecordMeta = decoded
        }
    }

    private func saveRuleMeta() {
        if let data = try? PropertyListEncoder().encode(ruleRecordMeta) {
            try? data.write(to: ruleMetaURL, options: .atomic)
        }
    }

    /// 규칙 레코드 이름. 방문은 UUID, 규칙은 "rules|호스트"로 갈라 같은 존을 쓴다.
    private static func ruleRecordID(_ host: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "rules|\(host)", zoneID: zoneID)
    }

    private static func host(fromRecordName name: String) -> String? {
        name.hasPrefix("rules|") ? String(name.dropFirst(6)) : nil
    }

    nonisolated static func defaultStateURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("sync-state.dat")
    }

    /// 켜짐 여부. 처음 실행은 켜짐으로 시작한다.
    var isEnabled: Bool {
        get {
            if defaults.object(forKey: Self.enabledKey) == nil { return true }
            return defaults.bool(forKey: Self.enabledKey)
        }
        set {
            defaults.set(newValue, forKey: Self.enabledKey)
            if newValue {
                start()
            } else {
                stop()
            }
        }
    }

    /// 앱이 뜰 때 한 번 부른다. iCloud 계정이 없으면 아무것도 하지 않는다 — 앱은 로컬로 돈다.
    func start() {
        guard isEnabled, engine == nil else { return }
        history.onLocalChange = { [weak self] saved, deleted in
            self?.enqueue(saved: saved, deleted: deleted)
        }
        ruleStore.onLocalChange = { [weak self] saved, deleted in
            self?.enqueueRules(saved: saved, deleted: deleted)
        }
        var configuration = CKSyncEngine.Configuration(
            database: CKContainer(identifier: Self.containerID).privateCloudDatabase,
            stateSerialization: loadState(),
            delegate: self
        )
        configuration.automaticallySync = true
        Task {
            let status = try? await CKContainer(identifier: Self.containerID).accountStatus()
            let name: String
            switch status {
            case .available: name = "available"
            case .noAccount: name = "noAccount"
            case .restricted: name = "restricted"
            case .couldNotDetermine: name = "couldNotDetermine"
            case .temporarilyUnavailable: name = "temporarilyUnavailable"
            default: name = "unknown"
            }
            Self.logger.log("iCloud 계정 상태: \(name, privacy: .public)")
        }
        let isFirstRun = configuration.stateSerialization == nil
        engine = CKSyncEngine(configuration)
        Self.logger.log("start(): 동기화 시작")
        // 처음 켰다면 레코드를 담을 존부터 만들고, 이 기기에 쌓여 있던 기록을 통째로 올린다.
        if isFirstRun {
            engine?.state.add(pendingDatabaseChanges: [
                .saveZone(CKRecordZone(zoneID: Self.zoneID))
            ])
            uploadEverything()
        }
    }

    func stop() {
        history.onLocalChange = nil
        ruleStore.onLocalChange = nil
        engine = nil
        pendingState = nil
        try? FileManager.default.removeItem(at: stateURL)
        Self.logger.log("stop(): 동기화 중단")
    }

    /// 지금까지 쌓인 방문·규칙을 전부 올릴 목록에 넣는다. 이미 서버에 있는 건 갱신으로 처리된다.
    func uploadEverything() {
        enqueue(saved: history.allIDs, deleted: [])
        enqueueRules(saved: ruleStore.allHosts, deleted: [])
    }

    private func enqueueRules(saved: [String], deleted: [String]) {
        guard let engine else { return }
        var changes: [CKSyncEngine.PendingRecordZoneChange] = saved.map { .saveRecord(Self.ruleRecordID($0)) }
        changes.append(contentsOf: deleted.map { .deleteRecord(Self.ruleRecordID($0)) })
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    private func enqueue(saved: [UUID], deleted: [UUID]) {
        guard let engine else { return }
        var changes: [CKSyncEngine.PendingRecordZoneChange] = saved.map { .saveRecord(Self.recordID($0)) }
        changes.append(contentsOf: deleted.map { .deleteRecord(Self.recordID($0)) })
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    // MARK: - 상태 보관

    private func loadState() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        do {
            return try PropertyListDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        } catch {
            Self.logger.error("loadState(): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func scheduleStateSave(_ state: CKSyncEngine.State.Serialization) {
        pendingState = state
        guard !stateSaveScheduled else { return }
        stateSaveScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.flushState()
        }
    }

    /// 모아 둔 엔진 상태를 지금 쓴다. 백그라운드로 빠질 때도 부른다.
    func flushState() {
        stateSaveScheduled = false
        guard let state = pendingState else { return }
        pendingState = nil
        saveState(state)
    }

    private func saveState(_ state: CKSyncEngine.State.Serialization) {
        do {
            let data = try PropertyListEncoder().encode(state)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            Self.logger.error("saveState(): \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - 레코드 ↔ 방문

extension CKRecord.FieldKey {
    static let rulesData = "rules"
    static let visitDate = "date"
    static let visitURL = "url"
    static let visitTitle = "title"
    static let visitTabID = "tabID"
    static let visitPrevID = "prevVisitID"
    static let visitParentID = "parentVisitID"
}

private extension CKRecord {
    /// 서버 레코드를 방문과 시스템 필드로 옮긴다. 주소나 날짜가 없으면 우리가 쓴 레코드가 아니다.
    func toVisit() -> (visit: Visit, systemFields: Data)? {
        guard let id = UUID(uuidString: recordID.recordName),
              let raw = encryptedValues[.visitURL] as? String,
              let url = URL(string: raw),
              let date = encryptedValues[.visitDate] as? Date,
              let tabRaw = encryptedValues[.visitTabID] as? String,
              let tabID = UUID(uuidString: tabRaw) else { return nil }
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        encodeSystemFields(with: archiver)
        let visit = Visit(id: id,
                          date: date,
                          url: url,
                          title: encryptedValues[.visitTitle] as? String,
                          tabID: tabID,
                          prevVisitID: (encryptedValues[.visitPrevID] as? String).flatMap(UUID.init(uuidString:)),
                          parentVisitID: (encryptedValues[.visitParentID] as? String).flatMap(UUID.init(uuidString:)))
        return (visit, archiver.encodedData)
    }

    func fill(from visit: Visit) {
        encryptedValues[.visitDate] = visit.date
        encryptedValues[.visitURL] = visit.url.absoluteString
        encryptedValues[.visitTitle] = visit.title
        encryptedValues[.visitTabID] = visit.tabID.uuidString
        encryptedValues[.visitPrevID] = visit.prevVisitID?.uuidString
        encryptedValues[.visitParentID] = visit.parentVisitID?.uuidString
    }

    /// 저장해 둔 시스템 필드로 레코드를 되살린다. 실패하면 nil.
    static func fromSystemFields(_ data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        return CKRecord(coder: unarchiver)
    }
}

// MARK: - CKSyncEngineDelegate

extension CloudSync: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let event):
            scheduleStateSave(event.stateSerialization)
        case .accountChange(let event):
            handleAccountChange(event)
        case .fetchedRecordZoneChanges(let event):
            handleFetched(event)
        case .sentRecordZoneChanges(let event):
            handleSent(event, syncEngine: syncEngine)
        case .fetchedDatabaseChanges(let event):
            // 존이 통째로 지워졌으면 이 기기 기록도 비운다.
            if event.deletions.contains(where: { $0.zoneID.zoneName == Self.zoneName }) {
                history.removeFromServer(ids: history.allIDs)
            }
        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] recordID in
            guard let self else { return nil }
            return await MainActor.run {
                if let host = Self.host(fromRecordName: recordID.recordName) {
                    guard let payload = self.ruleStore.payload(for: host) else {
                        syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                        return nil
                    }
                    let record = self.ruleRecordMeta[host].flatMap(CKRecord.fromSystemFields)
                        ?? CKRecord(recordType: Self.rulesRecordType, recordID: recordID)
                    record.encryptedValues[.rulesData] = payload
                    return record
                }
                guard let visitID = UUID(uuidString: recordID.recordName),
                      let visit = self.history.visit(withID: visitID) else {
                    // 이미 지워진 방문이 목록에 남아 있다 — 올릴 게 없으니 뺀다.
                    syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                    return nil
                }
                let record = self.history.recordData(for: visitID).flatMap(CKRecord.fromSystemFields)
                    ?? CKRecord(recordType: Self.visitRecordType, recordID: recordID)
                record.fill(from: visit)
                return record
            }
        }
    }

    private func handleFetched(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        Self.logger.log("받음: 변경 \(event.modifications.count) 삭제 \(event.deletions.count)")
        var incoming: [(visit: Visit, systemFields: Data)] = []
        for modification in event.modifications {
            let record = modification.record
            if record.recordType == Self.rulesRecordType {
                guard let host = Self.host(fromRecordName: record.recordID.recordName),
                      let data = record.encryptedValues[.rulesData] as? Data else { continue }
                ruleStore.mergeFromServer(host: host, data: data)
                let archiver = NSKeyedArchiver(requiringSecureCoding: true)
                record.encodeSystemFields(with: archiver)
                ruleRecordMeta[host] = archiver.encodedData
            } else if let fetched = record.toVisit() {
                incoming.append(fetched)
            }
        }
        saveRuleMeta()
        history.mergeFromServer(incoming.map(\.visit))
        for fetched in incoming {
            history.setLastKnownRecord(fetched.systemFields, forVisit: fetched.visit.id)
        }
        var deletedVisits: [UUID] = []
        for deletion in event.deletions {
            if let host = Self.host(fromRecordName: deletion.recordID.recordName) {
                ruleStore.removeFromServer(host: host)
                ruleRecordMeta.removeValue(forKey: host)
            } else if let id = UUID(uuidString: deletion.recordID.recordName) {
                deletedVisits.append(id)
            }
        }
        history.removeFromServer(ids: deletedVisits)
    }

    private func handleSent(_ event: CKSyncEngine.Event.SentRecordZoneChanges, syncEngine: CKSyncEngine) {
        Self.logger.log("올림: 성공 \(event.savedRecords.count) 실패 \(event.failedRecordSaves.count)")
        for saved in event.savedRecords {
            let archiver = NSKeyedArchiver(requiringSecureCoding: true)
            saved.encodeSystemFields(with: archiver)
            if let host = Self.host(fromRecordName: saved.recordID.recordName) {
                ruleRecordMeta[host] = archiver.encodedData
            } else if let id = UUID(uuidString: saved.recordID.recordName) {
                history.setLastKnownRecord(archiver.encodedData, forVisit: id)
            }
        }
        saveRuleMeta()

        var retryRecords: [CKSyncEngine.PendingRecordZoneChange] = []
        var retryZones: [CKSyncEngine.PendingDatabaseChange] = []
        for failure in event.failedRecordSaves {
            let recordID = failure.record.recordID
            let visitID = UUID(uuidString: recordID.recordName)
            let ruleHost = Self.host(fromRecordName: recordID.recordName)
            switch failure.error.code {
            case .serverRecordChanged:
                // 다른 기기가 먼저 고쳤다. 서버 것을 받아들이고 이쪽 것은 버린다.
                if let serverRecord = failure.error.serverRecord {
                    if let host = ruleHost {
                        if let data = serverRecord.encryptedValues[.rulesData] as? Data {
                            ruleStore.mergeFromServer(host: host, data: data)
                        }
                        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
                        serverRecord.encodeSystemFields(with: archiver)
                        ruleRecordMeta[host] = archiver.encodedData
                        saveRuleMeta()
                    } else if let fetched = serverRecord.toVisit() {
                        history.mergeFromServer([fetched.visit])
                        history.setLastKnownRecord(fetched.systemFields, forVisit: fetched.visit.id)
                    }
                }
            case .zoneNotFound:
                // 존이 아직 없다. 만들고 다시 올린다.
                retryZones.append(.saveZone(CKRecordZone(zoneID: recordID.zoneID)))
                retryRecords.append(.saveRecord(recordID))
                if let host = ruleHost { ruleRecordMeta.removeValue(forKey: host); saveRuleMeta() }
                if let visitID { history.setLastKnownRecord(nil, forVisit: visitID) }
            case .unknownItem:
                // 들고 있던 서버 레코드가 서버에는 없다. 시스템 필드를 버리고 새로 올린다.
                retryRecords.append(.saveRecord(recordID))
                if let host = ruleHost { ruleRecordMeta.removeValue(forKey: host); saveRuleMeta() }
                if let visitID { history.setLastKnownRecord(nil, forVisit: visitID) }
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                 .notAuthenticated, .operationCancelled:
                // 엔진이 알아서 다시 시도한다.
                break
            default:
                // 원인 불명 거부(스키마 미배포 등)로 버리면 기록이 서버에 영영 안 올라간
                // 채 남는다 — 올릴 목록에 되돌려 다음 동기화 때 다시 시도한다.
                retryRecords.append(.saveRecord(recordID))
                Self.logger.error("올리기 실패, 재시도 예약 \(recordID.recordName, privacy: .public) code=\(failure.error.code.rawValue): \(failure.error.localizedDescription, privacy: .public)")
            }
        }
        syncEngine.state.add(pendingDatabaseChanges: retryZones)
        syncEngine.state.add(pendingRecordZoneChanges: retryRecords)
    }

    private func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) {
        switch event.changeType {
        case .signIn:
            // 계정이 붙었다. 이 기기에 있던 기록을 전부 올린다.
            uploadEverything()
        case .switchAccounts, .signOut:
            // 남의 계정 데이터가 섞이지 않게 이 기기 기록·규칙을 비운다. 서버 것은 그대로 남는다.
            history.removeFromServer(ids: history.allIDs)
            for host in ruleStore.allHosts { ruleStore.removeFromServer(host: host) }
            ruleRecordMeta.removeAll()
            saveRuleMeta()
        @unknown default:
            break
        }
    }
}
