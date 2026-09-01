import XCTest
@testable import Slate

final class BannerSweeperTests: XCTestCase {
    /// 1x1 투명 gif. 실제로 로드되므로 width/height 속성이 그 크기로 늘어나 렌더된다.
    private let pixel = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"

    @MainActor private func harness() -> ScriptHarness {
        ScriptHarness(scripts: [UserScripts.source(named: "banner-sweeper")])
    }

    /// 실측 배너 마크업 형태. class 없음, button + data-banner-link, 이미지 380x100.
    private func adBanner(_ target: String, _ id: String) -> String {
        """
        <button type="button" class="" data-banner-id="\(id)" data-banner-link="\(target)">
          <img src="\(pixel)" alt="\(target)" width="380" height="100">
        </button>
        """
    }

    @MainActor func testRemovesRowOfFirstPartyBanners() async throws {
        let banners = ["https://ad1.example", "https://ad2.example", "http://ad3.example/"]
            .enumerated().map { adBanner($0.element, "b\($0.offset)") }.joined()
        let html = "<html><body><div id=\"ads\">" + banners + "</div></body></html>"
        let h = harness()
        await h.load(html)
        let remaining = try await h.count("button")
        XCTAssertEqual(remaining, 0)
    }

    @MainActor func testKeepsLoneExternalBanner() async throws {
        let html = "<html><body><div>" + adBanner("https://example.com", "solo") + "</div></body></html>"
        let h = harness()
        await h.load(html)
        let remaining = try await h.count("button")
        XCTAssertEqual(remaining, 1, "형제가 없는 단독 배너는 남아야 한다")
    }

    @MainActor func testKeepsSameHostImageLinks() async throws {
        let rows = (0..<3).map { index in
            "<a href=\"https://site7.com/item/\(index)\"><img src=\"" + pixel + "\" width=\"380\" height=\"100\"></a>"
        }.joined()
        let html = "<html><body><div>" + rows + "</div></body></html>"
        let h = harness()
        await h.load(html)
        let remaining = try await h.count("a")
        XCTAssertEqual(remaining, 3, "같은 호스트로 가는 링크는 광고가 아니다")
    }

    @MainActor func testKeepsBannersWithText() async throws {
        let rows = (0..<3).map { index in
            "<a href=\"https://partner\(index).com\"><img src=\"" + pixel + "\" width=\"380\" height=\"100\">제휴사 \(index)</a>"
        }.joined()
        let html = "<html><body><div>" + rows + "</div></body></html>"
        let h = harness()
        await h.load(html)
        let remaining = try await h.count("a")
        XCTAssertEqual(remaining, 3, "텍스트가 있으면 광고로 보지 않는다")
    }

    @MainActor func testKeepsSquareThumbnails() async throws {
        let rows = (0..<3).map { index in
            "<a href=\"https://shop\(index).com\"><img src=\"" + pixel + "\" width=\"300\" height=\"300\"></a>"
        }.joined()
        let html = "<html><body><div>" + rows + "</div></body></html>"
        let h = harness()
        await h.load(html)
        let remaining = try await h.count("a")
        XCTAssertEqual(remaining, 3, "가로세로비 2.5 미만은 배너 규격이 아니다")
    }

    /// display:inline인 a는 자식 img의 높이를 라인박스에 반영하지 않는다(button은 반영한다) —
    /// 그래서 크기 측정을 이미지 자체로 하면 래퍼 태그와 무관하게 같은 판정이 나와야 한다.
    @MainActor func testRemovesRowOfInlineWrappedBanners() async throws {
        let rows = ["https://ad1.example", "https://ad2.example", "http://ad3.example/"]
            .map { target in "<a href=\"\(target)\"><img src=\"" + pixel + "\" width=\"380\" height=\"100\"></a>" }
            .joined()
        let html = "<html><body><div>" + rows + "</div></body></html>"
        let h = harness()
        await h.load(html)
        let remaining = try await h.count("a")
        XCTAssertEqual(remaining, 0, "인라인 a로 감싼 배너도 button과 동일하게 지워져야 한다")
    }
}
