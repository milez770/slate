import XCTest
@testable import Slate

final class SnapshotStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-snapshots-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeImage(_ color: UIColor, size: CGSize = CGSize(width: 900, height: 1800)) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    func testStoredImageComesBack() async {
        let store = SnapshotStore(directory: dir)
        let id = UUID()
        store.store(makeImage(.red), for: id)
        let loaded = await store.load(for: id)
        XCTAssertNotNil(loaded, "저장한 그림을 다시 못 읽었다")
    }

    /// 저장할 때 폭을 줄인다 — 원본 그대로 쌓으면 디스크가 금방 찬다.
    func testStoredImageIsDownscaled() async {
        let store = SnapshotStore(directory: dir)
        let id = UUID()
        store.store(makeImage(.blue, size: CGSize(width: 900, height: 1800)), for: id)
        let loaded = await store.load(for: id)
        let width = (loaded?.size.width ?? 0) * (loaded?.scale ?? 1)
        XCTAssertEqual(width, 360, accuracy: 1, "저장 폭이 360px가 아니다")
    }

    /// 다른 그림으로 덮어써도 같은 열쇠로 읽힌다 — 같은 주소를 다시 방문하면 방문 id가 재사용된다.
    func testStoreOverwrites() async {
        let store = SnapshotStore(directory: dir)
        let id = UUID()
        store.store(makeImage(.red), for: id)
        _ = await store.load(for: id)
        store.store(makeImage(.green), for: id)
        let loaded = await store.load(for: id)
        XCTAssertNotNil(loaded)
    }

    func testDeleteRemovesImage() async {
        let store = SnapshotStore(directory: dir)
        let id = UUID()
        store.store(makeImage(.red), for: id)
        _ = await store.load(for: id)
        store.delete([id])
        let loaded = await store.load(for: id)
        XCTAssertNil(loaded, "지운 그림이 남아 있다")
    }

    /// 기록에서 사라진 방문의 그림은 청소 때 같이 없어진다.
    func testPruneDropsImagesWithoutVisit() async {
        let store = SnapshotStore(directory: dir)
        let kept = UUID()
        let orphan = UUID()
        store.store(makeImage(.red), for: kept)
        store.store(makeImage(.blue), for: orphan)
        _ = await store.load(for: orphan)
        store.prune(keeping: [kept])
        let survivor = await store.load(for: kept)
        let gone = await store.load(for: orphan)
        XCTAssertNotNil(survivor, "기록에 있는 그림까지 지워졌다")
        XCTAssertNil(gone, "기록에 없는 그림이 남아 있다")
    }
}
