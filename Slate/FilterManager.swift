import Foundation
import WebKit
import ContentBlockerConverter
import os

@MainActor
final class FilterManager {
    static let shared = FilterManager()
    private static let logger = Logger(subsystem: "com.wonseon.slate", category: "filters")
    private static let bundledFilters = ["easylist", "list-kr", "youslist"]
    private static let remoteURLs: [String: URL] = [
        "easylist": URL(string: "https://easylist.to/easylist/easylist.txt")!,
        "list-kr": URL(string: "https://cdn.jsdelivr.net/npm/@list-kr/filterslists@latest/dist/filterslist-AdGuard.txt")!,
        "youslist": URL(string: "https://raw.githubusercontent.com/yous/YousList/master/youslist.txt")!,
    ]
    // iOS 18 targets Safari 16.4+, which raises the per-list rule cap from 50k to 150k.
    private nonisolated static let safariVersion = SafariVersion.safari16_4

    private var refreshInFlight = false

    var lastUpdated: Date? {
        UserDefaults.standard.object(forKey: "slate.filters.updated") as? Date
    }

    nonisolated static func convert(filterText: String) throws -> String {
        let rules = filterText.components(separatedBy: .newlines)
        let result = ContentBlockerConverter().convertArray(rules: rules, safariVersion: safariVersion)
        return result.safariRulesJSON
    }

    /// 요소 숨김(css-display-none) 규칙을 뺀 JSON. 광고 요청은 그대로 막고, 광고 차단 감지용
    /// 미끼 요소는 숨기지 않아 감지를 통과한다.
    nonisolated static func stripCosmeticRules(_ json: String) throws -> String {
        guard let data = json.data(using: .utf8),
              let rules = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return json }
        let kept = rules.filter { rule in
            (rule["action"] as? [String: Any])?["type"] as? String != "css-display-none"
        }
        let out = try JSONSerialization.data(withJSONObject: kept)
        return String(decoding: out, as: UTF8.self)
    }

    /// 감지 회피용 목록의 저장 식별자 접미사. 전체 목록과 따로 컴파일·캐시된다.
    private static let networkSuffix = "-network"

    private func filterText(name: String) -> String? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if let downloaded = try? String(contentsOf: dir.appendingPathComponent("\(name).txt"), encoding: .utf8) {
            return downloaded
        }
        guard let bundled = Bundle.main.url(forResource: name, withExtension: "txt") else {
            Self.logger.error("filterText(\(name, privacy: .public)): no bundled resource found")
            return nil
        }
        guard let text = try? String(contentsOf: bundled, encoding: .utf8) else {
            Self.logger.error("filterText(\(name, privacy: .public)): failed to read bundled resource")
            return nil
        }
        return text
    }

    func loadRuleLists() async -> [WKContentRuleList] {
        await load(suffix: "") { $0 }
    }

    /// 요소 숨김 규칙을 뺀 목록. "감지 회피" 사이트가 처음 나올 때 컴파일하고 이후는 저장소 캐시.
    func loadNetworkOnlyRuleLists() async -> [WKContentRuleList] {
        await load(suffix: Self.networkSuffix) { try Self.stripCosmeticRules($0) }
    }

    private func load(suffix: String,
                      transform: @escaping @Sendable (String) throws -> String) async -> [WKContentRuleList] {
        var lists: [WKContentRuleList] = []
        let store = WKContentRuleListStore.default()!
        for name in Self.bundledFilters {
            let identifier = name + suffix
            if let cached = try? await store.contentRuleList(forIdentifier: identifier) {
                lists.append(cached)
                continue
            }
            guard let text = filterText(name: name) else {
                Self.logger.error("load(\(identifier, privacy: .public)): no filter text available")
                continue
            }
            let json: String
            do {
                json = try await Task.detached(priority: .userInitiated) {
                    try transform(Self.convert(filterText: text))
                }.value
            } catch {
                Self.logger.error("load(\(identifier, privacy: .public)): conversion failed")
                continue
            }
            guard let compiled = try? await store.compileContentRuleList(forIdentifier: identifier,
                                                                          encodedContentRuleList: json) else {
                Self.logger.error("load(\(identifier, privacy: .public)): compile failed")
                continue
            }
            lists.append(compiled)
        }
        return lists
    }

    /// 목록 이름 하나의 컴파일 캐시(전체·감지 회피)를 지운다. 필터 본문이 바뀌면 둘 다 다시 컴파일해야 한다.
    private func removeCompiled(_ name: String, from store: WKContentRuleListStore) async {
        try? await store.removeContentRuleList(forIdentifier: name)
        try? await store.removeContentRuleList(forIdentifier: name + Self.networkSuffix)
    }

    func refresh() async throws {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        defer { refreshInFlight = false }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("refresh(): failed to create Application Support directory: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        let store = WKContentRuleListStore.default()!
        for (name, url) in Self.remoteURLs {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let text = String(data: data, encoding: .utf8),
                      text.count > 50_000, text.contains("!") else {
                    throw URLError(.badServerResponse)
                }
                try data.write(to: dir.appendingPathComponent("\(name).txt"), options: .atomic)
                await removeCompiled(name, from: store)
            } catch {
                Self.logger.error("refresh(\(name, privacy: .public)): download/write failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
        let lists = await loadRuleLists()
        guard !lists.isEmpty else { throw URLError(.cannotParseResponse) }
        UserDefaults.standard.set(Date(), forKey: "slate.filters.updated")
    }

    /// 다운로드 필터를 지우고 번들 초기값으로 되돌린다.
    func resetToBundled() async {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let store = WKContentRuleListStore.default()!
        for name in Self.bundledFilters {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(name).txt"))
            await removeCompiled(name, from: store)
        }
        UserDefaults.standard.removeObject(forKey: "slate.filters.updated")
        _ = await loadRuleLists()
    }
}
