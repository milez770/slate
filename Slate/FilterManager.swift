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
        var lists: [WKContentRuleList] = []
        let store = WKContentRuleListStore.default()!
        for name in Self.bundledFilters {
            if let cached = try? await store.contentRuleList(forIdentifier: name) {
                lists.append(cached)
                continue
            }
            guard let text = filterText(name: name) else {
                Self.logger.error("loadRuleLists(\(name, privacy: .public)): no filter text available")
                continue
            }
            let json: String
            do {
                json = try await Task.detached(priority: .userInitiated) {
                    try Self.convert(filterText: text)
                }.value
            } catch {
                Self.logger.error("loadRuleLists(\(name, privacy: .public)): conversion failed")
                continue
            }
            guard let compiled = try? await store.compileContentRuleList(forIdentifier: name, encodedContentRuleList: json) else {
                Self.logger.error("loadRuleLists(\(name, privacy: .public)): compile failed")
                continue
            }
            lists.append(compiled)
        }
        return lists
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
                try? await store.removeContentRuleList(forIdentifier: name)
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
            try? await store.removeContentRuleList(forIdentifier: name)
        }
        UserDefaults.standard.removeObject(forKey: "slate.filters.updated")
        _ = await loadRuleLists()
    }
}
