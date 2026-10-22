import Observation
import UIKit
import WebKit
import os

@MainActor
@Observable
final class Tab: Identifiable {
    private static let logger = Logger(subsystem: "com.wonseon.slate", category: "tab")

    let id: UUID
    /// 이 탭의 웹뷰. 내린 탭은 웹뷰를 놓아 liveWebView가 비어 있다 — 웹뷰는 페이지를 불러오지
    /// 않아도 만들어지는 순간 웹 프로세스를 하나 붙잡는다(기기에서 탭 67개일 때 웹 프로세스 69개).
    /// 비어 있을 때 부르면 그 자리에서 새로 만든다.
    var webView: WKWebView {
        if let liveWebView { return liveWebView }
        let created = WKWebView(frame: .zero, configuration: makeConfiguration())
        liveWebView = created
        attach(created)
        onWebViewCreated?(created)
        return created
    }
    private(set) var liveWebView: WKWebView?
    /// 웹뷰를 새로 만든 직후 알린다. TabStore가 규칙 목록·스크립트를 얹는다.
    @ObservationIgnored var onWebViewCreated: (@MainActor (WKWebView) -> Void)?
    @ObservationIgnored private let makeConfiguration: @MainActor () -> WKWebViewConfiguration
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
        liveWebView?.evaluateJavaScript("window.__slateSticky = \(sticky)") { _, error in
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
        guard let webView = liveWebView else { return }
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
    /// 마지막으로 이 탭을 본 시각. TabStore가 살아 있는 페이지 상한을 지킬 때 오래된 순으로 내린다.
    @ObservationIgnored var lastActivatedAt = Date.distantPast
    /// 페이지가 실제로 칠하는 배경색. 상태바 뒤를 이 색으로 메워 콘텐츠와 이어 보이게 한다.
    var pageBackground: UIColor = .systemBackground
    /// 로드 실패 사유. nil이 아니면 화면에 오류를 띄운다.
    var loadError: String?
    /// 실패의 오류 도메인·코드·실패 주소. 오류 화면 아래에 작게 띄운다 — 사유 문장만으로는
    /// 차단기·네트워크·WebKit 중 어디서 난 실패인지 알 수 없다.
    var loadErrorDetail: String?
    /// 막은 이동. 페이지가 떠 있으면 오류 화면 대신 띠로 알리고 몇 초 뒤 지운다. 빈 탭이면 오류
    /// 화면에 "차단 없이 열기"를 붙이는 근거가 된다. 종류에 따라 띠 문구와 "열기"의 동작이 갈린다.
    struct BlockedNavigation: Equatable {
        enum Kind {
            /// 콘텐츠 차단기 규칙이 문서를 막았다. "열기"는 그 한 번 규칙 없이 연다.
            case contentRule
            /// 스크립트가 딴 사이트로 보내는 이동을 끊었다. "열기"는 그 주소로 그냥 간다.
            case scriptJump
            /// 클릭 가로채기를 끊고 누른 링크로 되돌렸다. "열기" 없음.
            case recovered
        }
        let url: URL
        let kind: Kind
    }
    var blocked: BlockedNavigation?

    /// 막은 이동을 띠로 알린다. 몇 초 뒤 스스로 지운다. 막힌 이동의 출발점이 빈 중계 페이지면
    /// 그 전 페이지로 돌아간다.
    func showBlocked(_ url: URL, kind: BlockedNavigation.Kind) {
        let entry = BlockedNavigation(url: url, kind: kind)
        blocked = entry
        if kind != .recovered { retreatIfBlankPage() }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if self?.blocked == entry { self?.blocked = nil }
        }
    }

    /// 글도 그림도 없는 페이지에서 딴 사이트로 넘기려다 막혔다면 그 페이지는 광고 중계용이다 —
    /// 사용자가 보던 이전 페이지로 돌아간다.
    private func retreatIfBlankPage() {
        guard webView.canGoBack else { return }
        let js = """
        (function(){var b=document.body;if(!b)return true;var t=(b.innerText||'').trim();
        return t.length<40&&document.images.length===0&&!document.querySelector('video,iframe,canvas');})()
        """
        webView.evaluateJavaScript(js) { [weak self] value, _ in
            guard (value as? Bool) == true, let self, self.webView.canGoBack else { return }
            self.webView.goBack()
        }
    }
    /// 페이지가 떠 있는 채로 차단기가 이동을 막았다. 방금 누른 같은 사이트 링크가 있고 그 링크의
    /// 기본 이동을 핸들러가 막았다면 클릭 가로채기다 — 누른 링크로 간다. 아니면 띠만 띄운다.
    private func noteBlockedByRules(_ failed: URL) {
        if let intent = coordinator.recentClickIntent(within: 3), intent.prevented, intent.url != failed,
           !BrowserCoordinator.isCrossSite(intent.url, current: webView.url) {
            showBlocked(failed, kind: .recovered)
            coordinator.open(intent.url, in: webView)
        } else {
            showBlocked(failed, kind: .contentRule)
        }
    }

    /// 다음 로드 한 번은 규칙 목록 없이 간다. 커밋되면 TabStore가 규칙을 다시 걸고 끈다.
    @ObservationIgnored var bypassBlockerForNextLoad = false
    /// 안 보는 동안 웹 프로세스가 죽었다. 다시 고를 때 TabStore가 새로고침한다.
    @ObservationIgnored var reloadWhenShown = false
    /// 보는 중에 웹 프로세스가 마지막으로 죽은 시각.
    @ObservationIgnored private var lastTermination: Date?

    /// 웹 프로세스가 죽었을 때 할 일.
    enum TerminationResponse: Equatable {
        /// 다시 고를 때 새로고침한다.
        case reloadWhenShown
        /// 바로 새로고침한다.
        case reload
        /// 새로고침하지 않고 오류 화면으로 알린다.
        case giveUp
    }

    /// 안 보는 탭은 다시 고를 때 띄운다 — 바로 띄우면 메모리가 모자라 죽은 탭들이 한꺼번에 되살아나
    /// 다시 메모리를 다툰다. 보는 탭이 10초 안에 또 죽으면 자동으로 띄우지 않는다 — 죽고 띄우기를
    /// 되풀이하지 않게.
    nonisolated static func terminationResponse(hidden: Bool, now: Date, lastTermination: Date?) -> TerminationResponse {
        if hidden { return .reloadWhenShown }
        if let last = lastTermination, now.timeIntervalSince(last) < 10 { return .giveUp }
        return .reload
    }

    /// 웹 프로세스가 죽었다(대개 메모리 부족).
    func webContentTerminated(now: Date = Date()) {
        #if DEBUG
        MemoryLog.event("웹 프로세스 종료 \(webView.isHidden ? "숨은 탭" : "보는 탭") \(lastURL?.host ?? "")")
        #endif
        switch Self.terminationResponse(hidden: webView.isHidden, now: now, lastTermination: lastTermination) {
        case .reloadWhenShown:
            reloadWhenShown = true
        case .reload:
            lastTermination = now
            webView.reload()
        case .giveUp:
            lastTermination = now
            loadError = "페이지가 메모리를 너무 많이 써서 멈췄다"
            loadErrorDetail = "웹 프로세스가 10초 안에 두 번 종료됨"
        }
    }

    /// 로드 없이 주소가 바뀔 때(SPA의 pushState·replaceState — didCommit이 안 뜬다) 알린다.
    /// 둘째 인자는 뒤로가기 항목이 그대로인가 — replaceState는 항목을 새로 만들지 않고 주소만 고친다.
    /// 로딩 중의 주소 변화는 didCommit이 맡으므로 여기서는 거른다.
    @ObservationIgnored var onURLChange: (@MainActor (URL, Bool) -> Void)?
    /// 마지막으로 본 뒤로가기 항목. 주소가 바뀌었는데 항목이 같으면 replaceState다.
    @ObservationIgnored private weak var lastListItem: WKBackForwardListItem?
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

    /// configuration이 nil이면 웹뷰 없이(내린 채로) 만든다. makeConfiguration은 웹뷰를 나중에 새로
    /// 만들 때 쓴다.
    init(id: UUID = UUID(), configuration: WKWebViewConfiguration? = WKWebViewConfiguration(),
         makeConfiguration: @escaping @MainActor () -> WKWebViewConfiguration = { WKWebViewConfiguration() },
         ruleStore: SiteRuleStore = .shared) {
        self.id = id
        liveWebView = configuration.map { WKWebView(frame: .zero, configuration: $0) }
        self.makeConfiguration = makeConfiguration
        coordinator = BrowserCoordinator()
        self.ruleStore = ruleStore
        coordinator.onCommit = { [weak self] url in
            guard let self, !self.hibernated else { return }
            self.lastURL = url
            self.lastListItem = self.webView.backForwardList.currentItem
            self.canGoBack = self.webView.canGoBack
            self.canGoForward = self.webView.canGoForward
            self.applyStoredRules()
            self.pushStickyFlag()
            // 새 문서는 번역으로 시작한다.
            if self.showingOriginal { self.showingOriginal = false }
        }
        coordinator.onFinish = { [weak self] _ in
            // didCommit과 atDocumentStart 스크립트 실행의 선후는 WebKit이 보장하지 않는다.
            // 문서 로드 완료 시점에 한 번 더 밀어 넣어 순서 의존을 없앤다 — 중복 호출은 무해하다.
            self?.applyStoredRules()
            self?.pushStickyFlag()
            // 웹 프로세스가 첫 화면을 그려 올릴 틈을 준 뒤 찍는다.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                self?.captureSnapshot()
            }
        }
        coordinator.onWebContentTerminated = { [weak self] in
            self?.webContentTerminated()
        }
        coordinator.onLoadEnd = { webView in
            webView.scrollView.refreshControl?.endRefreshing()
        }
        coordinator.shouldDetourToNewTab = { [weak self] url in
            guard let self, self.sticky, let current = self.webView.url else { return false }
            return !URLPart.isPaginationMove(from: current, to: url)
        }
        coordinator.onHijackRecovered = { [weak self] blocked in
            self?.showBlocked(blocked, kind: .recovered)
        }
        coordinator.onScriptJumpBlocked = { [weak self] blocked in
            self?.showBlocked(blocked, kind: .scriptJump)
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
            let blockedByRules = BrowserCoordinator.isBlockedByContentBlocker(error)
            // 차단기가 막은 이동인데 뒤에 페이지가 떠 있으면 실패가 아니다 — 페이지는 그대로 두고
            // 띠로만 알린다. WebKit은 실패를 알리기 전에 url을 원래 페이지로 되돌려 둔다.
            if blockedByRules, let failed, self.webView.url != nil {
                self.noteBlockedByRules(failed)
                return
            }
            self.blocked = blockedByRules ? failed.map { BlockedNavigation(url: $0, kind: .contentRule) } : nil
            self.failedURL = failed
            // 실패한 주소를 주소창에 남긴다 — 커밋이 안 됐으므로 lastURL이 비어 있고,
            // 그대로 두면 주소창이 빈 채라 주소를 고쳐 다시 시도할 수가 없다.
            if let failed { self.lastURL = failed }
            self.loadError = error.localizedDescription
            self.loadErrorDetail = ["\(error.domain) \(error.code)", failed?.absoluteString]
                .compactMap { $0 }.joined(separator: " · ")
        }

        if let liveWebView { attach(liveWebView) }
    }

    /// 웹뷰를 놓는다. 화면 계층에서도 빠지면 웹 프로세스가 같이 내려간다. 다시 부르면 새로 만든다.
    func unloadWebView() {
        guard let old = liveWebView else { return }
        observations = []
        old.stopLoading()
        old.navigationDelegate = nil
        old.uiDelegate = nil
        old.configuration.userContentController.removeAllScriptMessageHandlers()
        liveWebView = nil
        lastListItem = nil
        lastScrollY = 0
        scrollAccumulator = 0
    }

    /// 웹뷰에 위임자·메시지 처리기·새로고침·관찰을 붙인다.
    private func attach(_ webView: WKWebView) {
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
                    guard !webView.isLoading else { return }
                    let item = webView.backForwardList.currentItem
                    let replaced = item != nil && item === self.lastListItem
                    self.lastListItem = item
                    self.onURLChange?(url, replaced)
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
    /// 12MB씩 쥔다. 픽셀은 저장 폭(360px)으로 바로 그린다 — 화면 배율(3배)로 그리면 한 장에
    /// 3MB를 잡았다가 저장할 때 다시 줄인다.
    nonisolated static let snapshotWidth: CGFloat = 200

    /// 지금 보이는 화면을 찍는다. 로드 완료 뒤 잠시 있다 자동으로 부르고, 격자를 열 때도 한 번 더
    /// 부른다 — 스크롤·SPA 이동으로 화면이 달라졌어도 카드가 마지막 모습을 담게.
    func captureSnapshot() {
        guard !hibernated, let image = Self.thumbnail(of: webView) else { return }
        thumbnail = image
        onSnapshot?(image)
    }

    /// 뷰의 지금 모습을 카드 폭으로 우리 비트맵에 그린다. 창에 붙어 보이는 뷰만 그린다.
    /// WebKit의 takeSnapshot은 웹 프로세스와 나눠 쓰는 표면(IOSurface)에 얹힌 그림을 넘기는데,
    /// 완료 블록 안에서 바로 복사해도 그 표면이 이미 비워져 있으면 그리다 죽는다. drawHierarchy는
    /// 렌더 서버가 그 자리에서 우리 컨텍스트에 그려 주므로 남의 메모리를 들고 있는 순간이 없다.
    static func thumbnail(of view: UIView) -> UIImage? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0, view.window != nil, !view.isHidden else { return nil }
        let size = CGSize(width: snapshotWidth, height: (bounds.height * snapshotWidth / bounds.width).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = SnapshotStore.storedWidth / snapshotWidth
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            // 마지막으로 그려진 프레임을 쓴다. 아직 한 번도 안 그려졌으면 지금 그려서 찍는다.
            if !view.drawHierarchy(in: rect, afterScreenUpdates: false) {
                view.drawHierarchy(in: rect, afterScreenUpdates: true)
            }
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
