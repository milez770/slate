#if DEBUG
import Foundation

/// 기기 부하 시험용. 실행 인자 -slate.stress "호스트 호스트 …"로 켜면 그 호스트의 탭들 사이에서만,
/// 0.8~1.6초마다 탭 바꾸기(격자 열고 고르기)·스크롤·같은 사이트 링크 누르기·뒤로 가기 중 하나를 한다.
/// 그 호스트의 탭이 없으면 새 탭으로 연다. 디버그 빌드에만 있다.
@MainActor
enum StressDriver {
    static func start(_ store: TabStore) {
        guard let raw = UserDefaults.standard.string(forKey: "slate.stress") else { return }
        let hosts = raw.split(separator: " ").map { token -> String in
            let text = String(token)
            return URL(string: text)?.host ?? text
        }
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
