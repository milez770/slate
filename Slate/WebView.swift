import SwiftUI
import WebKit

struct WebView: UIViewRepresentable {
    let webView: WKWebView
    /// 지금 보는 탭인가. 아닌 탭의 웹뷰는 hidden으로 둔다 — 투명도 0으로만 감추면 WebKit은
    /// 여전히 보이는 페이지로 취급해 탭마다 렌더링을 돌리고 계층 메모리를 쥔다. hidden이면
    /// 웹 프로세스가 배경으로 내려가고, 스크롤 위치는 뷰가 계층에 남아 있어 그대로다.
    let isActive: Bool

    func makeUIView(context: Context) -> WKWebView {
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isHidden = !isActive
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if uiView.isHidden == isActive { uiView.isHidden = !isActive }
    }
}
