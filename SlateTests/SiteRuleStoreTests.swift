import XCTest
@testable import Slate

final class SiteRuleStoreTests: XCTestCase {
    @MainActor
    private func tempStore(_ name: String = #function) -> SiteRuleStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-tests-\(name)-\(UUID().uuidString).json")
        return SiteRuleStore(fileURL: url)
    }

    private let rule = SiteRule(kind: "selector", value: "[data-banner-link]", added: Date(timeIntervalSince1970: 0))

    @MainActor func testRoundtripAcrossInstances() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-tests-roundtrip-\(UUID().uuidString).json")
        let first = SiteRuleStore(fileURL: url)
        first.add([rule], host: "site7.com")
        let second = SiteRuleStore(fileURL: url)
        XCTAssertEqual(second.rules(for: "site7.com"), [rule])
    }

    @MainActor func testDuplicateRuleIsNotStoredTwice() {
        let store = tempStore()
        store.add([rule], host: "site7.com")
        store.add([rule], host: "site7.com")
        XCTAssertEqual(store.rules(for: "site7.com").count, 1)
    }

    @MainActor func testRemoveSingleAndAll() {
        let store = tempStore()
        let other = SiteRule(kind: "imgSrcPrefix", value: "cdn1.example/board_uploads/", added: Date(timeIntervalSince1970: 0))
        store.add([rule, other], host: "site7.com")
        store.remove(rule, host: "site7.com")
        XCTAssertEqual(store.rules(for: "site7.com"), [other])
        store.removeAll(host: "site7.com")
        XCTAssertTrue(store.rules(for: "site7.com").isEmpty)
        XCTAssertFalse(store.hosts.contains("site7.com"))
    }

    @MainActor func testNewRuleIsEnabledByDefault() {
        let store = tempStore()
        store.add([rule], host: "site7.com")
        XCTAssertEqual(store.enabledRules(for: "site7.com"), [rule])
    }

    @MainActor func testDisabledRuleStaysInListButNotApplied() {
        let store = tempStore()
        let other = SiteRule(kind: "selector", value: ".vw-mini-icon", added: Date(timeIntervalSince1970: 0))
        store.add([rule, other], host: "site7.com")
        store.setEnabled(other, enabled: false, host: "site7.com")
        XCTAssertEqual(store.rules(for: "site7.com").count, 2, "꺼도 목록엔 남는다")
        XCTAssertEqual(store.enabledRules(for: "site7.com").map(\.id), [rule.id], "꺼진 규칙은 적용되지 않는다")
    }

    @MainActor func testEnabledStateSurvivesReload() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-tests-enabled-\(UUID().uuidString).json")
        let first = SiteRuleStore(fileURL: url)
        first.add([rule], host: "site7.com")
        first.setEnabled(rule, enabled: false, host: "site7.com")
        let second = SiteRuleStore(fileURL: url)
        XCTAssertTrue(second.enabledRules(for: "site7.com").isEmpty)
        XCTAssertEqual(second.rules(for: "site7.com").first?.enabled, false)
    }

    @MainActor func testOldJSONWithoutEnabledDecodesAsOn() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-tests-legacy-\(UUID().uuidString).json")
        let legacy = #"{"site7.com":[{"kind":"selector","value":"[data-banner-link]","added":0}]}"#
        try legacy.data(using: .utf8)!.write(to: url)
        let store = SiteRuleStore(fileURL: url)
        XCTAssertEqual(store.enabledRules(for: "site7.com").count, 1, "enabled 없는 옛 규칙은 켜진 것으로 읽는다")
    }

    @MainActor func testHostStemMatching() {
        XCTAssertTrue(SiteRuleStore.matches(stored: "site7.com", visiting: "site7.com"))
        XCTAssertTrue(SiteRuleStore.matches(stored: "site7.com", visiting: "site8.com"))
        XCTAssertTrue(SiteRuleStore.matches(stored: "site7.com", visiting: "www.site12.com"))
        XCTAssertFalse(SiteRuleStore.matches(stored: "site7.com", visiting: "example.com"),
                       "방문 호스트에 숫자 접미사가 없으면 어간 매칭을 쓰지 않는다 — 다른 소유자일 수 있어 규칙이 새면 안 된다")
        XCTAssertFalse(SiteRuleStore.matches(stored: "site7.com", visiting: "rite8.com"))
        XCTAssertFalse(SiteRuleStore.matches(stored: "site7.com", visiting: "site7.net"))
        XCTAssertFalse(SiteRuleStore.matches(stored: "site.com", visiting: "site31.com"),
                       "저장된 호스트에 숫자 접미사가 없으면 정확 일치만 쓴다")
        XCTAssertFalse(SiteRuleStore.matches(stored: "a1.com", visiting: "a2.com"),
                       "어간이 3자 미만이면 어간 매칭을 쓰지 않는다")
    }

    @MainActor func testRulesLookupUsesStemMatching() {
        let store = tempStore()
        store.add([rule], host: "site7.com")
        XCTAssertEqual(store.rules(for: "site8.com"), [rule])
    }

    /// add()로는 어간이 같은 두 호스트를 한 키로 합쳐버려 다중 키 병합 경로를 못 탄다.
    /// 저장 파일에 두 키를 직접 써서 새 인스턴스로 읽어야 실제 병합 코드를 검증한다.
    private func seedFile(_ seed: [String: [SiteRule]], name: String = #function) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-tests-\(name)-\(UUID().uuidString).json")
        let data = try! JSONEncoder().encode(seed)
        try! data.write(to: url)
        return url
    }

    @MainActor func testRulesLookupMergesMultipleMatchingHostsDeterministically() {
        let ruleA = SiteRule(kind: "selector", value: "[data-a]", added: Date(timeIntervalSince1970: 0))
        let ruleB = SiteRule(kind: "selector", value: "[data-b]", added: Date(timeIntervalSince1970: 0))
        let url = seedFile(["site7.com": [ruleA], "site8.com": [ruleB]])
        let store = SiteRuleStore(fileURL: url)
        XCTAssertEqual(store.rules(for: "site9.com"), [ruleA, ruleB])
        XCTAssertEqual(store.rules(for: "site9.com"), [ruleA, ruleB])
    }

    @MainActor func testRulesLookupPrefersEarlierKeyForDuplicateIdAcrossHosts() {
        let earlier = SiteRule(kind: "selector", value: "[data-banner-link]", added: Date(timeIntervalSince1970: 0))
        let later = SiteRule(kind: "selector", value: "[data-banner-link]", added: Date(timeIntervalSince1970: 100))
        let url = seedFile(["site7.com": [earlier], "site8.com": [later]])
        let store = SiteRuleStore(fileURL: url)
        XCTAssertEqual(store.rules(for: "site9.com"), [earlier])
    }

    @MainActor func testAddAttachesToExistingMatchingKeyInsteadOfFragmenting() {
        let store = tempStore()
        store.add([rule], host: "site7.com")
        let other = SiteRule(kind: "imgSrcPrefix", value: "cdn1.example/x/", added: Date(timeIntervalSince1970: 0))
        store.add([other], host: "site8.com")
        XCTAssertEqual(store.hosts, ["site7.com"])
        XCTAssertEqual(store.rules(for: "site7.com"), [rule, other])
    }

    @MainActor func testRemoveViaMatchingHostRemovesFromStoredKey() {
        let store = tempStore()
        store.add([rule], host: "site7.com")
        store.remove(rule, host: "site8.com")
        XCTAssertTrue(store.rules(for: "site7.com").isEmpty)
        XCTAssertFalse(store.hosts.contains("site7.com"))
    }

    @MainActor func testNumericSuffixHostDoesNotLeakToBareBrand() {
        let store = tempStore()
        store.add([rule], host: "site31.com")
        XCTAssertTrue(store.rules(for: "site.com").isEmpty)
    }
}
