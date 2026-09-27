import Observation
import UIKit
import WebKit
import os

@MainActor
@Observable
final class Tab: Identifiable {
    private static let logger = Logger(subsystem: "com.wonseon.slate", category: "tab")

    let id: UUID
    let webView: WKWebView
    let coordinator: BrowserCoordinator
    var lastURL: URL?
    var canGoBack = false
    var canGoForward = false
    var progress: Double = 0
    var isLoading = false
    var chromeCollapsed = false
    var thumbnail: UIImage?
    /// 고정 탭. 켜면 링크를 눌러도 이 페이지가 남고 새 탭이 열린다. 쪽 넘김은 제자리.
    /// 페이지 안 가로채기 스크립트가 읽는 플래그를 같이 갱신한다.
    var sticky = false {
        didSet { pushStickyFlag() }
    }

    /// 지금 문서에 고정 여부를 알린다. 문서가 갈릴 때마다 다시 심어야 한다.
    private func pushStickyFlag() {
        webView.evaluateJavaScript("window.__slateSticky = \(sticky)") { _, error in
            if let error {
                Self.logger.error("pushStickyFlag: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    /// 이 탭이 갈라져 나온 고정 탭. 격자에서 그 그룹에 묶인다.
    var stickyParentID: UUID?
    /// 번역 대신 원문을 보인다. 탭 단위이고 문서가 갈리면 꺼진다.
    var showingOriginal = false {
        didSet { pushShowOriginal() }
    }

    /// 원문 보기 상태를 문서에 알린다. 번역을 요청해 온 하위 프레임에도 보낸다.
    private func pushShowOriginal() {
        let js = "window.__slateShowOriginal && window.__slateShowOriginal(\(showingOriginal)); 0"
        webView.evaluateJavaScript(js) { _, _ in }
        for frame in coordinator.translationFrames {
            webView.evaluateJavaScript(js, in: frame, in: .page) { _ in }
        }
    }
    /// 지금 이 탭에 얹힌 광고 차단 방식. TabStore가 이동 직전에 사이트 설정과 맞춘다.
    @ObservationIgnored var appliedBlockingMode: BlockingMode = .full
    /// 절전 상태. 메모리가 모자랄 때 안 보는 탭의 페이지를 내리고 뒤로가기 이력만
    /// pendingInteractionState에 들고 있다. 다시 고르면 TabStore가 되살린다. 절전 중에는
    /// 웹뷰가 빈 페이지를 물고 있으므로 주소·그림을 갱신하지 않는다.
    var hibernated = false
    /// 페이지가 실제로 칠하는 배경색. 상태바 뒤를 이 색으로 메워 콘텐츠와 이어 보이게 한다.
    var pageBackground: UIColor = .systemBackground
    /// 로드 실패 사유. nil이 아니면 화면에 오류를 띄운다.
    var loadError: String?
    /// 실패의 오류 도메인·코드·실패 주소. 오류 화면 아래에 작게 띄운다 — 사유 문장만으로는
    /// 차단기·네트워크·WebKit 중 어디서 난 실패인지 알 수 없다.
    var loadErrorDetail: String?
    /// 막은 이동의 주소. 페이지가 떠 있으면 오류 화면 대신 띠로 알리고 몇 초 뒤 지운다. 빈 탭이면
    /// 오류 화면에 "차단 없이 열기"를 붙이는 근거가 된다.
    var blockedURL: URL?
    /// 막은 이동이 클릭 가로채기였고 누른 링크로 되돌렸다. 띠에 "열기" 대신 그 사실을 적는다.
    var blockedRecovered = false

    /// 막은 이동을 띠로 알린다. 몇 초 뒤 스스로 지운다.
    private func showBlocked(_ url: URL, recovered: Bool) {
        blockedURL = url
        blockedRecovered = recovered
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if self?.blockedURL == url { self?.blockedURL = nil; self?.blockedRecovered = false }
        }
    }
    /// 다음 로드 한 번은 규칙 목록 없이 간다. 커밋되면 TabStore가 규칙을 다시 걸고 끈다.
    @ObservationIgnored var bypassBlockerForNextLoad = false

    /// 로드 없이 주소가 바뀔 때(SPA의 pushState — didCommit이 안 뜬다) 알린다.
    /// 로딩 중의 주소 변화는 didCommit이 맡으므로 여기서는 거른다.
    @ObservationIgnored var onURLChange: (@MainActor (URL) -> Void)?
    /// 페이지 제목이 잡힐 때 알린다. 제목은 로드 완료보다 늦게 온다.
    @ObservationIgnored var onTitleChange: (@MainActor (String, URL) -> Void)?
    /// 페이지 그림을 찍었을 때 알린다. 받는 쪽이 지금 방문에 붙여 디스크에 남긴다.
    @ObservationIgnored var onSnapshot: (@MainActor (UIImage) -> Void)?

    /// 재시작 복원 때 파일에서 읽어 둔 뒤로가기 이력. 화면에 붙어 activate될 때 웹뷰에 넣고
    /// 비운다. 소비 전에 다시 백그라운드로 빠지면 이 값을 그대로 저장한다 — 아직 빈 웹뷰의
    /// 상태로 덮으면 이력이 사라진다.
    @ObservationIgnored var pendingInteractionState: Data?
    /// 실패한 주소. 첫 로드가 실패하면 webView.url도 lastURL도 비어 다시 시도할 대상이
    /// 남지 않는다 — 오류 객체가 들고 있는 주소를 잡아둔다.
    @ObservationIgnored private var failedURL: URL?
    @ObservationIgnored private let ruleStore: SiteRuleStore
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var lastScrollY: CGFloat = 0
    @ObservationIgnored private var scrollAccumulator: CGFloat = 0

    init(id: UUID = UUID(), configuration: WKWebViewConfiguration = WKWebViewConfiguration(),
         ruleStore: SiteRuleStore = .shared) {
        self.id = id
        webView = WKWebView(frame: .zero, configuration: configuration)
        coordinator = BrowserCoordinator()
        self.ruleStore = ruleStore
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.uiDelegate = coordinator
        webView.navigationDelegate = coordinator
        // 손이 닿은 시각을 이동 정책에 알린다 — 스크립트 주도 이동이 사용자 조작에서 난 것인지 가른다.
        webView.addGestureRecognizer(TouchObserver.make { [weak coordinator] in coordinator?.noteUserTouch() })
        webView.configuration.userContentController.add(coordinator, name: "slateAdIntent")
        webView.configuration.userContentController.add(coordinator, name: "slateClickIntent")
        webView.configuration.userContentController.add(coordinator, name: "slateStickyOpen")
        webView.configuration.userContentController.add(coordinator, name: "slateTranslate")
        coordinator.onCommit = { [weak self] url in
            guard let self, !self.hibernated else { return }
            self.lastURL = url
            self.canGoBack = self.webView.canGoBack
            self.canGoForward = self.webView.canGoForward
            self.applyStoredRules()
            self.pushStickyFlag()
            // 새 문서는 번역으로 시작한다.
            if self.showingOriginal { self.showingOriginal = false }
        }
        coordinator.onFinish = { [weak self] webView in
            // didCommit과 atDocumentStart 스크립트 실행의 선후는 WebKit이 보장하지 않는다.
            // 문서 로드 완료 시점에 한 번 더 밀어 넣어 순서 의존을 없앤다 — 중복 호출은 무해하다.
            self?.applyStoredRules()
            self?.pushStickyFlag()
            self?.captureSnapshot()
        }
        coordinator.onLoadEnd = { webView in
            webView.scrollView.refreshControl?.endRefreshing()
        }
        coordinator.shouldDetourToNewTab = { [weak self] url in
            guard let self, self.sticky, let current = self.webView.url else { return false }
            return !URLPart.isPaginationMove(from: current, to: url)
        }
        coordinator.onHijackRecovered = { [weak self] blocked in
            self?.showBlocked(blocked, recovered: true)
        }
        coordinator.onStart = { [weak self] in
            self?.loadError = nil
            self?.loadErrorDetail = nil
            self?.failedURL = nil
        }
        coordinator.onFail = { [weak self] error in
            guard let self else { return }
            let error = error as NSError
            let failed = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL
            // 차단기가 막은 이동인데 뒤에 페이지가 떠 있으면 실패가 아니다 — 페이지는 그대로 두고
            // 띠로만 알린다. WebKit은 실패를 알리기 전에 url을 원래 페이지로 되돌려 둔다.
            // 방금 누른 같은 사이트 링크가 있고 그 링크의 기본 이동을 핸들러가 막았다면 클릭
            // 가로채기다 — 누른 링크로 간다.
            if BrowserCoordinator.isBlockedByContentBlocker(error), let failed, self.webView.url != nil {
                if let intent = self.coordinator.recentClickIntent(within: 3), intent.prevented, intent.url != failed,
                   !BrowserCoordinator.isCrossSite(intent.url, current: self.webView.url) {
                    self.showBlocked(failed, recovered: true)
                    if self.coordinator.shouldDetourToNewTab?(intent.url) == true {
                        self.coordinator.onOpenInNewTab?(intent.url)
                    } else {
                        self.webView.load(URLRequest(url: intent.url))
                    }
                } else {
                    self.showBlocked(failed, recovered: false)
                }
                return
            }
            self.blockedURL = BrowserCoordinator.isBlockedByContentBlocker(error) ? failed : nil
            self.blockedRecovered = false
            self.failedURL = failed
            // 실패한 주소를 주소창에 남긴다 — 커밋이 안 됐으므로 lastURL이 비어 있고,
            // 그대로 두면 주소창이 빈 채라 주소를 고쳐 다시 시도할 수가 없다.
            if let failed { self.lastURL = failed }
            self.loadError = error.localizedDescription
            self.loadErrorDetail = ["\(error.domain) \(error.code)", failed?.absoluteString]
                .compactMap { $0 }.joined(separator: " · ")
        }

        let refreshControl = UIRefreshControl()
        refreshControl.addAction(UIAction { [weak self] _ in
            guard let self, self.webView.url != nil else {
                self?.webView.scrollView.refreshControl?.endRefreshing()
                return
            }
            self.webView.reload()
        }, for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        observations = [
            webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.canGoBack = webView.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.canGoForward = webView.canGoForward }
            },
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in
                    // 로드가 실패하거나 웹 프로세스가 죽으면 url이 nil로 떨어진다. 그대로 받으면
                    // 주소창이 비어 주소를 고쳐 다시 시도할 수가 없다 — nil은 무시한다.
                    guard let self, !self.hibernated, let url = webView.url else { return }
                    self.lastURL = url
                    // 로딩 중이면 일반 로드(제공·리다이렉트 주소 포함)라 didCommit이 처리한다.
                    // 로딩이 아닌데 주소가 바뀌었으면 SPA 이동이다.
                    if !webView.isLoading { self.onURLChange?(url) }
                }
            },
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in
                    guard let title = webView.title, !title.isEmpty, let url = webView.url else { return }
                    self?.onTitleChange?(title, url)
                }
            },
            webView.observe(\.underPageBackgroundColor, options: [.new, .initial]) { [weak self] webView, _ in
                Task { @MainActor in
                    self?.pageBackground = webView.underPageBackgroundColor ?? .systemBackground
                }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.progress = webView.estimatedProgress }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.isLoading = webView.isLoading }
            },
            webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, change in
                // UIScrollView KVO는 항상 메인 스레드에서 온다. 스크롤은 프레임마다 발화하므로
                // Task{} 대기열에 쌓아 순서가 밀리면 lastScrollY 갱신이 어긋나 델타가 틀어진다 —
                // assumeIsolated로 그 자리에서 동기 처리한다.
                guard let self, let newOffset = change.newValue else { return }
                MainActor.assumeIsolated {
                    let delta = newOffset.y - self.lastScrollY
                    self.lastScrollY = newOffset.y
                    // 정지 상태 오프셋은 이제 -contentInset.top이다(safe area 확장으로 페이지가
                    // 인셋만큼 밀려 그려진다) — 0과 비교하면 인셋만큼 어긋난다.
                    if newOffset.y <= -self.webView.scrollView.contentInset.top {
                        self.chromeCollapsed = false
                        self.scrollAccumulator = 0
                        return
                    }
                    // 관성 스크롤은 프레임마다 몇 pt씩 작은 델타로 들어온다 — 매 이벤트 델타를
                    // 임계값과 바로 비교하면 웬만해선 안 넘는다. 같은 방향으로 누적해 판정한다.
                    if delta != 0, self.scrollAccumulator != 0, (delta > 0) != (self.scrollAccumulator > 0) {
                        self.scrollAccumulator = 0
                    }
                    self.scrollAccumulator += delta
                    if self.scrollAccumulator > 24 {
                        self.chromeCollapsed = true
                        self.scrollAccumulator = 0
                    } else if self.scrollAccumulator < -24 {
                        self.chromeCollapsed = false
                        self.scrollAccumulator = 0
                    }
                }
            },
        ]
    }

    /// 찍는 그림의 폭(포인트). 격자 카드 폭이면 충분하다 — 전체 화면 크기로 찍으면 탭마다
    /// 12MB씩 쥔다.
    nonisolated static let snapshotWidth: CGFloat = 200

    /// 지금 보이는 화면을 찍는다. 로드 완료 때 자동으로 부르고, 격자를 열 때도 한 번 더
    /// 부른다 — 스크롤·SPA 이동으로 화면이 달라졌어도 카드가 마지막 모습을 담게.
    func captureSnapshot() {
        guard !hibernated else { return }   // 빈 페이지를 찍어 카드 그림을 덮으면 안 된다
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: Double(Self.snapshotWidth))
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            // 완료 블록은 메인 스레드에서 온다. 여기서 바로 복사해야 한다.
            guard let image, let copy = Self.detached(image) else { return }
            Task { @MainActor in
                self?.thumbnail = copy
                self?.onSnapshot?(copy)
            }
        }
    }

    /// WebKit이 준 그림은 웹 프로세스와 나눠 쓰는 메모리(IOSurface)에 얹혀 있다. 뒤늦게 다른
    /// 스레드에서 읽으면 이미 버려진 메모리를 건드려 죽는다 — 우리 소유의 비트맵으로 바로 복사한다.
    nonisolated static func detached(_ image: UIImage) -> UIImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 실패한 주소를 다시 연다. 잡아둔 주소가 없으면 현재 주소로, 그것도 없으면 새로고침.
    func retryLoad() {
        loadError = nil
        loadErrorDetail = nil
        if let url = failedURL ?? webView.url ?? lastURL {
            webView.load(URLRequest(url: url))
        } else {
            webView.reload()
        }
    }

    /// 화면 좌표(포인트) 사각형을 웹 페이지의 CSS 픽셀 좌표(문서 좌표계)로 바꾼다.
    /// 오버레이는 safe area 밖까지 덮는 화면 전체 좌표계인데 웹뷰는 contentInset.top만큼
    /// 밀려 그려지고 스크롤도 걸린다 — scrollView.contentOffset을 먼저 더해 문서 원점 기준으로
    /// 맞춘 뒤 확대율로 나눈다. scale·offset은 테스트에서만 넘긴다. 평소에는 웹뷰의 현재
    /// 확대율·스크롤 오프셋을 쓴다.
    func cssRect(for rect: CGRect, scale: CGFloat? = nil, offset: CGPoint? = nil) -> CGRect {
        let zoom = scale ?? webView.scrollView.zoomScale
        guard zoom > 0 else { return rect }
        let contentOffset = offset ?? webView.scrollView.contentOffset
        return CGRect(x: (rect.minX + contentOffset.x) / zoom, y: (rect.minY + contentOffset.y) / zoom,
                      width: rect.width / zoom, height: rect.height / zoom)
    }

    /// 지목 영역의 요소를 제거하고 저장할 규칙을 돌려준다.
    func pickArea(_ rect: CGRect) async -> [SiteRule] {
        let area = cssRect(for: rect)
        let js = "JSON.stringify(window.__slatePickArea({x:\(Int(area.minX)),y:\(Int(area.minY)),w:\(Int(area.width)),h:\(Int(area.height))}))"
        let result = try? await webView.evaluateJavaScript(js)
        guard let raw = result as? String,
              let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return []
        }
        let now = Date()
        return parsed.compactMap { entry in
            guard let kind = entry["kind"], let value = entry["value"] else { return nil }
            return SiteRule(kind: kind, value: value, added: now)
        }
    }

    /// 지목으로 나온 규칙을 현재 URL 호스트로 저장소에 넣는다. 빈 배열이면 아무것도 하지 않는다.
    /// applyStoredRules()와 짝 — 이쪽은 쓰기, 저쪽은 읽어서 웹뷰에 미는 쪽.
    func saveRules(_ rules: [SiteRule]) {
        guard !rules.isEmpty, let host = webView.url?.host else { return }
        ruleStore.add(rules, host: host)
    }

    /// 현재 URL 호스트의 저장 규칙을 웹뷰에 밀어 넣는다. 여러 커밋/로드 시점에서 불려도
    /// 결과가 같으므로 중복 호출은 무해하다.
    func applyStoredRules() {
        guard let host = webView.url?.host else { return }
        let rules = ruleStore.enabledRules(for: host)
        guard !rules.isEmpty else { return }
        let payload = rules.map { ["kind": $0.kind, "value": $0.value] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__slateSetRules(" + json + "); 1") { _, error in
            guard let error else { return }
            Self.logger.error("applyStoredRules(): \(error.localizedDescription, privacy: .public)")
        }
    }
}
