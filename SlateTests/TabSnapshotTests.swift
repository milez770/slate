import UIKit
import XCTest
@testable import Slate

final class TabSnapshotTests: XCTestCase {
    /// 복사본은 크기·배율이 같고, 원본과 다른 픽셀 저장소를 가진 우리 소유 비트맵이다.
    func testDetachedCopyKeepsSizeAndScaleWithOwnStorage() {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 3
        let source = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 400), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 400))
        }
        let copy = Tab.detached(source)
        XCTAssertNotNil(copy)
        XCTAssertEqual(copy?.size, source.size)
        XCTAssertEqual(copy?.scale, source.scale)
        XCTAssertNotNil(copy?.cgImage)
        XCTAssertFalse(copy?.cgImage === source.cgImage, "원본 픽셀 저장소를 그대로 들고 있지 않는다")
        XCTAssertEqual(copy?.cgImage?.width, 600)
    }

    func testDetachedRejectsEmptyImage() {
        XCTAssertNil(Tab.detached(UIImage()))
    }

    func testSnapshotWidthMatchesGridCard() {
        XCTAssertEqual(Tab.snapshotWidth, 200)
    }
}
