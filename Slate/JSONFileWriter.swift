import Foundation
import os

/// JSON 파일 하나를 순서대로 쓰는 배경 일꾼. 더 새 스냅샷이 이미 씌었으면 옛 것은 건너뛴다.
/// 원장(방문 기록·번역문)은 메인 스레드에서 통째로 인코딩하지 않고 여기로 넘긴다.
actor JSONFileWriter {
    private static let logger = Logger(subsystem: "com.wonseon.slate", category: "filewriter")
    private var latest = 0

    func write<T: Encodable & Sendable>(_ value: T, generation: Int, to url: URL) {
        guard generation > latest else { return }
        latest = generation
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("write(\(url.lastPathComponent, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
    }
}
