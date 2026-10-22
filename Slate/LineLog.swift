import Foundation

/// 줄 단위 로그 파일. 원장(방문 기록·번역문)은 바뀐 줄만 끝에 붙이고, 옛 줄이 쌓이면 한 번 다시 쓴다.
enum LineLog {
    static let newline = Data([UInt8(ascii: "\n")])

    /// 줄들을 파일 끝에 붙인다. 앞 줄이 줄바꿈 없이 끊겨 있으면 먼저 끝맺는다.
    static func append(_ data: Data, to url: URL) throws {
        guard !data.isEmpty else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
        // 마지막 글자를 읽어야 하니 읽기·쓰기 겸용으로 연다.
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != newline { try handle.write(contentsOf: newline) }
        }
        try handle.write(contentsOf: data)
    }

    /// 임시 파일에 body가 쓴 내용으로 파일을 바꿔 넣는다.
    static func rewrite(_ url: URL, body: (FileHandle) throws -> Void) throws {
        let temp = url.appendingPathExtension("tmp")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: temp)
            let handle = try FileHandle(forWritingTo: temp)
            try body(handle)
            try handle.close()
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}
