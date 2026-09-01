import XCTest
@testable import Slate

final class AreaPickerTests: XCTestCase {
    @MainActor private func harness() -> ScriptHarness {
        ScriptHarness(scripts: [UserScripts.source(named: "area-picker")])
    }

    /// 지목 영역을 CSS 픽셀로 넘기고 돌려받은 규칙을 파싱한다.
    @MainActor private func pick(_ h: ScriptHarness, x: Int, y: Int, w: Int, h height: Int) async throws -> [[String: String]] {
        let js = "JSON.stringify(window.__slatePickArea({x:\(x),y:\(y),w:\(w),h:\(height)}))"
        guard let json = try await h.eval(js) as? String,
              let data = json.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return []
        }
        return parsed
    }

    /// 대상을 body 직속 자식으로 둔다. 지목 대상이 곧 최상위 요소가 되게 하려는 배치다.
    private func page(_ bodyHTML: String) -> String {
        "<html><head><style>body{margin:0}</style></head><body>" + bodyHTML + "</body></html>"
    }

    private let box = "width:380px;height:100px"

    @MainActor func testRemovesOnlyElementsFullyInsideArea() async throws {
        let html = page(
            "<div style=\"\(box)\" data-banner-link=\"https://a.com\">A</div>"
            + "<div style=\"\(box)\" data-banner-link=\"https://b.com\">B</div>"
            + "<div id=\"keep\" style=\"\(box)\">본문</div>")
        let h = harness()
        await h.load(html)
        _ = try await pick(h, x: 0, y: 0, w: 390, h: 210)
        let bannerCount = try await h.count("[data-banner-link]")
        let keepCount = try await h.count("#keep")
        XCTAssertEqual(bannerCount, 0)
        XCTAssertEqual(keepCount, 1, "영역 밖 요소는 남는다")
    }

    @MainActor func testCatchesFullWidthBannerWhenSelectionMissesEdges() async throws {
        // 화면 폭을 꽉 채운 배너는 손가락으로 양끝까지 못 담는다. 가운데 350px만 담아도 잡혀야 한다.
        let html = page(
            "<div id=\"banner\" style=\"width:390px;height:100px\" data-banner-link=\"https://a.com\">A</div>"
            + "<div id=\"keep\" style=\"\(box)\">본문</div>")
        let h = harness()
        await h.load(html)
        let rules = try await pick(h, x: 20, y: 5, w: 350, h: 90)
        XCTAssertEqual(rules.first?["value"], "[data-banner-link]")
        let bannerCount = try await h.count("#banner")
        let keepCount = try await h.count("#keep")
        XCTAssertEqual(bannerCount, 0)
        XCTAssertEqual(keepCount, 1, "사각형에 조금 걸친 아래 본문은 남는다")
    }

    @MainActor func testSmallSelectionDoesNotTakeLargeContainer() async throws {
        // 큰 본문 래퍼 안의 작은 광고만 담으면 래퍼는 남고 광고만 지워진다.
        let html = page(
            "<div id=\"wrap\" style=\"width:390px;height:1200px\">"
            + "<div id=\"ad\" style=\"width:300px;height:250px\" data-banner-link=\"https://a.com\">A</div>"
            + "<p>본문</p></div>")
        let h = harness()
        await h.load(html)
        _ = try await pick(h, x: 0, y: 0, w: 320, h: 260)
        let adCount = try await h.count("#ad")
        let wrapCount = try await h.count("#wrap")
        XCTAssertEqual(adCount, 0)
        XCTAssertEqual(wrapCount, 1)
    }

    @MainActor func testKeepsBodyWhenAreaCoversEverything() async throws {
        let html = page("<div style=\"\(box)\">A</div>")
        let h = harness()
        await h.load(html)
        _ = try await pick(h, x: 0, y: 0, w: 3000, h: 3000)
        let bodyCount = try await h.count("body")
        let divCount = try await h.count("div")
        XCTAssertEqual(bodyCount, 1)
        XCTAssertEqual(divCount, 0)
    }

    @MainActor func testAttributeRuleWinsOverIdAndClass() async throws {
        let html = page("<div id=\"promo\" class=\"row\" style=\"\(box)\" data-banner-link=\"https://a.com\">A</div>")
        let h = harness()
        await h.load(html)
        let rules = try await pick(h, x: 0, y: 0, w: 390, h: 110)
        XCTAssertEqual(rules.first?["kind"], "selector")
        XCTAssertEqual(rules.first?["value"], "[data-banner-link]")
    }

    @MainActor func testFallsBackToImageSourcePrefix() async throws {
        let html = page("<div style=\"\(box)\"><img src=\"https://cdn1.example/board_uploads/2026/x.png\" width=\"380\" height=\"100\"></div>")
        let h = harness()
        await h.load(html)
        let rules = try await pick(h, x: 0, y: 0, w: 390, h: 110)
        XCTAssertEqual(rules.first?["kind"], "imgSrcPrefix")
        XCTAssertEqual(rules.first?["value"], "cdn1.example/board_uploads/")
    }

    @MainActor func testFallsBackToDomPath() async throws {
        let html = page("<div style=\"\(box)\"><span>광고</span></div>")
        let h = harness()
        await h.load(html)
        let rules = try await pick(h, x: 0, y: 0, w: 390, h: 110)
        XCTAssertEqual(rules.first?["kind"], "selector")
        XCTAssertEqual(rules.first?["value"], "body>div:nth-child(1)")
    }

    @MainActor func testSkipsHashLikeClassNames() async throws {
        let html = page("<div class=\"row css1a2b3c4d\" style=\"\(box)\">광고</div>")
        let h = harness()
        await h.load(html)
        let rules = try await pick(h, x: 0, y: 0, w: 390, h: 110)
        XCTAssertEqual(rules.first?["value"], ".row", "해시 같은 class는 규칙에 넣지 않는다")
    }

    @MainActor func testDemotesTooBroadSelector() async throws {
        let filler = (0..<40).map { _ in "<span class=\"cell\">x</span>" }.joined()
        let html = page("<div class=\"cell\" style=\"\(box)\"><img src=\"https://cdn.example.com/ads/a.png\"></div>" + filler)
        let h = harness()
        await h.load(html)
        let rules = try await pick(h, x: 0, y: 0, w: 390, h: 110)
        XCTAssertEqual(rules.first?["kind"], "imgSrcPrefix",
                       "41개를 잡는 .cell은 너무 넓어 한 단계 아래 규칙으로 내려간다")
        XCTAssertEqual(rules.first?["value"], "cdn.example.com/ads/")
    }

    @MainActor func testDemotesTooBroadImagePrefixToPathRule() async throws {
        // 광고 이미지와 본문 썸네일 40장이 같은 첫 경로 세그먼트(images/)를 쓴다.
        // 픽업 영역 밖(top:5000px)에 둬 지목 대상 자체는 광고 div 하나뿐이게 한다.
        let filler = (0..<40).map { i in
            "<img style=\"position:absolute;top:5000px\" src=\"https://cdn.example.com/images/thumb\(i).png\">"
        }.joined()
        let html = page(
            "<div style=\"\(box)\"><img src=\"https://cdn.example.com/images/ad.png\"></div>" + filler)
        let h = harness()
        await h.load(html)
        let rules = try await pick(h, x: 0, y: 0, w: 390, h: 110)
        XCTAssertEqual(rules.first?["kind"], "selector",
                       "같은 접두사 이미지가 41장이면 imgSrcPrefix도 너무 넓어 경로 규칙(5순위)으로 내려간다")
        XCTAssertEqual(rules.first?["value"], "body>div:nth-child(1)")
    }

    /// 페이지를 스크롤한 상태에서도 지목 영역(문서 좌표)에 겹치는 요소가 잡히는지 확인한다.
    /// Swift가 화면 좌표 + contentOffset을 넘긴다고 가정하고, 여기서는 그 결과인 문서 좌표를
    /// 직접 넘긴다 — insideArea가 getBoundingClientRect(뷰포트 좌표)에 scrollY를 더해
    /// 같은 좌표계로 맞추는지가 검증 대상이다.
    @MainActor func testMatchesElementAfterScroll() async throws {
        let html = page(
            "<div style=\"height:2000px\">필러</div>"
            + "<div id=\"banner\" style=\"\(box)\" data-banner-link=\"https://a.com\">광고</div>")
        let h = harness()
        await h.load(html)
        _ = try await h.eval("window.scrollTo(0, 2000); 1")
        // 배너는 문서 좌표로 y=2000~2100. 스크롤 후에도 같은 문서 좌표를 넘기면 잡혀야 한다.
        let rules = try await pick(h, x: 0, y: 2000, w: 390, h: 110)
        XCTAssertEqual(rules.first?["value"], "[data-banner-link]",
                       "스크롤된 상태에서도 문서 좌표 기준으로 대상이 잡혀야 한다")
        let bannerCount = try await h.count("#banner")
        XCTAssertEqual(bannerCount, 0, "잡힌 배너는 지워진다")
    }
}
