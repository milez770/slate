import SwiftUI
import WebKit

struct BrowserView: View {
    let tab: Tab
    let store: TabStore
    /// 활성 탭 카드가 격자에서 놓인 자리(화면 좌표). 페이지가 여기로 줄고 여기서 자란다.
    let cardFrame: CGRect
    @State private var addressText = ""
    @State private var addressFocused = false
    /// 주소 조각 편집이 열려 있다. 주소창 포커스가 풀려도 칩 줄을 유지한다.
    @State private var chipEditing = false
    @State private var showingSettings = false
    @State private var showingShare = false
    @State private var showingTimeline = false
    @State private var progressVisible = false
    @State private var picking = false
    /// 하단 바의 실측 높이(펼침/축소 상태에 따라 바뀐다). obscuredContentInsets 계산에 쓴다.
    @State private var barHeight: CGFloat = 0
    /// 시스템 홈 인디케이터 안전 영역. 웹뷰가 풀블리드라 자체 safe area로는 못 읽으므로
    /// ZStack 컨테이너(바 자신은 자식일 뿐이라 영향 없음)의 geometry에서 읽는다.
    @State private var homeIndicatorInset: CGFloat = 0
    /// 웹뷰가 실제로 차지하는 화면 좌표. 배율·기준점을 여기 기준으로 잡는다 — 상단 안전
    /// 영역 때문에 화면 크기와 다르다.
    @State private var webFrame: CGRect = .zero
    /// 클립보드에 웹 주소로 보이는 내용이 있는지. 주소창 포커스 때 패턴 검사만 하고(내용은
    /// 안 읽는다 — 읽으면 시스템 붙여넣기 알림이 뜬다) 버튼을 누를 때만 실제로 읽는다.
    @State private var clipboardHasLink = false
    /// 페이지 내 찾기 모드. 켜지면 하단 바가 통째로 찾기 줄로 바뀐다.
    @State private var findActive = false
    @State private var findQuery = ""
    @State private var findCount = 0
    @State private var findIndex = 0
    @FocusState private var findFocused: Bool

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                fullBleedLayout
            } else {
                legacyLayout
            }
        }
        .onAppear {
            addressText = hostDisplay(tab.lastURL)
            progressVisible = tab.isLoading
            if tab.webView.url == nil && tab.lastURL == nil {
                addressFocused = true
                detectClipboardLink()
            }
            updateObscuredInsets()
        }
        .onChange(of: tab.id) {
            // 뷰를 재사용하므로 탭이 바뀌면 탭에 매인 상태를 직접 갈아 끼운다.
            addressText = hostDisplay(tab.lastURL)
            addressFocused = false
            picking = false
            progressVisible = tab.isLoading
            findActive = false
            findQuery = ""
            findCount = 0
            updateObscuredInsets()
        }
        .onChange(of: store.showingGrid) { _, showing in
            if showing, findActive { exitFind() }
        }
        .onChange(of: tab.lastURL) {
            if !addressFocused { addressText = hostDisplay(tab.lastURL) }
        }
        .onChange(of: addressFocused) { _, focused in
            if focused {
                detectClipboardLink()
            } else {
                addressText = hostDisplay(tab.lastURL)
            }
        }
        .onChange(of: tab.isLoading) { _, loading in
            if loading {
                progressVisible = true
            } else {
                withAnimation(.easeInOut(duration: 0.3).delay(0.15)) {
                    progressVisible = false
                }
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView(store: store) }
        .sheet(isPresented: $showingTimeline) { TimelineView(store: store) }
        .sheet(isPresented: $showingShare) {
            if let url = tab.lastURL { ShareSheet(activityItems: [url]) }
        }
        .overlay {
            if picking {
                AreaPickerOverlay(
                    onCancel: { picking = false },
                    onConfirm: { rect in
                        picking = false
                        Task {
                            let rules = await tab.pickArea(rect)
                            tab.saveRules(rules)
                        }
                    }
                )
            }
        }
    }

    // MARK: - 레이아웃 (Safari 실측 모델)

    /// iOS 26+: 웹뷰는 풀블리드, 사이트의 position:fixed 하단 요소는 `WKWebView
    /// .obscuredContentInsets`로 지정한 만큼(바 실측 높이 + 홈 인디케이터) 안쪽으로 줄어든
    /// layout viewport 기준 바 상단 바로 위에 앵커된다 — 실물 Safari 스크린샷 실측에서
    /// 사이트 컨트롤 메뉴가 알약 바로 위에 얹히는 것과 동일. 바 자신은 overlay로 웹뷰 위에
    /// 반투명(유리)하게 뜨고, 스크롤 중인 일반 콘텐츠는 그 밑을 그대로 지나간다(바가 스크롤
    /// 콘텐츠를 가리는 부분은 Safari와 같으므로 허용). 홈 인디케이터 띠를 따로 채울 필요 없다
    /// — 콘텐츠가 이미 그 밑까지 그려지고 있고 바가 유리라 자연히 이어져 보인다.
    @available(iOS 26.0, *)
    private var fullBleedLayout: some View {
        ZStack(alignment: .bottom) {
            // 웹뷰가 놓일 자리를 재는 자. 웹뷰 자신에 걸면 축소된 값이 되돌아와 배율이
            // 다시 계산되고, 그 결과 또 줄어드는 되먹임으로 애니메이션이 멎는다.
            webFrameProbe
            // 모든 탭의 웹뷰를 계층에 상시 두고 활성만 보인다. 탭을 바꿀 때 웹뷰를 떼었다
            // 다시 붙이면 그 사이 프레임이 0을 지나며 스크롤 오프셋이 맨 위로 잘린다 —
            // 떼어붙임이 없으면 각 탭의 스크롤 위치가 그대로 남는다.
            allWebViews
                .ignoresSafeArea(edges: .bottom)
                .background(Color(uiColor: tab.pageBackground).ignoresSafeArea(edges: .top))
                .overlay { loadErrorView }
                .overlay(alignment: .bottom) { blockedBanner.animation(.spring(response: 0.3), value: tab.blockedURL) }
                .modifier(pageZoom)
            bottomBar()
                // 바 접힘·주소 포커스의 스프링은 바에만 건다. 뷰 전체에 걸면 탭을 바꿀 때
                // 두 탭의 접힘 상태가 다른 경우 카드 프레임 점프까지 스프링으로 미끄러진다.
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: tab.chromeCollapsed)
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: addressFocused)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newHeight in
                    barHeight = newHeight
                    updateObscuredInsets()
                }
                // 페이지 펼침을 그대로 따라간다 — 접히면 사라지고 펼쳐지며 돌아온다.
                .opacity(store.zoomProgress)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.bottom }) { newInset in
            homeIndicatorInset = newInset
            updateObscuredInsets()
        }
    }

    /// iOS 26 미만 폴백. `obscuredContentInsets`가 없는 OS에서는 웹뷰 자체 safe area로 바
    /// 공간을 예약해(safeAreaInset) 최소한 사이트 하단 요소가 바에 가려지진 않게 한다 — 이
    /// 경로에서는 사이트 요소가 바 아래(=예약된 영역 시작 지점)에 앉지 바 위에 앉진 않는다.
    private var legacyLayout: some View {
        ZStack {
            // 자리는 변환이 걸리지 않는 형제가 잰다. 웹뷰 자신에 재면 축소된 값이 되돌아와
            // 배율이 다시 계산되는 되먹임이 생긴다.
            Color.clear
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { webFrame = $0 }
            allWebViews
                .overlay { loadErrorView }
                .overlay(alignment: .bottom) { blockedBanner.animation(.spring(response: 0.3), value: tab.blockedURL) }
                // 배경색은 마스크 안에 있어야 한다 — 밖에 두면 격자를 열었을 때 접힌 페이지
                // 대신 배경색이 화면 전체를 덮어 격자가 안 보인다.
                .background(Color(uiColor: tab.pageBackground).ignoresSafeArea())
                .modifier(pageZoom)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar()
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: tab.chromeCollapsed)
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: addressFocused)
                .opacity(store.zoomProgress)
        }
    }

    /// 전체 탭의 웹뷰 더미. 활성 탭만 보이고 만질 수 있다. 나머지는 UIKit hidden — 계층에는
    /// 남아 스크롤 위치를 지키되 WebKit에는 안 보이는 페이지로 잡혀 메모리를 놓는다.
    private var allWebViews: some View {
        ZStack {
            ForEach(store.tabs) { t in
                WebView(webView: t.webView, isActive: t === tab)
                    .allowsHitTesting(t === tab)
            }
        }
    }

    /// 웹뷰가 놓일 자리를 재는 자. 웹뷰와 같은 레이아웃 규칙을 받되 변환이 걸리지 않아
    /// 값이 흔들리지 않는다.
    private var webFrameProbe: some View {
        Color.clear
            .ignoresSafeArea(edges: .bottom)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { webFrame = $0 }
            .allowsHitTesting(false)
    }

    /// 접히면 카드 자리·크기로, 펼치면 화면 전체로.
    ///
    /// bottomSlop: 웹뷰는 하단 안전 영역까지 그리지만 마스크·overlay는 그 확장분을 뺀
    /// 경계를 받는다(계측: 컨테이너 778 vs 실제 그림 812). 펼친 상태의 마스크가 그
    /// 확장분을 덮도록 홈 인디케이터 몫을 더한다 — 안 더하면 아래 34pt가 잘려 뒤 배경이
    /// 띠로 드러난다.
    private var pageZoom: CardZoom<some View> {
        CardZoom(progress: store.zoomProgress, webFrame: webFrame, cardFrame: cardFrame,
                 bottomSlop: homeIndicatorInset) {
            cardChrome
        }
    }

    /// 접히는 사각형에 얹는 카드 장식. 탭 버튼을 누른 순간부터 붙어 격자의 카드와 같은
    /// 모양이 되고, 사각형을 따라 자리를 옮긴다. 배율에는 눌리지 않아 글자·아이콘 크기가
    /// 내내 카드의 것과 같다.
    private var cardChrome: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(tab.lastURL?.host ?? "새 탭")
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.55))
            }
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.black.opacity(0.6), in: Circle())
                .padding(.top, 8)
                .padding(.trailing, 8)
        }
    }

    /// 로드 실패 표시. 실패는 대부분 첫 로드에서 나고 그때 화면은 비어 있다 — 배너로
    /// 알리면 눈에 안 들어오므로 가운데를 덮는다. 하단 바보다 아래에 깔려 바는 계속 쓸 수 있다.
    @ViewBuilder
    private var loadErrorView: some View {
        if let message = tab.loadError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text("페이지를 열지 못했다")
                    .font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let detail = tab.loadErrorDetail {
                    Text(detail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
                HStack(spacing: 10) {
                    Button { tab.retryLoad() } label: {
                        Text("다시 시도")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(brandGreen, in: Capsule())
                    }
                    .accessibilityIdentifier("retryLoadButton")
                    // 차단기가 막은 첫 로드. 정말 가려던 페이지면 이 한 번은 규칙 없이 연다.
                    if let blocked = tab.blockedURL, tab.blockedKind == .contentRule {
                        Button { store.loadBypassingBlocker(blocked, in: tab) } label: {
                            Text("차단 없이 열기")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                .background(Color(.systemGray5), in: Capsule())
                        }
                        .accessibilityIdentifier("bypassBlockerButton")
                    }
                }
                .padding(.top, 4)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
        }
    }

    /// 차단기가 막은 이동을 알리는 띠. 페이지는 그대로 있으므로 덮지 않고 바 위에 잠깐 뜬다.
    /// 정말 가려던 주소면 "열기"로 이 한 번만 규칙 없이 간다.
    @ViewBuilder
    private var blockedBanner: some View {
        if let blocked = tab.blockedURL, tab.loadError == nil {
            HStack(spacing: 10) {
                Image(systemName: "shield.slash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(blockedBannerText(blocked))
                    .font(.footnote)
                    .lineLimit(1)
                switch tab.blockedKind {
                case .contentRule:
                    Button("열기") { store.loadBypassingBlocker(blocked, in: tab) }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.borderless)
                case .scriptJump:
                    Button("열기") { store.openBlockedTarget(blocked, in: tab) }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.borderless)
                case .recovered:
                    EmptyView()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .barSurface(Capsule())
            .padding(.bottom, barHeight + homeIndicatorInset + 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityIdentifier("blockedBanner")
        }
    }

    private func blockedBannerText(_ blocked: URL) -> String {
        let host = blocked.host ?? blocked.absoluteString
        switch tab.blockedKind {
        case .contentRule: return "막은 이동 · \(host)"
        case .scriptJump: return "딴 사이트로 보내는 이동을 막았다 · \(host)"
        case .recovered: return "광고 이동을 막고 누른 링크로 갑니다 · \(host)"
        }
    }

    /// 바 실측 높이 + 홈 인디케이터를 더해 obscuredContentInsets.bottom에 반영한다.
    /// 두 값 중 하나가 바뀔 때마다(펼침/축소 전환 포함) 호출된다.
    private func updateObscuredInsets() {
        guard #available(iOS 26.0, *) else { return }
        let bottom = barHeight + homeIndicatorInset
        var insets = tab.webView.obscuredContentInsets
        insets.bottom = bottom
        tab.webView.obscuredContentInsets = insets
        // obscuredContentInsets는 position:fixed 요소만 바 위로 앵커할 뿐 스크롤 콘텐츠의
        // 스크롤 범위는 늘리지 않는다 — 문서가 스크롤되는 페이지는 콘텐츠 끝이 바 높이만큼
        // 바 뒤에 묻힌다. scrollView.contentInset.bottom으로 스크롤 여유를 줘 콘텐츠 끝이 바
        // 위로 올라오게 한다.
        let scrollView = tab.webView.scrollView
        if scrollView.contentInset.bottom != bottom {
            scrollView.contentInset.bottom = bottom
            scrollView.verticalScrollIndicatorInsets.bottom = bottom
        }
    }

    // MARK: - 하단 바

    /// 하단 바 요소의 공통 높이. 원형 버튼과 주소 캡슐이 같은 높이로 맞물린다.
    private let barButtonSize: CGFloat = 44
    /// 하단 바 아이콘 크기. 새로고침도 좌우 버튼과 같은 크기를 쓴다.
    private let barIconSize: CGFloat = 17
    /// 앱 아이콘 배경색 #29FF6C. 진행 표시줄에만 쓴다.
    private let brandGreen = Color.keyGreen

    /// 사파리와 같은 구성. 통짜 판 대신 뒤로·주소·더보기 세 덩어리가 각각 떠 있고
    /// 그 사이로 웹 콘텐츠가 비친다.
    @ViewBuilder
    private func bottomBar() -> some View {
        if findActive {
            findBar
        } else if tab.chromeCollapsed {
            collapsedBar
                .transition(.scale(scale: 0.92).combined(with: .opacity))
        } else {
            VStack(spacing: 8) {
                if addressFocused || chipEditing, let url = tab.lastURL {
                    URLChipBar(url: url, isEditingPart: $chipEditing) { newURL in
                        addressFocused = false
                        tab.webView.load(URLRequest(url: newURL))
                    }
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                if addressFocused && clipboardHasLink {
                    Button { openClipboardLink() } label: {
                        Label("복사한 링크 열기", systemImage: "link")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(PressableStyle())
                    .barSurface(Capsule())
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                    .accessibilityIdentifier("clipboardLinkButton")
                }
                addressRow
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
        }
    }

    private var addressRow: some View {
            HStack(spacing: 6) {
                if !addressFocused {
                    circleButton("chevron.left", identifier: "backButton", disabled: !tab.canGoBack) {
                        tab.webView.goBack()
                    }
                    .contextMenu { backMenuItems }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    circleButton("chevron.right", identifier: "forwardButton", disabled: !tab.canGoForward) {
                        tab.webView.goForward()
                    }
                    .contextMenu { forwardMenuItems }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                addressCapsule
                if addressFocused {
                    circleButton("xmark", identifier: "cancelButton") { addressFocused = false }
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    tabGridButton
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    moreButton
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
    }

    // MARK: - 페이지 내 찾기

    /// 하단 바를 통째로 대신하는 찾기 줄. 검색어·몇 번째/전체·위아래 이동·닫기.
    private var findBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("페이지에서 찾기", text: $findQuery)
                    .focused($findFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit { if findCount > 0 { goToMatch(findIndex + 1) } }
                    .frame(height: barButtonSize)
                if !findQuery.isEmpty {
                    Text(findCount > 0 ? "\(findIndex + 1)/\(findCount)" : "0")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .barSurface(Capsule())
            circleButton("chevron.up", identifier: "findPrevButton", disabled: findCount == 0) {
                goToMatch(findIndex - 1)
            }
            circleButton("chevron.down", identifier: "findNextButton", disabled: findCount == 0) {
                goToMatch(findIndex + 1)
            }
            circleButton("xmark", identifier: "findDoneButton") { exitFind() }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .task(id: findQuery) {
            // 타자 멈춤을 0.25초 기다렸다 검색한다 — 글자마다 전체 페이지를 훑지 않게.
            try? await Task.sleep(for: .milliseconds(250))
            await runFind()
        }
    }

    func enterFind() {
        findActive = true
        findQuery = ""
        findCount = 0
        findIndex = 0
        findFocused = true
    }

    private func exitFind() {
        findActive = false
        findFocused = false
        findQuery = ""
        findCount = 0
        tab.webView.evaluateJavaScript("window.__slateFindClear && window.__slateFindClear(); 0",
                                       completionHandler: nil)
    }

    private func runFind() async {
        guard findActive else { return }
        guard !findQuery.isEmpty else {
            findCount = 0
            tab.webView.evaluateJavaScript("window.__slateFindClear && window.__slateFindClear(); 0",
                                           completionHandler: nil)
            return
        }
        guard let data = try? JSONEncoder().encode([findQuery]),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "window.__slateFind ? window.__slateFind(\(json)[0]) : 0"
        let result = try? await tab.webView.evaluateJavaScript(js)
        findCount = (result as? Int) ?? 0
        findIndex = 0
        if findCount > 0 { goToMatch(0) }
    }

    private func goToMatch(_ index: Int) {
        tab.webView.evaluateJavaScript("window.__slateFindGoto ? window.__slateFindGoto(\(index)) : -1") { value, _ in
            if let normalized = value as? Int, normalized >= 0 {
                findIndex = normalized
            }
        }
    }

    /// 클립보드 패턴 검사. 내용을 읽지 않아 시스템 붙여넣기 알림이 뜨지 않는다.
    private func detectClipboardLink() {
        UIPasteboard.general.detectPatterns(for: [\.probableWebURL]) { result in
            let found = (try? result.get())?.contains(\.probableWebURL) ?? false
            Task { @MainActor in clipboardHasLink = found }
        }
    }

    /// 버튼을 눌렀을 때만 클립보드를 실제로 읽는다 — 이때 시스템 알림이 한 번 뜬다.
    private func openClipboardLink() {
        let pasteboard = UIPasteboard.general
        guard let url = pasteboard.url ?? pasteboard.string.map(AddressResolver.url(from:)) else { return }
        tab.webView.load(URLRequest(url: url))
        addressFocused = false
    }

    /// 주소창·접힌 바에 붙는 상태 표시. 고정, 광고 차단 방식 변경, 원문 보기 순.
    private var statusBadges: [String] {
        var badges: [String] = []
        if tab.sticky { badges.append("pin.fill") }
        if store.blockingModes.mode(for: tab.lastURL) != .full { badges.append("shield.slash.fill") }
        if tab.showingOriginal { badges.append("character.book.closed.fill") }
        return badges
    }

    private func badge(_ symbol: String, size: CGFloat, box: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: box, height: box)
            .background(Color.keyGreen, in: Circle())
    }

    private var collapsedBar: some View {
        HStack(spacing: 5) {
            ForEach(statusBadges, id: \.self) { badge($0, size: 8, box: 15) }
            Text(hostDisplay(tab.lastURL))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .barSurface(Capsule())
            .contentShape(Capsule())
            .onTapGesture { tab.chromeCollapsed = false }
            .accessibilityIdentifier("collapsedBar")
            .padding(.bottom, 6)
    }

    /// 주소 캡슐 안을 진행률만큼 왼쪽부터 채우는 로딩 표시. 별도 줄 대신 캡슐 자체가 게이지다.
    private var progressFill: some View {
        GeometryReader { geo in
            Capsule()
                .fill(brandGreen.opacity(0.3))
                .frame(width: max(geo.size.width * tab.progress, 0))
                .animation(.linear(duration: 0.2), value: tab.progress)
        }
        .clipShape(Capsule())
        .opacity(progressVisible ? 1 : 0)
        .allowsHitTesting(false)
    }

    private var addressCapsule: some View {
        HStack(spacing: 0) {
            // 오른쪽 새로고침 버튼이 차지하는 만큼 왼쪽에도 여백을 둬 주소가 가운데 오게 한다.
            // 상태 표시가 있으면 그 여백 자리에 아이콘이 선다.
            HStack(spacing: 3) {
                if !addressFocused {
                    ForEach(statusBadges, id: \.self) { badge($0, size: 9, box: 18) }
                }
            }
            .frame(minWidth: 16)
            .frame(height: barButtonSize)
            .padding(.leading, !statusBadges.isEmpty && !addressFocused ? 10 : 0)
            AddressField(
                text: $addressText,
                isFocused: $addressFocused,
                editingValue: { tab.lastURL?.absoluteString ?? "" },
                onSubmit: { text in
                    let url = AddressResolver.url(from: text)
                    tab.webView.load(URLRequest(url: url))
                }
            )
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: barButtonSize)
            Button {
                if tab.isLoading {
                    tab.webView.stopLoading()
                } else if tab.lastURL != nil {
                    tab.webView.reload()
                }
            } label: {
                Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: barIconSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 32, height: barButtonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .padding(.trailing, 6)
            .accessibilityIdentifier("reloadStopButton")
        }
        .frame(maxWidth: .infinity)
        .background { progressFill }
        .barSurface(Capsule())
        .contentShape(Capsule())
        .onTapGesture { addressFocused = true }
    }

    /// 자주 쓰지 않는 조작은 여기 모은다.
    private var moreButton: some View {
        Menu {
            Button {
                showingShare = true
            } label: {
                Label("공유", systemImage: "square.and.arrow.up")
            }
            .disabled(tab.lastURL == nil)
            Toggle(isOn: Binding(get: { tab.sticky }, set: { tab.sticky = $0; store.saveState() })) {
                Label("이 탭 고정", systemImage: "pin")
            }
            Picker(selection: Binding(get: { store.blockingModes.mode(for: tab.lastURL) },
                                      set: { store.setBlockingMode($0, for: tab) })) {
                ForEach(BlockingMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            } label: {
                Label("이 사이트 광고 차단", systemImage: "shield")
            }
            .disabled(tab.lastURL == nil)
            if store.autoTranslateEnabled {
                Toggle(isOn: Binding(get: { tab.showingOriginal }, set: { tab.showingOriginal = $0 })) {
                    Label("원문 보기", systemImage: "character.book.closed")
                }
                .disabled(tab.lastURL == nil)
            }
            Button {
                enterFind()
            } label: {
                Label("페이지에서 찾기", systemImage: "magnifyingglass")
            }
            .disabled(tab.lastURL == nil)
            Button {
                picking = true
            } label: {
                Label("광고 제거", systemImage: "eye.slash")
            }
            .disabled(tab.lastURL == nil)
            Divider()
            Button {
                showingTimeline = true
            } label: {
                Label("방문 기록", systemImage: "clock")
            }
            Button {
                showingSettings = true
            } label: {
                Label("설정", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: barIconSize, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: barButtonSize, height: barButtonSize)
                .barSurface(Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityIdentifier("moreButton")
    }

    /// 누르는 동안 살짝 줄어드는 반응. 모든 하단 바 버튼이 같은 반응을 쓴다.
    private struct PressableStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
        }
    }

    /// 탭 격자 버튼. 테두리 사각형 안에 열린 탭 수가 들어간다.
    private var tabGridButton: some View {
        Button { store.openGrid() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(.primary, lineWidth: 1.8)
                    .frame(width: 19, height: 19)
                Text("\(min(store.tabs.count, 99))")
                    .font(.system(size: store.tabs.count > 9 ? 8.5 : 10.5, weight: .bold))
                    .foregroundStyle(.primary)
            }
            .frame(width: barButtonSize, height: barButtonSize)
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityIdentifier("tabGridButton")
        .barSurface(Circle())
    }

    private func circleButton(_ systemImage: String, identifier: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        // 배경은 버튼 바깥에 둔다. 안에 두면 비활성일 때 재질까지 함께 흐려진다.
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: barIconSize, weight: .semibold))
                .foregroundStyle(disabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .frame(width: barButtonSize, height: barButtonSize)
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .disabled(disabled)
        .accessibilityIdentifier(identifier)
        .barSurface(Circle())
    }

    // MARK: - 뒤/앞으로 히스토리 메뉴 (A2)

    @ViewBuilder
    private var backMenuItems: some View {
        ForEach(Array(tab.webView.backForwardList.backList.reversed().enumerated()), id: \.offset) { _, item in
            Button(menuTitle(for: item)) { tab.webView.go(to: item) }
        }
    }

    @ViewBuilder
    private var forwardMenuItems: some View {
        ForEach(Array(tab.webView.backForwardList.forwardList.enumerated()), id: \.offset) { _, item in
            Button(menuTitle(for: item)) { tab.webView.go(to: item) }
        }
    }

    private func menuTitle(for item: WKBackForwardListItem) -> String {
        if let title = item.title, !title.isEmpty { return title }
        return item.url.host ?? item.url.absoluteString
    }

    // MARK: - 표시용 host (B2)

    private func hostDisplay(_ url: URL?) -> String {
        guard let host = url?.host else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// 페이지를 카드 자리·크기로 접는다. 바깥 틀은 마스크가 카드 모양으로 좁히고, 안의 내용은
/// 균등 배율로 줄어든다 — 두 축을 따로 눌러 크기를 맞추면 내용이 세로로 찌그러진다. 넘치는
/// 아래쪽은 마스크가 자르는데, 카드 썸네일이 만들어지는 방식(위쪽을 채우고 나머지 잘라냄)과
/// 같아서 접힌 그림이 카드와 일치한다.
///
/// 마스크도 배율도 레이아웃을 바꾸지 않으므로 웹뷰 프레임은 내내 그대로다 — 페이지가 좁은
/// 폭으로 다시 흐르지 않는다.
///
/// 보간은 SwiftUI 기본 요소(scaleEffect·frame·offset·opacity)에 맡긴다. 모든 값이
/// progress의 1차식이라 같은 트랜잭션 안에서 매 틱 정확히 맞물린다. 뷰의 삽입·제거를
/// 애니메이션 중간값에 거는 구조가 없어 얼어붙거나 어긋난 잔상이 생길 자리가 없다.
private struct CardZoom<Chrome: View>: ViewModifier {
    let progress: Double
    let webFrame: CGRect
    let cardFrame: CGRect
    /// 펼친 상태에서 마스크를 아래로 더 내릴 양. 웹뷰의 하단 안전 영역 확장분(마스크
    /// 컨테이너에는 안 잡히는)을 덮는다.
    let bottomSlop: CGFloat
    /// 접히는 사각형에 얹는 카드 장식(호스트 라벨·닫기 표시). 배율에 눌리지 않고 사각형만
    /// 따라가며, 펼칠수록 옅어져 다 펼치면 없다.
    @ViewBuilder let chrome: () -> Chrome

    /// 접힌 상태의 균등 배율. 카드 폭에 맞춘다.
    private var foldedScale: CGFloat {
        guard webFrame.width > 0, cardFrame.width > 0 else { return 1 }
        return min(cardFrame.width / webFrame.width, 1)
    }

    /// 배율의 기준점. 변환 후에도 제자리에 남는 점이므로 "앞쪽 여백 ÷ 줄어드는 총량"이다.
    private var anchor: UnitPoint {
        let shrinkX = webFrame.width * (1 - foldedScale)
        let shrinkY = webFrame.height * (1 - foldedScale)
        guard shrinkX > 0, shrinkY > 0 else { return .topLeading }
        return UnitPoint(x: (cardFrame.minX - webFrame.minX) / shrinkX,
                         y: (cardFrame.minY - webFrame.minY) / shrinkY)
    }

    func body(content: Content) -> some View {
        let scale = foldedScale + (1 - foldedScale) * progress
        let x = (cardFrame.minX - webFrame.minX) * (1 - progress)
        let y = (cardFrame.minY - webFrame.minY) * (1 - progress)
        let width = cardFrame.width + (webFrame.width - cardFrame.width) * progress
        let height = cardFrame.height + (webFrame.height + bottomSlop - cardFrame.height) * progress
        return content
            // 접힐수록 뭉갠다. 격자에서 활성 탭 자리는 카드가 아니라 접힌 실물이 보이므로,
            // 카드 썸네일과 같은 정도로 맞춘다(축소 전 반경 9 ≈ 축소 후 4). 펼치면 0이라
            // 평소 브라우징에는 비용이 없다.
            .blur(radius: (1 - progress) * 9)
            .scaleEffect(scale, anchor: anchor)
            .mask(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12 * (1 - progress))
                    .frame(width: max(width, 0), height: max(height, 0))
                    .offset(x: x, y: y)
            }
            .overlay(alignment: .topLeading) {
                chrome()
                    .frame(width: max(width, 0), height: max(height, 0))
                    .clipShape(RoundedRectangle(cornerRadius: 12 * (1 - progress)))
                    .offset(x: x, y: y)
                    .opacity(1 - progress)
                    .allowsHitTesting(false)
            }
    }
}

extension Color {
    /// 앱 아이콘 배경색 #29FF6C. 고정 표시와 로딩 게이지가 쓴다.
    static let keyGreen = Color(red: 41 / 255, green: 255 / 255, blue: 108 / 255)
}

extension View {
    /// iOS 26의 유리 재질. 시스템 메뉴가 쓰는 것과 같다.
    @ViewBuilder
    func barSurface<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            // 구 iOS에는 유리 재질이 없어 배경과 바가 같은 색으로 붙어 보인다 — 테두리와
            // 그림자로 면을 가른다.
            self.background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
        }
    }
}
