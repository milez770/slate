import Foundation
import WebKit
import os

/// 세션 쿠키(만료일 없는 쿠키) 영속화. 표준은 "세션이 끝나면 삭제"지만 iOS는 앱 프로세스를
/// 수시로 죽인다 — 그대로 두면 재실행마다 로그인이 풀린다. 데스크톱 크롬의 세션 복원과
/// 같은 층: 쿠키 변화를 관찰해 세션 쿠키만 파일로 저장하고, 앱 시작 때 웹뷰가 페이지를
/// 열기 전에 되살린다. 만료일 있는 쿠키는 WebKit이 스스로 디스크에 보존하므로 안 만진다.
@MainActor
final class SessionCookieStore: NSObject {
    static let shared = SessionCookieStore(fileURL: defaultFileURL())
    private static let logger = Logger(subsystem: "com.wonseon.slate", category: "sessioncookies")

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session-cookies.plist")
    }

    /// 저장해 둔 세션 쿠키를 쿠키 저장소에 되살린다. 첫 페이지 로드 전에 불러야
    /// 로그인 풀린 화면이 먼저 뜨지 않는다.
    func restore(into store: WKHTTPCookieStore) async {
        for cookie in loadCookies() {
            await store.setCookie(cookie)
        }
    }

    /// 쿠키 변화 관찰 시작. restore() 다음에 부른다.
    func attach(to store: WKHTTPCookieStore) {
        store.add(self)
    }

    /// 만료일 없는 쿠키만 남긴다 — 만료일 있는 쿠키는 WebKit이 알아서 보존한다.
    nonisolated static func sessionCookies(from cookies: [HTTPCookie]) -> [HTTPCookie] {
        cookies.filter { $0.isSessionOnly }
    }

    func save(_ cookies: [HTTPCookie]) {
        let dicts = Self.sessionCookies(from: cookies).compactMap { cookie -> [String: Any]? in
            guard let properties = cookie.properties else { return nil }
            var plain: [String: Any] = [:]
            for (key, value) in properties { plain[key.rawValue] = value }
            return plain
        }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: dicts, format: .binary, options: 0)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Self.logger.error("save(): \(error.localizedDescription, privacy: .public)")
        }
    }

    func loadCookies() -> [HTTPCookie] {
        guard let data = try? Data(contentsOf: fileURL),
              let dicts = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [[String: Any]] else {
            return []
        }
        return dicts.compactMap { plain in
            var properties: [HTTPCookiePropertyKey: Any] = [:]
            for (key, value) in plain { properties[HTTPCookiePropertyKey(key)] = value }
            return HTTPCookie(properties: properties)
        }
    }

    /// 변화가 몰릴 때(페이지 하나가 쿠키 여럿을 심는다) 매번 쓰지 않게 0.5초 모아서 저장한다.
    private func scheduleSnapshot(of store: WKHTTPCookieStore) {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            let cookies = await store.allCookies()
            self.save(cookies)
        }
    }
}

extension SessionCookieStore: WKHTTPCookieStoreObserver {
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in
            self.scheduleSnapshot(of: cookieStore)
        }
    }
}
