import XCTest
@testable import Slate

final class URLPartTests: XCTestCase {
    private let url = URL(string: "https://example.org/list/all-1.html?page=3#12")!

    func testParts() {
        let texts = URLPart.parts(of: url).map(\.text)
        XCTAssertEqual(texts, ["example.org", "list", "all-1.html", "page=3", "#12"])
    }

    func testReplacePathComponent() {
        let part = URLPart.parts(of: url)[2]
        XCTAssertEqual(part.replacing(with: "all-2.html", in: url)?.absoluteString,
                       "https://example.org/list/all-2.html?page=3#12")
    }

    func testReplaceQueryItem() {
        let part = URLPart.parts(of: url)[3]
        XCTAssertEqual(part.replacing(with: "page=7", in: url)?.absoluteString,
                       "https://example.org/list/all-1.html?page=7#12")
    }

    func testReplaceFragment() {
        let part = URLPart.parts(of: url)[4]
        XCTAssertEqual(part.replacing(with: "#5", in: url)?.absoluteString,
                       "https://example.org/list/all-1.html?page=3#5")
    }

    func testReplaceHost() {
        let part = URLPart.parts(of: url)[0]
        XCTAssertEqual(part.replacing(with: "example.com", in: url)?.absoluteString,
                       "https://example.com/list/all-1.html?page=3#12")
    }

    /// 마지막 숫자 덩어리만 움직인다 — all-1의 1이지 앞의 다른 숫자가 아니다.
    func testStepping() {
        XCTAssertEqual(URLPart.stepping("all-1.html", by: 1), "all-2.html")
        XCTAssertEqual(URLPart.stepping("all-1.html", by: -1), "all-0.html")
        XCTAssertEqual(URLPart.stepping("all-0.html", by: -1), "all-0.html")
        XCTAssertEqual(URLPart.stepping("1234.html", by: 1), "1235.html")
        XCTAssertEqual(URLPart.stepping("page=9", by: 1), "page=10")
        XCTAssertNil(URLPart.stepping("tag", by: 1))
    }

    /// 쪽 넘김 판별: 숫자만 다른 경로·쿼리/# 변화는 제자리, 모양이 다르면 새 탭감.
    func testPaginationMove() {
        let list1 = URL(string: "https://example.org/list/all-1.html")!
        let list2 = URL(string: "https://example.org/list/all-2.html")!
        let reader = URL(string: "https://example.org/view/1234.html")!
        let otherSite = URL(string: "https://example.com/list/all-2.html")!
        let sameFragment = URL(string: "https://example.org/list/all-1.html#5")!
        XCTAssertTrue(URLPart.isPaginationMove(from: list1, to: list2))
        XCTAssertTrue(URLPart.isPaginationMove(from: list1, to: sameFragment))
        XCTAssertFalse(URLPart.isPaginationMove(from: list1, to: reader))
        XCTAssertFalse(URLPart.isPaginationMove(from: list1, to: otherSite))
        // 작품 번호끼리는 숫자만 달라 제자리로 판정된다 — 읽기 화면에서 다음 화 이동
        XCTAssertTrue(URLPart.isPaginationMove(
            from: reader, to: URL(string: "https://example.org/view/1235.html")!))
    }

    /// 1쪽은 꼬리가 없고 2쪽부터 /page/N이 붙는 목록: 1쪽↔2쪽 왕복, 첫 화면→목록 2쪽,
    /// ?page=N 쿼리 전부 제자리. 상세 글은 새 탭.
    func testPageSuffixPagination() {
        let first = URL(string: "https://example.org/albums/")!
        let second = URL(string: "https://example.org/albums/page/2/")!
        let third = URL(string: "https://example.org/albums/page/3/")!
        let home = URL(string: "https://example.org/home1/")!
        let post = URL(string: "https://example.org/nyako-88-photos-2/")!
        XCTAssertTrue(URLPart.isPaginationMove(from: first, to: second))
        XCTAssertTrue(URLPart.isPaginationMove(from: second, to: first))
        XCTAssertTrue(URLPart.isPaginationMove(from: second, to: third))
        XCTAssertTrue(URLPart.isPaginationMove(from: home, to: second))
        XCTAssertTrue(URLPart.isPaginationMove(from: first, to: URL(string: "https://example.org/albums/page-2")!))
        XCTAssertTrue(URLPart.isPaginationMove(from: home, to: URL(string: "https://example.org/albums?page=2")!))
        XCTAssertFalse(URLPart.isPaginationMove(from: first, to: post))
        XCTAssertFalse(URLPart.isPaginationMove(from: second, to: post))
        XCTAssertFalse(URLPart.isPaginationMove(from: first, to: URL(string: "https://example.org/albums/123/")!),
                       "맨 숫자 조각은 글 번호일 수 있어 쪽 번호로 안 본다")
        XCTAssertFalse(URLPart.isPaginationMove(from: first, to: URL(string: "https://example.org/homepage2/")!))
        XCTAssertFalse(URLPart.isPaginationMove(from: home, to: URL(string: "https://example.org/albums?p=2")!),
                       "?p=N은 글 번호")
    }

    /// 인코딩된 경로(한글 태그)도 왕복이 깨지지 않는다.
    func testEncodedPathSurvives() {
        let encoded = URL(string: "https://example.org/list/%ED%95%9C%EA%B5%AD-1.html")!
        let parts = URLPart.parts(of: encoded)
        XCTAssertEqual(parts.map(\.text)[2], "한국-1.html")
        let stepped = parts[2].replacing(with: "한국-2.html", in: encoded)
        XCTAssertEqual(stepped?.absoluteString, "https://example.org/list/%ED%95%9C%EA%B5%AD-2.html")
    }
}
