import Foundation
import os

/// 번역 원장. 항목은 메모리 사전에 두고, 파일은 줄마다 `["키","번역"]` 한 쌍인 덧붙이기
/// 로그다 — 새 항목만 파일 끝에 붙이고 전체를 다시 쓰지 않는다. 5만 항목 전체를 저장마다
/// JSON으로 만들면 그때마다 수십 MB를 새로 잡아, 메모리가 빠듯한 순간 할당이 실패해 앱이 죽는다.
/// 줄 수가 상한의 두 배를 넘거나 항목을 잘라냈을 때만 파일을 한 번 다시 쓴다.
@MainActor
final class TranslationCache {
    static let shared = TranslationCache()
    private static let logger = Logger(subsystem: "com.wonseon.slate", category: "translate-cache")
    static let limit = 50_000

    private let url: URL
    private var map: [String: String] = [:]
    /// 파일에 쌓인 줄 수. 다시 쓸 때를 정하는 기준.
    private var linesOnDisk = 0
    private var pending: [(String, String)] = []
    private var needsRewrite = false
    private var flushTask: Task<Void, Never>?
    /// 옛 형식(사전 하나를 통째로 담은 translations.json)에서 옮겨 왔으면 새 파일을 쓴 뒤 지운다.
    private var legacyURL: URL?
    private let writer = TranslationLogWriter()

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("slate", isDirectory: true)
            .appendingPathComponent("translations.jsonl")
        if let data = try? Data(contentsOf: self.url) {
            for line in data.split(separator: UInt8(ascii: "\n")) {
                // 쓰다 죽어 반만 남은 줄은 건너뛴다.
                guard let pair = try? JSONSerialization.jsonObject(with: line) as? [String], pair.count == 2 else { continue }
                map[pair[0]] = pair[1]
                linesOnDisk += 1
            }
        } else {
            adoptLegacyFile()
        }
    }

    private func adoptLegacyFile() {
        let legacy = url.deletingLastPathComponent().appendingPathComponent("translations.json")
        guard let data = try? Data(contentsOf: legacy),
              let stored = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        map = stored
        legacyURL = legacy
        needsRewrite = true
        scheduleFlush()
    }

    var count: Int { map.count }

    /// 파일 크기(바이트). 설정 화면 표시용.
    var fileSize: Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    private func key(_ text: String, _ source: String) -> String { source + "\u{1}" + text }

    func lookup(_ text: String, source: String) -> String? {
        map[key(text, source)]
    }

    func store(_ pairs: [(String, String)], source: String) {
        guard !pairs.isEmpty else { return }
        for (text, translated) in pairs {
            let k = key(text, source)
            map[k] = translated
            pending.append((k, translated))
        }
        if map.count > Self.limit {
            for k in map.keys.prefix(map.count - Self.limit / 2) { map.removeValue(forKey: k) }
            needsRewrite = true
        } else if linesOnDisk + pending.count > Self.limit * 2 {
            needsRewrite = true
        }
        scheduleFlush()
    }

    /// 1초 모아서 쓴다. 쓰는 동안 들어온 항목은 같은 회차가 이어서 쓴다.
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await drain()
            flushTask = nil
        }
    }

    private func drain() async {
        while needsRewrite || !pending.isEmpty {
            if needsRewrite {
                needsRewrite = false
                pending.removeAll()
                let snapshot = map
                guard await writer.rewrite(snapshot, to: url) else { continue }
                linesOnDisk = snapshot.count
                if let legacyURL {
                    try? FileManager.default.removeItem(at: legacyURL)
                    self.legacyURL = nil
                }
            } else {
                let batch = pending
                pending.removeAll()
                if await writer.append(batch, to: url) { linesOnDisk += batch.count }
            }
        }
    }

    /// 모아 둔 항목을 지금 쓴다. 백그라운드로 빠질 때 부른다.
    func flush() async {
        flushTask?.cancel()
        flushTask = nil
        await drain()
    }
}

/// 번역 원장 파일을 쓰는 배경 일꾼. 덧붙이기와 전체 다시 쓰기 둘뿐이다.
actor TranslationLogWriter {
    private static let logger = Logger(subsystem: "com.wonseon.slate", category: "translate-log")
    private static let newline = Data([UInt8(ascii: "\n")])

    /// 쌍들을 파일 끝에 붙인다. 앞 줄이 줄바꿈 없이 끊겨 있으면 먼저 끝맺는다.
    func append(_ pairs: [(String, String)], to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
            // 마지막 글자를 읽어야 하니 읽기·쓰기 겸용으로 연다.
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                if try handle.read(upToCount: 1) != Self.newline { try handle.write(contentsOf: Self.newline) }
            }
            try handle.write(contentsOf: Self.lines(pairs))
            return true
        } catch {
            Self.logger.error("append: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 사전 전체로 파일을 새로 쓴다. 임시 파일에 천 줄씩 쓰고 바꿔 넣는다.
    func rewrite(_ map: [String: String], to url: URL) -> Bool {
        let temp = url.appendingPathExtension("tmp")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: temp)
            let handle = try FileHandle(forWritingTo: temp)
            var chunk: [(String, String)] = []
            chunk.reserveCapacity(1000)
            for pair in map {
                chunk.append(pair)
                if chunk.count == 1000 {
                    try handle.write(contentsOf: Self.lines(chunk))
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            if !chunk.isEmpty { try handle.write(contentsOf: Self.lines(chunk)) }
            try handle.close()
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
            return true
        } catch {
            Self.logger.error("rewrite: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: temp)
            return false
        }
    }

    private static func lines(_ pairs: [(String, String)]) throws -> Data {
        var data = Data()
        for (key, value) in pairs {
            data.append(try JSONSerialization.data(withJSONObject: [key, value]))
            data.append(newline)
        }
        return data
    }
}
