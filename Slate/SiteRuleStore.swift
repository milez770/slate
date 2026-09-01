import Foundation
import Observation
import os

struct SiteRule: Codable, Equatable, Identifiable {
    var kind: String        // "selector" | "imgSrcPrefix"
    var value: String
    var added: Date
    var enabled: Bool
    var id: String { kind + "|" + value }

    init(kind: String, value: String, added: Date, enabled: Bool = true) {
        self.kind = kind; self.value = value; self.added = added; self.enabled = enabled
    }

    // 옛 저장본에는 enabled가 없다 — 없으면 켜진 것으로 읽는다.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        value = try c.decode(String.self, forKey: .value)
        added = try c.decode(Date.self, forKey: .added)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

@MainActor
@Observable
final class SiteRuleStore {
    static let shared = SiteRuleStore(fileURL: defaultFileURL())
    private static let logger = Logger(subsystem: "com.wonseon.slate", category: "siterules")

    private let fileURL: URL
    private var storage: [String: [SiteRule]] = [:]
    /// 이 기기에서 규칙이 바뀔 때 알린다. 동기화 층이 받아 올릴 목록에 넣는다.
    /// 서버발 반영에는 부르지 않는다.
    @ObservationIgnored var onLocalChange: ((_ savedHosts: [String], _ deletedHosts: [String]) -> Void)?

    var hosts: [String] { storage.keys.sorted() }

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    static func defaultFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("site-rules.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode([String: [SiteRule]].self, from: data) else {
            Self.logger.error("load(): site-rules.json decode failed")
            return
        }
        storage = decoded
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(storage)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("save(): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 저장 키가 되는 호스트. www는 뗀다.
    static func normalize(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// 첫 라벨 끝의 숫자를 뗀 어간. 숫자 접미사가 없거나 어간이 3자 미만이면 nil.
    static func stem(_ host: String) -> String? {
        let labels = normalize(host).split(separator: ".").map(String.init)
        guard let first = labels.first, labels.count >= 2 else { return nil }
        let base = String(first.reversed().drop(while: { $0.isNumber }).reversed())
        guard base.count != first.count, base.count >= 3 else { return nil }
        return ([base] + labels.dropFirst()).joined(separator: ".")
    }

    /// 저장 호스트와 방문 호스트 둘 다 숫자 접미사를 가질 때만 어간으로 맞춘다.
    /// 한쪽이라도 숫자가 없으면 정확 일치만 — 숫자 없는 호스트는 다른 소유자일 수 있어 규칙이 새면 안 된다.
    static func matches(stored: String, visiting: String) -> Bool {
        let storedHost = normalize(stored)
        let visitingHost = normalize(visiting)
        if storedHost == visitingHost { return true }
        guard let storedStem = stem(storedHost), let visitingStem = stem(visitingHost) else { return false }
        return storedStem == visitingStem
    }

    private func matchingKeys(for host: String) -> [String] {
        storage.keys.filter { Self.matches(stored: $0, visiting: host) }.sorted()
    }

    /// 매칭되는 모든 저장 키의 규칙을 정렬 순서로 합친다. 같은 id가 여러 키에 있으면 한 번만 담는다.
    func rules(for host: String) -> [SiteRule] {
        let key = Self.normalize(host)
        var seen = Set<String>()
        var result: [SiteRule] = []
        for stored in matchingKeys(for: key) {
            for rule in storage[stored] ?? [] where !seen.contains(rule.id) {
                seen.insert(rule.id)
                result.append(rule)
            }
        }
        return result
    }

    /// 페이지에 실제로 적용할 규칙 — 켜진 것만.
    func enabledRules(for host: String) -> [SiteRule] {
        rules(for: host).filter { $0.enabled }
    }

    /// 규칙 하나를 켜거나 끈다. 페이지가 깨지면 하나씩 꺼서 범인을 찾는 데 쓴다.
    func setEnabled(_ rule: SiteRule, enabled: Bool, host: String) {
        let key = Self.normalize(host)
        for stored in matchingKeys(for: key) {
            guard var existing = storage[stored] else { continue }
            for i in existing.indices where existing[i].id == rule.id {
                existing[i].enabled = enabled
            }
            storage[stored] = existing
        }
        save()
        onLocalChange?(matchingKeys(for: key), [])
    }

    /// 매칭되는 기존 키가 있으면 그 키(여럿이면 정렬 순서 첫 번째)에 붙인다. 없으면 정규화한 host로 새 키를 만든다.
    func add(_ rules: [SiteRule], host: String) {
        let key = Self.normalize(host)
        let targetKey = matchingKeys(for: key).first ?? key
        var existing = storage[targetKey] ?? []
        for rule in rules where !existing.contains(where: { $0.id == rule.id }) {
            existing.append(rule)
        }
        storage[targetKey] = existing
        save()
        onLocalChange?([targetKey], [])
    }

    /// 매칭되는 모든 키에서 지운다. 비게 된 키는 제거한다.
    func remove(_ rule: SiteRule, host: String) {
        let key = Self.normalize(host)
        var saved: [String] = []
        var deleted: [String] = []
        for stored in matchingKeys(for: key) {
            guard var existing = storage[stored] else { continue }
            existing.removeAll { $0.id == rule.id }
            if existing.isEmpty {
                storage.removeValue(forKey: stored)
                deleted.append(stored)
            } else {
                storage[stored] = existing
                saved.append(stored)
            }
        }
        save()
        onLocalChange?(saved, deleted)
    }

    func removeAll(host: String) {
        let key = Self.normalize(host)
        var deleted: [String] = []
        for stored in matchingKeys(for: key) {
            storage.removeValue(forKey: stored)
            deleted.append(stored)
        }
        save()
        onLocalChange?([], deleted)
    }

    func removeAll() {
        let deleted = Array(storage.keys)
        storage.removeAll()
        save()
        onLocalChange?([], deleted)
    }

    // MARK: - 동기화

    /// 호스트 하나의 규칙 뭉치를 서버에 실을 JSON.
    func payload(for host: String) -> Data? {
        guard let rules = storage[host] else { return nil }
        return try? JSONEncoder().encode(rules)
    }

    /// 서버에서 받은 규칙을 반영한다. onLocalChange를 부르지 않는다.
    func mergeFromServer(host: String, data: Data) {
        guard let rules = try? JSONDecoder().decode([SiteRule].self, from: data) else {
            Self.logger.error("mergeFromServer(): 규칙 해석 실패 \(host, privacy: .public)")
            return
        }
        if rules.isEmpty {
            storage.removeValue(forKey: host)
        } else {
            storage[host] = rules
        }
        save()
    }

    /// 서버에서 지워진 호스트를 이 기기에서도 지운다.
    func removeFromServer(host: String) {
        storage.removeValue(forKey: host)
        save()
    }

    var allHosts: [String] { Array(storage.keys) }
}
