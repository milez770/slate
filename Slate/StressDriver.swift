#if DEBUG
import Foundation
import UIKit

/// 기기 부하 시험용. 실행 인자 -slate.stress "호스트 호스트 …"로 켜면 그 호스트의 탭들 사이에서만,
/// 0.8~1.6초마다 탭 바꾸기(격자 열고 고르기)·스크롤·같은 사이트 링크 누르기·뒤로 가기 중 하나를 한다.
/// 그 호스트의 탭이 없으면 새 탭으로 연다. -slate.backcheck는 뒤로가기 확인을 돌린다(startBackCheck).
/// 디버그 빌드에만 있다.
@MainActor
enum StressDriver {
    static func start(_ store: TabStore) {
        if let raw = UserDefaults.standard.string(forKey: "slate.navcheck"), let url = URL(string: raw) {
            startNavCheck(store, url: url)
            return
        }
        if let raw = UserDefaults.standard.string(forKey: "slate.backcheck") {
            startBackCheck(store, hosts: hostList(raw))
            return
        }
        guard let raw = UserDefaults.standard.string(forKey: "slate.stress") else { return }
        let hosts = hostList(raw)
        guard !hosts.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            for host in hosts where !store.tabs.contains(where: { $0.lastURL?.host?.hasSuffix(host) == true }) {
                store.newTab()
                store.activeTab?.webView.load(URLRequest(url: URL(string: "https://\(host)/")!))
                try? await Task.sleep(for: .seconds(2))
            }
            var step = 0
            while true {
                step += 1
                let candidates = store.tabs.filter { matches($0, hosts) }
                let tab = store.activeTab
                switch Int.random(in: 0..<10) {
                case 0...2:
                    if let next = candidates.filter({ $0 !== tab }).randomElement() {
                        store.openGrid()
                        try? await Task.sleep(for: .milliseconds(400))
                        store.pick(next)
                    }
                case 3...5:
                    _ = try? await tab?.webView.evaluateJavaScript("window.scrollBy(0, \(Int.random(in: 400...2500))); 0")
                case 6...8:
                    _ = try? await tab?.webView.evaluateJavaScript(clickSameSiteLink)
                default:
                    if tab?.webView.canGoBack == true { tab?.webView.goBack() }
                }
                if step % 50 == 0 { MemoryLog.event("부하 동작 \(step)회 · 대상 탭 \(candidates.count)개") }
                try? await Task.sleep(for: .milliseconds(Int.random(in: 800...1600)))
            }
        }
    }

    private static func hostList(_ raw: String) -> [String] {
        raw.split(separator: " ").map { token in
            let text = String(token)
            return URL(string: text)?.host ?? text
        }
    }

    /// 실행 인자 -slate.backcheck "호스트 …": 그 호스트의 탭을 차례로 골라 같은 사이트 링크로 넘어간 뒤
    /// 뒤로 가고, 2.5초 뒤 주소·글자·화면을 보고 남긴다. 두 번에 한 번은 넘어간 뒤 그 탭을 내렸다가
    /// 되살린 다음 뒤로 간다 — 메모리 부족 알림으로 탭이 내려간 뒤와 같은 상황이다.
    private static func startBackCheck(_ store: TabStore, hosts: [String]) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            var round = 0
            while true {
                let candidates = store.tabs.filter { matches($0, hosts) }
                for tab in candidates {
                    round += 1
                    let unloadFirst = round % 2 == 0
                    await select(tab, in: store)
                    await settle(tab)
                    guard let start = tab.webView.url else { continue }
                    _ = try? await tab.webView.evaluateJavaScript(clickSameSiteLink)
                    await waitForURLChange(tab, from: start)
                    await settle(tab)
                    guard tab.webView.url != start, tab.webView.canGoBack else {
                        MemoryLog.event("뒤로가기 확인 \(start.host ?? "") 링크로 못 넘어감")
                        continue
                    }
                    if unloadFirst, let other = store.tabs.first(where: { $0 !== tab }) {
                        await select(other, in: store)
                        store.hibernate(tab)
                        await select(tab, in: store)
                        await settle(tab)
                    }
                    tab.webView.goBack()
                    try? await Task.sleep(for: .milliseconds(2500))
                    let text = (try? await tab.webView.evaluateJavaScript(
                        "document.body ? document.body.innerText.trim().length : -1")) as? Int ?? -2
                    let backOK = HistoryStore.stripFragment(tab.webView.url ?? start) == HistoryStore.stripFragment(start)
                    let screen = isBlank(tab.webView).map { $0 ? "빔" : "정상" } ?? "못 찍음"
                    MemoryLog.event("뒤로가기 확인 \(start.host ?? "") 되살린뒤=\(unloadFirst) 주소=\(backOK ? "맞음" : "틀림") 글자=\(text) 화면=\(screen)")
                }
                if candidates.isEmpty { try? await Task.sleep(for: .seconds(5)) }
            }
        }
    }

    /// 실행 인자 -slate.navcheck "주소": 새 탭에 그 주소를 열고 "다음화" 링크를 다섯 번 누른 뒤 뒤로를
    /// 여섯 번 간다. 매번 웹뷰 주소·문서 주소·제목·뒤로가기 목록 길이를 남긴다.
    private static func startNavCheck(_ store: TabStore, url: URL) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            store.newTab()
            guard let tab = store.activeTab else { return }
            tab.webView.load(URLRequest(url: url))
            await settle(tab)
            await logPage(tab, "시작")
            // -slate.navcheck.next "주소": 다음화 대신 그 주소를 불러 한 번 넘어간다(보통 페이지 대조용).
            if let raw = UserDefaults.standard.string(forKey: "slate.navcheck.next"), let next = URL(string: raw) {
                tab.webView.load(URLRequest(url: next))
                await settle(tab)
                await logPage(tab, "넘어감")
            } else {
                await clickNextEpisodes(tab)
            }
            // -slate.navcheck.swipe YES면 뒤로는 바깥(UI 시험)이 밀어서 하고, 여기서는 1초마다 문서 상태만 남긴다.
            if UserDefaults.standard.bool(forKey: "slate.navcheck.swipe") {
                MemoryLog.event("이동 확인 앞으로 끝")
                for second in 1...60 {
                    try? await Task.sleep(for: .seconds(1))
                    await logPage(tab, "\(second)초")
                }
                return
            }
            for step in 1...6 {
                tab.webView.goBack()
                try? await Task.sleep(for: .milliseconds(2500))
                await logPage(tab, "뒤로 \(step)")
            }
        }
    }

    private static func clickNextEpisodes(_ tab: Tab) async {
            for step in 1...5 {
                let before = tab.webView.url
                _ = try? await tab.webView.evaluateJavaScript("""
                    (function(){var a=[].find.call(document.querySelectorAll('a'),function(e){return /다음화/.test(e.textContent);});
                    if(!a)return 0;a.click();return 1;})()
                    """)
                if let before { await waitForURLChange(tab, from: before) }
                await settle(tab)
                await logPage(tab, "다음화 \(step)")
            }
    }

    private static func logPage(_ tab: Tab, _ label: String) async {
        let list = tab.webView.backForwardList
        let page = (try? await tab.webView.evaluateJavaScript(
            "location.pathname + ' | ' + document.title.slice(0, 30) + ' | history=' + history.length")) as? String ?? "?"
        MemoryLog.event("이동 확인 \(label): 웹뷰=\(tab.webView.url?.path ?? "-") 문서=\(page) 뒤목록=\(list.backList.count) 앞목록=\(list.forwardList.count) 현재항목=\(list.currentItem?.url.path ?? "-")")
    }

    private static func select(_ tab: Tab, in store: TabStore) async {
        store.openGrid()
        try? await Task.sleep(for: .milliseconds(400))
        store.pick(tab)
        try? await Task.sleep(for: .milliseconds(600))
    }

    /// 로딩이 끝나고 1초 더 기다린다. 10초를 넘기면 그냥 넘어간다.
    private static func settle(_ tab: Tab) async {
        for _ in 0..<50 where tab.webView.isLoading { try? await Task.sleep(for: .milliseconds(200)) }
        try? await Task.sleep(for: .seconds(1))
    }

    private static func waitForURLChange(_ tab: Tab, from url: URL) async {
        for _ in 0..<50 where tab.webView.url == url { try? await Task.sleep(for: .milliseconds(200)) }
    }

    /// 웹뷰 화면이 한 색인가. 작게 줄여 밝기 분산을 본다.
    private static func isBlank(_ view: UIView) -> Bool? {
        guard let cg = Tab.thumbnail(of: view)?.cgImage else { return nil }
        let width = 36, height = 72
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var values: [Double] = []
        for i in stride(from: 0, to: pixels.count, by: 4) {
            values.append(0.3 * Double(pixels[i]) + 0.59 * Double(pixels[i + 1]) + 0.11 * Double(pixels[i + 2]))
        }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
        return variance < 4
    }

    private static func matches(_ tab: Tab, _ hosts: [String]) -> Bool {
        guard let host = tab.lastURL?.host else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// 같은 사이트의 다른 페이지 링크 하나를 누른다. 사이트의 클릭 처리기(팝업 포함)가 그대로 돈다.
    private static let clickSameSiteLink = """
    (function(){var links=[].filter.call(document.querySelectorAll('a[href]'),function(a){
      try{var u=new URL(a.href,location.href);return u.hostname===location.hostname&&u.pathname!==location.pathname;}catch(e){return false;}});
    if(!links.length)return 0;links[Math.floor(Math.random()*links.length)].click();return 1;})()
    """
}
#endif
