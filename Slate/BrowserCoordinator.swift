import UIKit
import WebKit
import os

@MainActor
final class BrowserCoordinator: NSObject, WKUIDelegate, WKNavigationDelegate {
    var onCommit: (@MainActor (URL) -> Void)?
    var onFinish: (@MainActor (WKWebView) -> Void)?
    var onLoadEnd: (@MainActor (WKWebView) -> Void)?
    var onStart: (@MainActor () -> Void)?
    var onFail: (@MainActor (Error) -> Void)?
    /// 링크 롱탭 메뉴의 "새 탭에서 열기".
    var onOpenInNewTab: (@MainActor (URL) -> Void)?
    /// 고정 탭: 이 이동을 새 탭으로 돌려야 하면 true. 원래 페이지는 남는다.
    var shouldDetourToNewTab: (@MainActor (URL) -> Bool)?
    /// 메인 프레임이 이 주소로 이동하기 직전. 사이트별 차단 방식을 갈아 끼우는 데 쓴다.
    var onMainFrameNavigation: (@MainActor (URL) -> Void)?

    /// 번역을 요청해 온 하위 프레임. 원문 보기 토글을 이 프레임들에도 보낸다. 문서가 갈리면 비운다.
    private(set) var translationFrames: [WKFrameInfo] = []

    /// popup-guard가 광고 수법(창 열기·가짜 클릭)을 막은 마지막 시각. 광고 스크립트는
    /// 막히면 location 이동으로 넘어가는데, 그건 JS로 못 막는다 — 이 신호 직후의 딴 사이트
    /// 이동을 네이티브가 자른다.
    private var lastAdIntent: Date?

    func noteAdIntent() {
        lastAdIntent = Date()
    }

    private var adIntentAge: TimeInterval? {
        lastAdIntent.map { Date().timeIntervalSince($0) }
    }

    /// 웹뷰에 손이 닿은 마지막 시각. 스크립트 주도 이동(.other)이 사용자 조작에서 난 것인지 가른다.
    private var lastTouch: Date?

    func noteUserTouch() {
        lastTouch = Date()
    }

    private var touchAge: TimeInterval? {
        lastTouch.map { Date().timeIntervalSince($0) }
    }

    /// 웹뷰가 스스로 보여줄 수 있는 스킴. 그 밖(kakaotalk:·itms-apps:·tel: 등)은 다른 앱의 몫이다.
    nonisolated static let webSchemes: Set<String> = ["http", "https", "about", "blob", "data", "file", "javascript"]

    nonisolated static func isWebScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return true }
        return webSchemes.contains(scheme)
    }

    /// 사용자가 시작한 이동인가 — 누른 링크·보낸 폼, 또는 화면을 만진 뒤 2초 안의 스크립트 이동.
    /// 다른 앱 열기는 이것만 허용한다. 손 안 댄 채 스크립트가 시도하는 것(광고의 앱스토어 넘기기)은 버린다.
    nonisolated static func isUserInitiated(type: WKNavigationType, touchAge: TimeInterval?) -> Bool {
        switch type {
        case .linkActivated, .formSubmitted: return true
        default: return (touchAge ?? .infinity) < 2
        }
    }

    /// 고정 탭이 새 탭으로 돌릴 이동인가 — 누른 링크, 또는 화면을 만진 뒤 2초 안의 스크립트 이동.
    /// 카드가 `<a>`가 아니라 클릭 핸들러로 location을 바꾸는 사이트도 여기서 잡힌다. 폼 전송·
    /// 뒤로가기·새로고침·손 안 댄 리다이렉트는 제자리에서 간다.
    nonisolated static func shouldDetour(type: WKNavigationType, touchAge: TimeInterval?) -> Bool {
        switch type {
        case .linkActivated: return true
        case .other: return (touchAge ?? .infinity) < 2
        default: return false
        }
    }

    /// 등록 도메인(eTLD+1 근사). popup-guard.js의 registrable()과 같은 규칙.
    nonisolated static func registrableDomain(_ host: String) -> String {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host }
        let second = labels[labels.count - 2]
        let keep = second.count <= 3 ? 3 : 2   // co.kr·com.au 류
        return labels.suffix(keep).joined(separator: ".")
    }

    nonisolated static func isCrossSite(_ target: URL, current: URL?) -> Bool {
        guard let targetHost = target.host, let currentHost = current?.host else { return false }
        return registrableDomain(targetHost) != registrableDomain(currentHost)
    }

    /// 광고 신호 직후의 딴 사이트 이동만 자른다. JS 주도 이동(.other)은 3초, 링크 탭
    /// (.linkActivated — 화면을 덮은 투명 낚시 앵커)은 같은 제스처인 1초 안만. 신호가 없던
    /// 페이지(OAuth 리다이렉트 등 정상 이동)는 건드리지 않는다.
    nonisolated static func shouldBlockNavigation(type: WKNavigationType, target: URL, current: URL?,
                                                  adIntentAge: TimeInterval?) -> Bool {
        guard let age = adIntentAge,
              let scheme = target.scheme, scheme == "http" || scheme == "https",
              isCrossSite(target, current: current) else { return false }
        switch type {
        case .other: return age < 3
        case .linkActivated: return age < 1
        default: return false
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 웹뷰가 못 보여주는 스킴은 웹뷰에 태우지 않는다 — 태우면 "URL을 표시할 수 없다"
        // 오류로 끝난다. 사용자가 시작한 이동이면 다른 앱에서 열지 묻는다.
        if let url = navigationAction.request.url, !Self.isWebScheme(url) {
            decisionHandler(.cancel)
            if Self.isUserInitiated(type: navigationAction.navigationType, touchAge: touchAge) {
                confirmOpenExternalApp(url, from: webView)
            }
            return
        }
        if navigationAction.targetFrame?.isMainFrame == true,
           let url = navigationAction.request.url,
           Self.shouldBlockNavigation(type: navigationAction.navigationType, target: url,
                                      current: webView.url, adIntentAge: adIntentAge) {
            decisionHandler(.cancel)
            return
        }
        // 고정 탭: 사용자가 일으킨 이동이 다른 페이지 모양이면 새 탭으로 돌리고 이 페이지는
        // 그대로 둔다. 쪽 넘김(숫자만 다른 이동)은 제자리에서 간다.
        if navigationAction.targetFrame?.isMainFrame == true,
           Self.shouldDetour(type: navigationAction.navigationType, touchAge: touchAge),
           let url = navigationAction.request.url,
           shouldDetourToNewTab?(url) == true {
            onOpenInNewTab?(url)
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == true, let url = navigationAction.request.url {
            onMainFrameNavigation?(url)
        }
        decisionHandler(.allow)
    }

    /// 화면에 알릴 실패인가. 로딩 도중 다른 곳으로 이동하면 앞선 로드가 취소(-999)로 끝나고,
    /// 유니버설 링크를 다른 앱에 넘기면 WebKit이 그 이동을 중단(WebKitErrorDomain 102)으로
    /// 끝낸다 — 둘 다 페이지는 멀쩡하다. 거르지 않으면 멀쩡한 이동·앱 열기마다 오류가 뜬다.
    nonisolated static func isRealFailure(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return false }
        if error.domain == "WebKitErrorDomain" && error.code == 102 { return false }
        return true
    }

    /// 다른 앱에서 열지 묻는다. 주소를 그대로 보여준다 — 광고가 앱스토어로 보내는 시도를
    /// 사용자가 알아보고 거절할 수 있게. 열 앱이 없으면 그렇다고 알린다.
    private func confirmOpenExternalApp(_ url: URL, from webView: WKWebView) {
        guard let presenter = presenter(for: webView) else { return }
        let alert = UIAlertController(title: "다른 앱에서 열기",
                                      message: String(url.absoluteString.prefix(200)), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "취소", style: .cancel) { [weak self] _ in
            self?.dismissActivePanel = nil
        })
        let open = UIAlertAction(title: "열기", style: .default) { [weak self, weak webView] _ in
            self?.dismissActivePanel = nil
            UIApplication.shared.open(url) { opened in
                guard !opened else { return }
                Task { @MainActor in
                    guard let self, let webView else { return }
                    self.notify("이 주소를 열 수 있는 앱이 없다", on: webView)
                }
            }
        }
        alert.addAction(open)
        alert.preferredAction = open
        presentPanel(alert, on: presenter, cancel: {})
    }

    private func notify(_ message: String, on webView: WKWebView) {
        guard let presenter = presenter(for: webView) else { return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "확인", style: .default) { [weak self] _ in
            self?.dismissActivePanel = nil
        })
        presentPanel(alert, on: presenter, cancel: {})
    }

    /// 웹페이지가 띄우는 알림창 제목. 어느 사이트가 띄웠는지 보여준다 — 광고가 연달아
    /// 띄우는 경우 출처가 안 보이면 무엇을 누르는지 알 수 없다.
    nonisolated static func panelTitle(for url: URL?) -> String {
        url?.host ?? "이 페이지"
    }

    // 팝업: 기본 거부. 사용자가 직접 누른 링크, 또는 화면을 만진 직후 스크립트가 여는 같은
    // 사이트 창만 현재 탭에서 연다(다른 사이트 창은 popup-guard가 가짜 창으로 막는다). 단 같은
    // 제스처에서 광고 신호가 왔으면 그 링크는 화면을 덮은 낚시 앵커다 — 현재 탭에도 안 싣는다.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if Self.shouldDetour(type: navigationAction.navigationType, touchAge: touchAge),
           let url = navigationAction.request.url {
            if let age = adIntentAge, age < 1, Self.isCrossSite(url, current: webView.url) { return nil }
            // 고정 탭이면 target=_blank 링크도 현재 탭 대신 새 탭으로.
            if shouldDetourToNewTab?(url) == true {
                onOpenInNewTab?(url)
                return nil
            }
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    /// 링크 롱탭 메뉴. 시스템 기본 항목(열기·복사 등) 앞에 "새 탭에서 열기"를 얹는다.
    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        guard let url = elementInfo.linkURL else { completionHandler(nil); return }
        let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] suggested in
            let openInNewTab = UIAction(title: "새 탭에서 열기",
                                        image: UIImage(systemName: "plus.square.on.square")) { _ in
                Task { @MainActor in self?.onOpenInNewTab?(url) }
            }
            return UIMenu(children: [openInNewTab] + suggested)
        }
        completionHandler(configuration)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        onStart?()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        translationFrames.removeAll()
        if let url = webView.url { onCommit?(url) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish?(webView)
        onLoadEnd?(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onLoadEnd?(webView)
        if Self.isRealFailure(error) { onFail?(error) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onLoadEnd?(webView)
        if Self.isRealFailure(error) { onFail?(error) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: - 웹페이지 알림창

    // 아래 세 메서드를 구현하지 않으면 WebKit이 alert·confirm·prompt를 조용히 무시한다 —
    // confirm이 늘 취소로 처리돼 확인 절차가 있는 사이트가 그 지점에서 막힌다.
    // 어떤 경로로 빠져나가든 completionHandler를 반드시 부른다. 안 부르면 웹 프로세스가 멈춘다.

    /// 떠 있는 알림창을 취소로 닫는 손잡이. 탭 격자로 나갈 때 부른다 — 창을 그대로 두면
    /// 격자 위에 남아 어느 탭이 띄운 건지 알 수 없다.
    private var dismissActivePanel: (() -> Void)?

    func dismissPanels() {
        dismissActivePanel?()
        dismissActivePanel = nil
    }

    /// completionHandler를 정확히 한 번만 부르게 감싸고, 취소 닫기 손잡이를 등록한다.
    private func presentPanel(_ alert: UIAlertController, on presenter: UIViewController,
                              cancel: @escaping () -> Void) {
        dismissActivePanel = { [weak alert] in
            alert?.dismiss(animated: false)
            cancel()
        }
        presenter.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let presenter = presenter(for: webView) else { completionHandler(); return }
        var done = false
        let complete = { if !done { done = true; completionHandler() } }
        let alert = UIAlertController(title: Self.panelTitle(for: frame.request.url),
                                      message: message, preferredStyle: .alert)
        let accept = UIAlertAction(title: "확인", style: .default) { [weak self] _ in
            complete(); self?.dismissActivePanel = nil
        }
        alert.addAction(accept)
        alert.preferredAction = accept
        presentPanel(alert, on: presenter, cancel: complete)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let presenter = presenter(for: webView) else { completionHandler(false); return }
        var done = false
        let complete: (Bool) -> Void = { if !done { done = true; completionHandler($0) } }
        let alert = UIAlertController(title: Self.panelTitle(for: frame.request.url),
                                      message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "취소", style: .cancel) { [weak self] _ in
            complete(false); self?.dismissActivePanel = nil
        })
        let accept = UIAlertAction(title: "확인", style: .default) { [weak self] _ in
            complete(true); self?.dismissActivePanel = nil
        }
        alert.addAction(accept)
        alert.preferredAction = accept
        presentPanel(alert, on: presenter, cancel: { complete(false) })
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        guard let presenter = presenter(for: webView) else { completionHandler(nil); return }
        var done = false
        let complete: (String?) -> Void = { if !done { done = true; completionHandler($0) } }
        let alert = UIAlertController(title: Self.panelTitle(for: frame.request.url),
                                      message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "취소", style: .cancel) { [weak self] _ in
            complete(nil); self?.dismissActivePanel = nil
        })
        let accept = UIAlertAction(title: "확인", style: .default) { [weak alert, weak self] _ in
            complete(alert?.textFields?.first?.text); self?.dismissActivePanel = nil
        }
        alert.addAction(accept)
        alert.preferredAction = accept
        presentPanel(alert, on: presenter, cancel: { complete(nil) })
    }

    /// 알림창을 띄울 화면. 설정 시트 등이 이미 떠 있으면 그 위에 얹어야 한다 —
    /// 루트에 바로 present하면 "이미 다른 화면을 띄우고 있다"로 무시된다.
    private func presenter(for webView: WKWebView) -> UIViewController? {
        var controller = webView.window?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }
}

extension BrowserCoordinator: WKScriptMessageHandler {
    /// popup-guard.js의 slateAdIntent 신호, sticky-detour.js의 고정 탭 새 탭 열기 요청,
    /// auto-translate.js의 번역 요청.
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        switch message.name {
        case "slateStickyOpen":
            if let raw = message.body as? String, let url = URL(string: raw) {
                onOpenInNewTab?(url)
            }
        case "slateTranslate":
            guard let items = message.body as? [[String: Any]], let webView = message.webView else { return }
            let frame = message.frameInfo
            if !frame.isMainFrame, translationFrames.count < 50,
               !translationFrames.contains(where: { $0.request.url == frame.request.url }) {
                translationFrames.append(frame)
            }
            Task { @MainActor in
                let reply = await Self.translateReply(items)
                // 요청이 온 프레임에 돌려준다. 기본 evaluateJavaScript는 메인 프레임에만 닿는다.
                webView.evaluateJavaScript("window.__slateApplyTranslations(\(reply)); 0",
                                           in: frame, in: .page) { _ in }
            }
        default:
            noteAdIntent()
        }
    }

    /// [{id, text, lang}] → 번역해서 [{id, text|null}] JSON. 모든 id에 답을 준다 — 답이 없으면
    /// 스크립트가 그 노드를 영원히 기다린다. 원어별로 묶어 각 세션에 보낸다.
    static func translateReply(_ items: [[String: Any]]) async -> String {
        struct Item { let id: Int; let text: String; let lang: String }
        let parsed = items.compactMap { item -> Item? in
            guard let id = item["id"] as? Int, let text = item["text"] as? String else { return nil }
            return Item(id: id, text: text, lang: item["lang"] as? String ?? "ja")
        }
        var out: [[String: Any]] = []
        let cache = TranslationCache.shared
        for (lang, group) in Dictionary(grouping: parsed, by: \.lang) {
            let source = Translator.source(for: lang, sample: group.map(\.text).joined(separator: "\n"))
            // 원장에 있는 문구는 모델에 안 보낸다.
            let misses = group.filter { cache.lookup($0.text, source: source) == nil }
            TranslationStats.shared.cacheHits += group.count - misses.count
            let translated = await Translator.shared.translate(misses.map(\.text), source: source)
            var fresh: [String: String] = [:]
            for (item, text) in zip(misses, translated) {
                if let text { fresh[item.text] = text }
            }
            cache.store(fresh.map { ($0.key, $0.value) }, source: source)
            for item in group {
                let text = cache.lookup(item.text, source: source) ?? fresh[item.text]
                out.append(["id": item.id, "text": text.map { $0 as Any } ?? NSNull()])
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: out),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }
}
