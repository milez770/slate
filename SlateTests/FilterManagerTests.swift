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
    func testBundledFilterListsExist() {
        XCTAssertNotNil(Bundle.main.url(forResource: "easylist", withExtension: "txt"))
        XCTAssertNotNil(Bundle.main.url(forResource: "list-kr", withExtension: "txt"))
        XCTAssertNotNil(Bundle.main.url(forResource: "youslist", withExtension: "txt"))
    }
}
