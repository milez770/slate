import Foundation
import os

/// 번역문 원장. (원어, 원문) → 번역문. 같은 문구는 페이지·탭·실행을 넘어 한 번만 번역한다.
@MainActor
final class TranslationCache {
    static let shared = TranslationCache()
    private static let logger = Logger(subsystem: "com.wonseon.slate", category: "translate-cache")
    /// 이 수를 넘으면 절반 가까이 비운다. 항목 하나가 수십 바이트라 5만이면 수 MB.
    static let limit = 50_000

    private let url: URL
    private var map: [String: String] = [:]
    private var saveTask: Task<Void, Never>?
    private var generation = 0
    private let writer = JSONFileWriter()

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("slate", isDirectory: true)
            .appendingPathComponent("translations.json")
        if let data = try? Data(contentsOf: self.url),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            map = stored
        }
    }

    var count: Int { map.count }

    private func key(_ text: String, _ source: String) -> String { source + "\u{1}" + text }

    func lookup(_ text: String, source: String) -> String? {
        map[key(text, source)]
    }

    func store(_ pairs: [(String, String)], source: String) {
        guard !pairs.isEmpty else { return }
        for (text, translated) in pairs { map[key(text, source)] = translated }
        if map.count > Self.limit {
            // 순서 없는 사전이라 어느 절반이 남는지는 임의다. 자주 쓰는 문구는 곧 다시 채워진다.
            for k in map.keys.prefix(map.count - Self.limit / 2) { map.removeValue(forKey: k) }
        }
        scheduleSave()
    }

    /// 변경을 2초 모아 배경에서 쓴다. 원장 전체를 메인 스레드에서 인코딩하지 않는다.
    private func scheduleSave() {
        generation += 1
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            await self.writer.write(self.map, generation: self.generation, to: self.url)
        }
    }

    /// 지금 바로 쓴다. 시험과 백그라운드 진입용.
    func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(map).write(to: url, options: .atomic)
        } catch {
            Self.logger.error("save: \(error.localizedDescription, privacy: .public)")
        }
    }
}
