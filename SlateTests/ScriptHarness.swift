import WebKit
import XCTest

/// 테스트용: 지정한 스크립트를 얹은 WKWebView에 HTML을 띄우고 자바스크립트를 실행한다.
@MainActor
final class ScriptHarness: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    /// 창에 붙여 document.hidden을 거짓으로 만든다 — 숨김 문서에서 멈추는 스크립트를 시험하려면 보여야 한다.
    private let window: UIWindow
    private var continuation: CheckedContinuation<Void, Never>?

    init(scripts: [String]) {
        let configuration = WKWebViewConfiguration()
        for source in scripts {
            configuration.userContentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            )
        }
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        window = UIWindow(frame: webView.frame)
        window.addSubview(webView)
        window.isHidden = false
        super.init()
        webView.navigationDelegate = self
    }

    /// host를 넘기면 그 호스트의 페이지로 뜬다. 외부 링크 판정 테스트에 필요하다.
    func load(_ html: String, host: String = "site7.com") async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "https://" + host + "/")!)
        }
    }

    func eval(_ js: String) async throws -> Any? {
        try await webView.evaluateJavaScript(js)
    }

    func count(_ selector: String) async throws -> Int {
        let value = try await eval("document.querySelectorAll(" + jsString(selector) + ").length")
        return (value as? Int) ?? Int((value as? NSNumber)?.intValue ?? -1)
    }

    /// 자바스크립트 문자열 리터럴로 감싼다.
    func jsString(_ raw: String) -> String {
        let escaped = raw.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume()
        continuation = nil
    }
}
