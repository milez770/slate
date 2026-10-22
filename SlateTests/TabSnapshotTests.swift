import UIKit
import XCTest
@testable import Slate

@MainActor
final class TabSnapshotTests: XCTestCase {
    /// 씬에 붙은 창. 씬 없는 창은 렌더 서버가 그리지 않아 찍을 게 없다.
    private func window(with view: UIView) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        return window
    }

    private func pixel(_ image: UIImage, at point: CGPoint) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let cg = image.cgImage else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let x = point.x * image.scale, y = point.y * image.scale
        context.draw(cg, in: CGRect(x: -x, y: -(CGFloat(cg.height) - y - 1), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return (rgba[0], rgba[1], rgba[2])
    }

    /// 창에 붙은 뷰를 카드 폭(200pt)·저장 폭(360px)으로, 비율을 지켜 우리 비트맵에 그린다. 색이 실제로 담긴다.
    func testThumbnailRendersVisibleViewAtCardWidth() {
        let view = UIView()
        view.backgroundColor = .red
        let window = window(with: view)
        defer { window.isHidden = true }
        let image = Tab.thumbnail(of: view)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.size.width, 200)
        XCTAssertEqual(image?.cgImage?.width, 360, "저장 폭 픽셀로 바로 그린다")
        XCTAssertEqual(Double(image?.cgImage?.height ?? 0), 844 * 360 / 390, accuracy: 1)
        let center = pixel(image!, at: CGPoint(x: 100, y: 200))
        XCTAssertNotNil(center)
        XCTAssertGreaterThan(center!.r, 200)
        XCTAssertLessThan(center!.g, 60)
        XCTAssertLessThan(center!.b, 60)
    }

    /// 창 밖에 있거나 숨은 뷰, 크기 없는 뷰는 찍지 않는다 — 빈 그림으로 카드를 덮지 않는다.
    func testThumbnailSkipsHiddenOrDetachedViews() {
        let detached = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        XCTAssertNil(Tab.thumbnail(of: detached))
        let hidden = UIView()
        let window = window(with: hidden)
        defer { window.isHidden = true }
        hidden.isHidden = true
        XCTAssertNil(Tab.thumbnail(of: hidden))
        XCTAssertNil(Tab.thumbnail(of: UIView()))
    }

    func testSnapshotWidthMatchesGridCard() {
        XCTAssertEqual(Tab.snapshotWidth, 200)
    }
}
