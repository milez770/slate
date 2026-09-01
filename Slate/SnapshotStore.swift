import UIKit
import os

/// 방문마다 찍은 페이지 그림을 디스크에 둔다. 탭 객체가 들고 있는 썸네일은 앱이 죽으면
/// 통째로 사라져 격자가 회색 카드로 남는다 — 그림의 주인을 탭이 아니라 방문 기록으로
/// 옮겨, 격자와 타임라인이 같은 파일을 본다.
final class SnapshotStore: @unchecked Sendable {
    static let shared = SnapshotStore()
    private static let logger = Logger(subsystem: "com.wonseon.slate", category: "snapshot")

    /// 저장 폭(픽셀). 격자 카드가 화면에서 쓰는 폭은 약 190pt(@3x 570px)지만 흐리게 깔리고,
    /// 타임라인 썸네일은 60pt다. 360px면 둘 다 덮는다.
    private static let storedWidth: CGFloat = 360
    private static let quality: CGFloat = 0.6
    /// 청소 상한. 둘 중 먼저 걸리는 쪽까지 오래된 파일부터 지운다.
    private static let fileLimit = 400
    private static let byteLimit = 60 * 1024 * 1024

    private let dir: URL
    private let cache = NSCache<NSString, UIImage>()
    private let io = DispatchQueue(label: "com.wonseon.slate.snapshot", qos: .utility)

    init(directory: URL = SnapshotStore.defaultDirectory()) {
        dir = directory
        cache.countLimit = 40
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("snapshots", isDirectory: true)
    }

    private func fileURL(_ id: UUID) -> URL {
        dir.appendingPathComponent("\(id.uuidString).jpg")
    }

    /// 방문 하나의 그림을 갈아 끼운다. 축소·인코딩·쓰기는 전부 백그라운드에서 한다 —
    /// 페이지 로드가 끝날 때마다 부르므로 메인 스레드에 얹으면 스크롤이 걸린다.
    func store(_ image: UIImage, for id: UUID) {
        io.async { [weak self] in
            guard let self else { return }
            let small = Self.downscaled(image)
            self.cache.setObject(small, forKey: id.uuidString as NSString)
            guard let data = small.jpegData(compressionQuality: Self.quality) else { return }
            do {
                try FileManager.default.createDirectory(at: self.dir, withIntermediateDirectories: true)
                try data.write(to: self.fileURL(id), options: .atomic)
            } catch {
                Self.logger.error("store(): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 그림 하나를 가져온다. 메모리에 있으면 디스크를 안 건드린다. 조회도 저장·삭제와 같은
    /// 큐에서 처리한다 — 큐 밖에서 캐시를 먼저 보면 방금 지운 그림이 되살아난다.
    func load(for id: UUID) async -> UIImage? {
        await withCheckedContinuation { continuation in
            io.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                let key = id.uuidString as NSString
                if let hit = self.cache.object(forKey: key) {
                    continuation.resume(returning: hit)
                    return
                }
                guard let image = UIImage(contentsOfFile: self.fileURL(id).path) else {
                    continuation.resume(returning: nil)
                    return
                }
                self.cache.setObject(image, forKey: key)
                continuation.resume(returning: image)
            }
        }
    }

    func delete(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        io.async { [weak self] in
            guard let self else { return }
            for id in ids {
                self.cache.removeObject(forKey: id.uuidString as NSString)
                try? FileManager.default.removeItem(at: self.fileURL(id))
            }
        }
    }

    func deleteAll() {
        io.async { [weak self] in
            guard let self else { return }
            self.cache.removeAllObjects()
            try? FileManager.default.removeItem(at: self.dir)
        }
    }

    /// 기록에 없는 그림을 지우고, 남은 것도 상한까지 오래된 순으로 지운다. 앱 시작 때 한 번.
    func prune(keeping ids: Set<UUID>) {
        io.async { [weak self] in
            guard let self else { return }
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: self.dir, includingPropertiesForKeys: Array(keys)) else { return }
            var alive: [(url: URL, date: Date, size: Int)] = []
            for file in files {
                let name = file.deletingPathExtension().lastPathComponent
                guard let id = UUID(uuidString: name), ids.contains(id) else {
                    self.cache.removeObject(forKey: name as NSString)
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                let values = try? file.resourceValues(forKeys: keys)
                alive.append((file, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0))
            }
            alive.sort { $0.date > $1.date }
            var count = 0
            var bytes = 0
            for entry in alive {
                count += 1
                bytes += entry.size
                if count > Self.fileLimit || bytes > Self.byteLimit {
                    try? FileManager.default.removeItem(at: entry.url)
                    self.cache.removeObject(
                        forKey: entry.url.deletingPathExtension().lastPathComponent as NSString)
                }
            }
        }
    }

    private static func downscaled(_ image: UIImage) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        guard pixelWidth > storedWidth, pixelWidth > 0 else { return image }
        let ratio = storedWidth / pixelWidth
        let size = CGSize(width: (pixelWidth * ratio).rounded(),
                          height: (image.size.height * image.scale * ratio).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
