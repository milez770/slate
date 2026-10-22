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
    /// 클릭을 가로채 광고로 보내는 이동을 끊고 누른 링크로 되돌렸다. 인자는 끊은 광고 주소.
    var onHijackRecovered: (@MainActor (URL) -> Void)?
    /// 스크립트가 딴 사이트로 보내는 이동을 끊었다. 페이지는 그대로다. 인자는 끊은 주소.
    var onScriptJumpBlocked: (@MainActor (URL) -> Void)?

    /// 사용자가 마지막으로 누른 앵커. popup-guard.js가 클릭 처리가 끝난 뒤 보낸다.
    struct ClickIntent {
        let url: URL
        /// 페이지 핸들러가 그 앵커의 기본 이동을 막았나. 막았으면 링크 대신 딴 데로 보내려는 것이다.
        let prevented: Bool
        let time: Date
    }

    private var lastClickIntent: ClickIntent?

    func noteClickIntent(_ url: URL, prevented: Bool) {
        lastClickIntent = ClickIntent(url: url, prevented: prevented, time: Date())
    }

    func recentClickIntent(within seconds: TimeInterval = gestureWindow) -> ClickIntent? {
        guard let intent = lastClickIntent, Date().timeIntervalSince(intent.time) < seconds else { return nil }
        return intent
    }

    /// 클릭 가로채기인가 — 사용자가 같은 사이트 앵커를 눌렀는데 핸들러가 기본 이동을 막고 스크립트로
    /// 딴 사이트(광고)로 보내는 이동. 앵커가 가리키던 주소로 되돌린다.
    nonisolated static func shouldRecoverHijack(type: WKNavigationType, target: URL, current: URL?,
                                                intent: ClickIntent?) -> Bool {
        guard type == .other, let intent, intent.prevented, intent.url != target,
              isCrossSite(target, current: current), !isCrossSite(intent.url, current: current) else { return false }
        return true
    }

    /// 번역을 요청해 온 하위 프레임. 원문 보기 토글을 이 프레임들에도 보낸다. 문서가 갈리면 비운다.
    private(set) var translationFrames: [WKFrameInfo] = []
    /// 메인 문서가 갈릴 때마다 오른다. 번역 요청이 그 문서가 떠 있는 동안 온 것인지 가린다.
    private var documentEpoch = 0

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

    /// 손이 닿은 뒤 이 시간 안의 이동을 "사용자가 일으킨 것"으로 본다. 클릭 의도의 유효 시간도 같다.
    nonisolated static let gestureWindow: TimeInterval = 2

    nonisolated static func withinGesture(_ age: TimeInterval?) -> Bool {
        (age ?? .infinity) < gestureWindow
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
        default: return withinGesture(touchAge)
        }
    }

    /// 고정 탭이 새 탭으로 돌릴 이동인가 — 누른 링크, 또는 화면을 만진 뒤 2초 안의 같은 사이트
    /// 스크립트 이동. 카드가 `<a>`가 아니라 클릭 핸들러로 location을 바꾸는 사이트도 여기서 잡힌다.
    /// 딴 사이트로 가는 스크립트 이동은 광고이므로 새 탭으로 돌리지 않는다(isScriptJump가 끊는다).
    /// 폼 전송·뒤로가기·새로고침·손 안 댄 리다이렉트는 제자리에서 간다.
    nonisolated static func shouldDetour(type: WKNavigationType, target: URL, current: URL?,
                                         touchAge: TimeInterval?) -> Bool {
        switch type {
        case .linkActivated: return true
        case .other: return withinGesture(touchAge) && !isCrossSite(target, current: current)
        default: return false
        }
    }

    /// 스크립트가 사용자를 딴 사이트로 보내는 이동인가 — 화면을 만진 뒤 2초 안에 스크립트가 시작한
    /// 딴 사이트 이동인데, 누른 앵커가 그 사이트를 가리키고 있지 않을 때. 광고 착륙 페이지로 넘기는
    /// 수법이 대부분이라 페이지를 벗어나지 않게 끊는다. 손 안 댄 리다이렉트(로그인 흐름 등)는 통과.
    nonisolated static func isScriptJump(type: WKNavigationType, target: URL, current: URL?,
                                         touchAge: TimeInterval?, intent: ClickIntent?) -> Bool {
        guard type == .other, withinGesture(touchAge), isCrossSite(target, current: current) else { return false }
        if let intent, !isCrossSite(target, current: intent.url) { return false }   // 누른 링크가 그 사이트로 가는 것
        return true
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

    /// 메인 프레임 이동 하나에 내리는 결정. 위에서부터 먼저 맞는 것이 이긴다.
    enum NavigationDecision: Equatable {
        /// 그대로 간다.
        case allow
        /// 광고 신호 직후의 딴 사이트 이동. 조용히 버린다.
        case drop
        /// 클릭 가로채기. 이 이동을 끊고 누른 링크로 간다.
        case recover(URL)
        /// 스크립트가 딴 사이트로 보내는 이동. 끊고 띠로 알린다.
        case blockScriptJump
        /// 고정 탭에서 다른 페이지로 가는 이동. 새 탭으로 돌린다.
        case detour
    }

    nonisolated static func decide(type: WKNavigationType, target: URL, current: URL?,
                                   touchAge: TimeInterval?, adIntentAge: TimeInterval?, intent: ClickIntent?,
                                   detours: (URL) -> Bool) -> NavigationDecision {
        if shouldBlockNavigation(type: type, target: target, current: current, adIntentAge: adIntentAge) { return .drop }
        if let intent, shouldRecoverHijack(type: type, target: target, current: current, intent: intent) {
            return .recover(intent.url)
        }
        if isScriptJump(type: type, target: target, current: current, touchAge: touchAge, intent: intent) {
            return .blockScriptJump
        }
        if shouldDetour(type: type, target: target, current: current, touchAge: touchAge), detours(target) { return .detour }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        // 웹뷰가 못 보여주는 스킴은 웹뷰에 태우지 않는다 — 태우면 "URL을 표시할 수 없다"
        // 오류로 끝난다. 사용자가 시작한 이동이면 다른 앱에서 열지 묻는다.
        if !Self.isWebScheme(url) {
            decisionHandler(.cancel)
            if Self.isUserInitiated(type: navigationAction.navigationType, touchAge: touchAge) {
                confirmOpenExternalApp(url, from: webView)
            }
            return
        }
        guard navigationAction.targetFrame?.isMainFrame == true else { decisionHandler(.allow); return }
        let decision = Self.decide(type: navigationAction.navigationType, target: url, current: webView.url,
                                   touchAge: touchAge, adIntentAge: adIntentAge,
                                   intent: recentClickIntent(within: Self.gestureWindow),
                                   detours: { shouldDetourToNewTab?($0) == true })
        switch decision {
        case .allow:
            onMainFrameNavigation?(url)
            decisionHandler(.allow)
        case .drop:
            decisionHandler(.cancel)
        case .recover(let intended):
            lastClickIntent = nil
            decisionHandler(.cancel)
            onHijackRecovered?(url)
            open(intended, in: webView)
        case .blockScriptJump:
            decisionHandler(.cancel)
            onScriptJumpBlocked?(url)
        case .detour:
            decisionHandler(.cancel)
            onOpenInNewTab?(url)
        }
    }

    /// 주소를 연다. 고정 탭이 새 탭으로 돌릴 이동이면 새 탭에, 아니면 이 웹뷰에.
    func open(_ url: URL, in webView: WKWebView) {
        if shouldDetourToNewTab?(url) == true {
            onOpenInNewTab?(url)
        } else {
            webView.load(URLRequest(url: url))
        }
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

    /// 콘텐츠 차단기가 문서 자체를 막았다(WebKitErrorDomain 104). 광고 착륙 페이지로 넘기는
    /// 이동이 대부분이고, 원래 페이지는 그대로 남아 있다.
    nonisolated static func isBlockedByContentBlocker(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == "WebKitErrorDomain" && error.code == 104
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

    /// 새 창 요청을 현재 탭(또는 고정 탭의 새 탭)에 실을 것인가. 사용자가 직접 누른 링크는 싣는다.
    /// 스크립트가 여는 창은 누른 앵커와 같은 주소일 때만 — 같은 사이트의 광고 중계 페이지를
    /// 아무 클릭에나 여는 수법(popup-guard는 딴 사이트 창만 가짜로 넘긴다)을 버리기 위해서다.
    nonisolated static func shouldHonorNewWindow(type: WKNavigationType, url: URL, intent: ClickIntent?) -> Bool {
        switch type {
        case .linkActivated: return true
        case .other: return intent?.url == url
        default: return false
        }
    }

    // 팝업: 기본 거부. 사용자가 직접 누른 링크만 현재 탭(고정 탭이면 새 탭)에서 연다 — 딴 사이트
    // 창은 popup-guard가 가짜 창으로 막는다. 스크립트가 연 창은 누른 앵커와 같은 주소일 때만 싣고
    // 나머지는 버리며 광고 신호로 친다. 같은 제스처에서 광고 신호가 왔으면 그 링크는 화면을 덮은
    // 낚시 앵커다 — 현재 탭에도 안 싣는다.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        let type = navigationAction.navigationType
        guard Self.shouldHonorNewWindow(type: type, url: url, intent: recentClickIntent(within: Self.gestureWindow)) else {
            if type == .other { noteAdIntent() }
            return nil
        }
        if let age = adIntentAge, age < 1, Self.isCrossSite(url, current: webView.url) { return nil }
        open(url, in: webView)
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
        documentEpoch += 1
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
        case "slateClickIntent":
            if let body = message.body as? [String: Any], let raw = body["href"] as? String, let url = URL(string: raw) {
                noteClickIntent(url, prevented: body["prevented"] as? Bool ?? false)
            }
        case "slateTranslate":
            guard let items = message.body as? [[String: Any]], let webView = message.webView else { return }
            let frame = message.frameInfo
            if !frame.isMainFrame, translationFrames.count < 50,
               !translationFrames.contains(where: { $0.request.url == frame.request.url }) {
                translationFrames.append(frame)
            }
            // 요청한 문서가 떠 있는 동안만 번역하고 답한다. 웹뷰는 약하게 쥔다 — 닫은 탭의 웹뷰를
            // 남은 번역이 붙잡지 않게.
            let epoch = documentEpoch
            let isCurrent: @MainActor () -> Bool = { [weak self, weak webView] in
                webView != nil && self?.documentEpoch == epoch
            }
            Task { @MainActor [weak webView] in
                await Self.translateReply(items, isCurrent: isCurrent) { reply in
                    guard isCurrent() else { return }
                    // 요청이 온 프레임에 돌려준다. 기본 evaluateJavaScript는 메인 프레임에만 닿는다.
                    webView?.evaluateJavaScript("window.__slateApplyTranslations(\(reply)); 0",
                                                in: frame, in: .page) { _ in }
                }
            }
        case "slateAdIntent":
            noteAdIntent()
        default:
            break
        }
    }

    /// [{id, text, lang}]을 번역해 [{id, text|null}] JSON으로 send에 넘긴다. 원장에 있는 문구는 바로
    /// 보내고, 나머지는 원어별로 번역이 끝나는 대로 보낸다. 모든 id에 답을 준다 — 답이 없으면
    /// 스크립트가 그 노드를 영원히 기다린다.
    static func translateReply(_ items: [[String: Any]], isCurrent: @escaping @MainActor () -> Bool = { true },
                               translator: Translator? = nil, cache: TranslationCache? = nil,
                               send: (String) -> Void) async {
        let translator = translator ?? .shared
        let cache = cache ?? .shared
        struct Item { let id: Int; let text: String; let lang: String }
        let parsed = items.compactMap { item -> Item? in
            guard let id = item["id"] as? Int, let text = item["text"] as? String else { return nil }
            return Item(id: id, text: text, lang: item["lang"] as? String ?? "ja")
        }
        var hits: [[String: Any]] = []
        var misses: [(source: String, items: [Item])] = []
        for (lang, group) in Dictionary(grouping: parsed, by: \.lang) {
            let source = Translator.source(for: lang, sample: group.map(\.text).joined(separator: "\n"))
            var missed: [Item] = []
            for item in group {
                if let text = cache.lookup(item.text, source: source) {
                    hits.append(["id": item.id, "text": text])
                } else {
                    missed.append(item)
                }
            }
            TranslationStats.shared.cacheHits += group.count - missed.count
            if !missed.isEmpty { misses.append((source, missed)) }
        }
        if !hits.isEmpty { send(json(hits)) }
        for (source, group) in misses {
            // 같은 문구가 여러 노드에 있으면 한 번만 번역한다.
            var seen: Set<String> = []
            let texts = group.map(\.text).filter { seen.insert($0).inserted }
            let translated = await translator.translate(texts, source: source, isCurrent: isCurrent)
            var fresh: [String: String] = [:]
            for (text, result) in zip(texts, translated) {
                if let result { fresh[text] = result }
            }
            cache.store(fresh.map { ($0.key, $0.value) }, source: source)
            send(json(group.map { ["id": $0.id, "text": fresh[$0.text].map { $0 as Any } ?? NSNull()] }))
        }
    }

    private static func json(_ value: [[String: Any]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }
}
