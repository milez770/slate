import XCTest
@testable import Slate

final class FilterManagerTests: XCTestCase {
    func testConversionProducesRules() throws {
        let json = try FilterManager.convert(filterText: "||doubleclick.net^\n||adservice.google.com^")
        XCTAssertTrue(json.contains("doubleclick"))
    }
    func testConversionSurvivesJunkLines() throws {
        let json = try FilterManager.convert(filterText: "! comment\n\n||example-ad.com^")
        XCTAssertTrue(json.contains("example-ad"))
    }
    /// 감지 회피 목록은 요소 숨김 규칙만 빼고 차단 규칙은 그대로 둔다.
    func testStripCosmeticRulesKeepsBlockingRules() throws {
        let json = """
        [{"trigger":{"url-filter":"ads\\\\.example"},"action":{"type":"block"}},
         {"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":".adsbox"}},
         {"trigger":{"url-filter":"track\\\\.example"},"action":{"type":"block-cookies"}}]
        """
        let stripped = try FilterManager.stripCosmeticRules(json)
        let rules = try JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [[String: Any]]
        let types = rules?.compactMap { ($0["action"] as? [String: Any])?["type"] as? String }
        XCTAssertEqual(types, ["block", "block-cookies"])
    }

    /// 실제 변환 결과에도 요소 숨김이 들어 있고, 벗기면 사라진다.
    func testStripCosmeticRulesOnConvertedList() throws {
        let json = try FilterManager.convert(filterText: "||doubleclick.net^\n##.adsbox")
        XCTAssertTrue(json.contains("css-display-none"))
        let stripped = try FilterManager.stripCosmeticRules(json)
        XCTAssertFalse(stripped.contains("css-display-none"))
        XCTAssertTrue(stripped.contains("doubleclick"))
    }

    func testBundledFilterListsExist() {
        XCTAssertNotNil(Bundle.main.url(forResource: "easylist", withExtension: "txt"))
        XCTAssertNotNil(Bundle.main.url(forResource: "list-kr", withExtension: "txt"))
        XCTAssertNotNil(Bundle.main.url(forResource: "youslist", withExtension: "txt"))
    }
}
