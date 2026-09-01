import XCTest
@testable import Slate

final class AddressResolverTests: XCTestCase {
    func testDomainGetsHTTPS() {
        XCTAssertEqual(AddressResolver.url(from: "naver.com").absoluteString, "https://naver.com")
    }
    func testFullURLKept() {
        XCTAssertEqual(AddressResolver.url(from: "http://example.com/a?b=1").absoluteString, "http://example.com/a?b=1")
    }
    func testKoreanQueryGoesToSearch() {
        let url = AddressResolver.url(from: "김치 볶음밥")
        XCTAssertEqual(url.host, "www.google.com")
        XCTAssertTrue(url.absoluteString.contains("search"))
    }
    func testSingleWordWithoutDotGoesToSearch() {
        XCTAssertEqual(AddressResolver.url(from: "slate").host, "www.google.com")
    }
}
