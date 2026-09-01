import Foundation
import Observation
import os
import WebKit

/// 한 도메인에 심을 쿠키 한 줄. 사용자가 설정 화면에서 도메인·이름·값·만료(일)를 넣는다.
/// 해외 접속 시 지역·연령 확인 관문이 심어 주는 확인 쿠키를 미리 박아 관문을 건너뛰는 용도.
/// 특정 사이트 값은 코드에 없다 — 사용자가 직접 넣는다.
struct CookieRule: Codable, Equatable, Identifiable {
    var domain: String
    var name: String
    var value: String
    var expiresDays: Int
    var id: String { domain + "|" + name }

    /// 이 규칙을 심을 쿠키로 바꾼다. 도메인·이름이 비면 nil — 반쪽 규칙은 쿠키를 안 만든다.
    /// path는 사이트 전체(/)를 덮고, 앞에 점이 붙은 도메인(.example.co.jp)은 서브도메인까지 먹는다.
    func httpCookie() -> HTTPCookie? {
        let trimmedDomain = domain.trimmingCharacters(in: .whitespaces)
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedDomain.isEmpty, !trimmedName.isEmpty else { return nil }
        return HTTPCookie(properties: [
            .domain: trimmedDomain,
            .path: "/",
            .name: trimmedName,
            .value: value,
            .expires: Date(timeIntervalSinceNow: TimeInterval(max(expiresDays, 0)) * 86400),
        ])
    }
}

@MainActor
@Observable
final class CookieRuleStore {
    static let shared = CookieRuleStore(fileURL: defaultFileURL())
    private static let logger = Logger(subsystem: "com.wonseon.slate", category: "cookierules")

    private let fileURL: URL
    private(set) var rules: [CookieRule] = []

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    static func defaultFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cookie-rules.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([CookieRule].self, from: data) else { return }
        rules = decoded
    }

    private func save() {
        do {
            try JSONEncoder().encode(rules).write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("save(): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 같은 도메인·이름 규칙이 있으면 값·만료를 갈고, 없으면 붙인다.
    func add(_ rule: CookieRule) {
        if let i = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[i] = rule
        } else {
            rules.append(rule)
        }
        save()
    }

    func remove(_ rule: CookieRule) {
        rules.removeAll { $0.id == rule.id }
        save()
    }

    /// 든 규칙 전부를 쿠키로. 반쪽 규칙(빈 도메인·이름)은 빠진다.
    func httpCookies() -> [HTTPCookie] {
        rules.compactMap { $0.httpCookie() }
    }

    /// 앱 시작 때 첫 페이지 로드 전에 쿠키를 심는다. SessionCookieStore.restore와 같은 자리.
    func inject(into store: WKHTTPCookieStore) async {
        for cookie in httpCookies() {
            await store.setCookie(cookie)
        }
    }
}
