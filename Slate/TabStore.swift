import Foundation
import Observation
import SwiftUI
import WebKit

@MainActor
@Observable
final class TabStore {
    private static let stateKey = "slate.tab.urls"
    private static let idsKey = "slate.tab.ids"
    private static let activeKey = "slate.tab.active"
    private static let bannerSweepKey = "slate.banner.sweep"
    private static let autoTranslateKey = "slate.translate.auto"
    private static let closedKey = "slate.tab.closed"
    private static let closedIDsKey = "slate.tab.closed.ids"
    private static let stickyIDsKey = "slate.tab.sticky"
    private static let stickyParentsKey = "slate.tab.sticky.parents"
    private static let closedStickyKey = "slate.tab.closed.sticky"
    private static let closedParentsKey = "slate.tab.closed.parents"
    private static let closedLimit = 10
    private let defaults: UserDefaults
    /// 방문 기록 원장. 탭 ID로 타임라인 카드와 살아있는 탭을 잇는다.
    let history: HistoryStore
    var tabs: [Tab] = []
    var activeTab: Tab?
    /// 최근에 닫은 탭. 앱이 살아 있는 동안은 뒤로가기 이력(interactionState)까지 갖고,
    /// 재시작 뒤에는 주소만 남는다. tabID는 방문 기록의 카드와 잇는 열쇠다.
    struct ClosedTab {
        let url: URL
        let state: Data?
        let tabID: UUID
        /// 고정 탭이었나·어느 고정 탭에서 갈라졌었나. 되살릴 때 그룹 자리로 돌아가게 한다.
        var sticky = false
        var stickyParentID: UUID?
    }
    private(set) var closedTabs: [ClosedTab] = []
    var showingGrid = false
    /// 페이지의 펼침 정도. 1이 화면 전체, 0이 격자의 활성 탭 카드 크기. 이 값 하나만
    /// 애니메이션되고, 배율·마스크·카드 장식이 전부 이 값의 1차식이라 같은 트랜잭션의
    /// 기본 보간만으로 매 틱 맞물린다.
    var zoomProgress: Double = 1

    /// 탭 격자를 연다. 격자를 먼저 보이게만 하고(펼쳐진 페이지가 덮고 있어 안 보인다),
    /// 접기는 ContentView가 활성 탭 카드의 자리를 확보한 뒤 beginCollapse()로 시작한다 —
    /// 자리 없이 접으면 원점이나 화면 밖으로 날아간다.
    func openGrid() {
        // 떠 있는 웹페이지 알림창을 취소로 닫는다. 그대로 두면 격자 위에 남는다.
        tabs.forEach { $0.coordinator.dismissPanels() }
        // 지금 보던 화면을 카드에 담는다 — 로드 완료 뒤 스크롤한 만큼은 아직 안 찍혀 있다.
        activeTab?.captureSnapshot()
        showingGrid = true
        pendingCollapse = true
    }

    /// openGrid() 후 접기 대기 상태. 카드 자리가 잡히는 쪽이 소비한다.
    private(set) var pendingCollapse = false

    /// 활성 탭 카드 자리가 잡혔다 — 다음 틱에 접기를 애니메이션한다. 한 번만 발동.
    func beginCollapse() {
        guard pendingCollapse else { return }
        pendingCollapse = false
        Task { @MainActor in
            withAnimation(.tabSwitch) { self.zoomProgress = 0 }
        }
    }

    /// 자리가 끝내 안 잡히면(카드 배치 실패) 애니메이션 없이 접는다.
    func collapseInstantly() {
        guard pendingCollapse, showingGrid else { return }
        pendingCollapse = false
        zoomProgress = 0
    }

    /// 격자에서 카드를 골랐다. 탭 교체(웹뷰·목표 카드 프레임)는 애니메이션 없이 먼저 끝낸다
    /// — 접힌 페이지가 이전 카드 자리에서 고른 카드 자리로 즉시 옮겨 가는데, 두 자리 모두
    /// 밑에 같은 그림의 실제 카드가 있어 점프가 보이지 않는다. 그다음 틱에 펼침만
    /// 애니메이션한다. 한 트랜잭션에 섞으면 마스크 크기 같은 파생값이 두 출처(카드 프레임
    /// 점프 + 진행률 보간)에서 동시에 바뀌어 시작 위치가 이전 카드로 어긋난다.
    func pick(_ tab: Tab) {
        pendingCollapse = false
        activate(tab)
        Task { @MainActor in
            withAnimation(.tabSwitch, completionCriteria: .logicallyComplete) {
                self.zoomProgress = 1
            } completion: {
                // 펼침이 끝날 때까지 격자를 밑에 남긴다 — 확대되는 페이지가 덮는다.
                self.showingGrid = false
            }
        }
    }

    /// 격자에서 새 탭. 새 탭은 자라날 카드가 격자에 없으므로 애니메이션 없이 바로 연다.
    func newTabFromGrid() {
        newTab()
        pendingCollapse = false
        zoomProgress = 1
        showingGrid = false
    }

    /// 사이트별 광고 차단 방식. 탭이 그 사이트로 이동하기 직전에 규칙 목록·스크립트를 방식에 맞춰 갈아 끼운다.
    let blockingModes: BlockingModeStore
    var ruleLists: [WKContentRuleList] = []
    /// 요소 숨김 규칙을 뺀 목록. "감지 회피" 사이트를 처음 만날 때 컴파일한다.
    private(set) var networkRuleLists: [WKContentRuleList]?
    private var networkListsTask: Task<[WKContentRuleList], Never>?

    var bannerSweepEnabled: Bool {
        didSet {
            defaults.set(bannerSweepEnabled, forKey: Self.bannerSweepKey)
            reloadUserScripts()
        }
    }

    /// 일본어 글자를 한국어로 바꾼다. 기본 켜짐.
    var autoTranslateEnabled: Bool {
        didSet {
            defaults.set(autoTranslateEnabled, forKey: Self.autoTranslateKey)
            reloadUserScripts()
        }
    }

    /// 탭별 뒤로가기 이력(interactionState) 파일이 사는 폴더. UserDefaults에 넣기엔 커서
    /// 파일로 둔다. 파일 이름은 탭 ID.
    private let stateDirectory: URL

    init(defaults: UserDefaults = .standard, history: HistoryStore? = nil, stateDirectory: URL? = nil,
         blockingModes: BlockingModeStore? = nil) {
        self.defaults = defaults
        self.history = history ?? .shared
        self.blockingModes = blockingModes ?? .shared
        self.stateDirectory = stateDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TabState", isDirectory: true)
        if defaults.object(forKey: Self.bannerSweepKey) == nil {
            bannerSweepEnabled = true
        } else {
            bannerSweepEnabled = defaults.bool(forKey: Self.bannerSweepKey)
        }
        if defaults.object(forKey: Self.autoTranslateKey) == nil {
            autoTranslateEnabled = true
        } else {
            autoTranslateEnabled = defaults.bool(forKey: Self.autoTranslateKey)
        }
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                #if DEBUG
                MemoryLog.event("메모리 부족 알림")
                #endif
                self?.relieveMemoryPressure()
            }
        }
    }

    deinit {
        if let memoryWarningObserver { NotificationCenter.default.removeObserver(memoryWarningObserver) }
    }

    @ObservationIgnored private var memoryWarningObserver: NSObjectProtocol?

    // MARK: - 메모리

    /// 절전 안 된 탭 수. 설정 화면 표시용.
    var liveTabCount: Int { tabs.filter { !$0.hibernated }.count }

    /// 페이지를 들고 있는 탭의 상한. 보는 탭과 최근에 본 탭 셋만 페이지를 들고 나머지는 절전한다 —
    /// 탭마다 웹 프로세스가 하나씩 붙어 기기 메모리를 나눠 쓰므로, 열어 둔 탭 수만큼 자라게 두면
    /// iOS의 부족 알림이 오기 전에 할당이 실패해 앱이 죽는다.
    static let liveTabLimit = 4

    /// 상한을 넘는 만큼 가장 오래 안 본 탭부터 내린다. 탭을 고르거나 새로 열 때 부른다.
    private func enforceLiveLimit() {
        let others = tabs.filter { $0 !== activeTab && !$0.hibernated && $0.webView.url != nil }
            .sorted { $0.lastActivatedAt > $1.lastActivatedAt }
        for tab in others.dropFirst(Self.liveTabLimit - 1) { hibernate(tab) }
    }

    /// iOS가 메모리 부족을 알렸다. 보는 탭 하나만 남기고 나머지 페이지를 내리고, 들고 있던
    /// 그림도 놓는다. 이걸 안 하면 다음 할당이 실패해 앱이 죽는다.
    func relieveMemoryPressure() {
        for tab in tabs where tab !== activeTab {
            hibernate(tab)
            tab.thumbnail = nil
        }
        SnapshotStore.shared.dropMemoryCache()
    }

    /// 탭의 페이지를 내린다. 웹뷰를 새것으로 바꿔 웹 프로세스까지 놓는다. 뒤로가기 이력은
    /// pendingInteractionState에 남겨 다시 고를 때 그 자리로 돌아온다. 주소창·격자 카드는
    /// lastURL과 디스크 그림을 그대로 쓴다.
    func hibernate(_ tab: Tab) {
        guard !tab.hibernated, tab.webView.url != nil, !tab.webView.isLoading else { return }
        tab.pendingInteractionState = tab.webView.interactionState as? Data
        tab.hibernated = true
        tab.thumbnail = nil
        tab.replaceWebView(configuration: Self.makeConfiguration())
        applyRuleLists(to: tab)
        applyUserScripts(to: tab)
    }

    /// 탭에 얹을 스크립트 목록. 차단 방식이 끄기면 광고를 건드리는 스크립트를 빼고, 나머지 두
    /// 방식은 광고 스크립트 껍데기(ad-stubs)까지 얹는다. 스위치 상태도 반영한다.
    private func userScripts(for mode: BlockingMode) -> [WKUserScript] {
        var scripts = [
            UserScripts.script(named: "popup-guard", injectionTime: .atDocumentStart, forMainFrameOnly: false),
            UserScripts.script(named: "sticky-detour", injectionTime: .atDocumentStart, forMainFrameOnly: true)
        ]
        if mode != .off {
            scripts += [
                UserScripts.script(named: "ad-stubs", injectionTime: .atDocumentStart, forMainFrameOnly: false),
                UserScripts.script(named: "ad-cloak", injectionTime: .atDocumentStart, forMainFrameOnly: false),
                UserScripts.script(named: "rule-applier", injectionTime: .atDocumentStart, forMainFrameOnly: false),
                UserScripts.script(named: "overlay-buster", injectionTime: .atDocumentEnd, forMainFrameOnly: false)
            ]
        }
        scripts += [
            UserScripts.script(named: "area-picker", injectionTime: .atDocumentEnd, forMainFrameOnly: true),
            UserScripts.script(named: "find-in-page", injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        ]
        if mode != .off, bannerSweepEnabled {
            scripts.append(UserScripts.script(named: "banner-sweeper", injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        }
        if autoTranslateEnabled {
            scripts.append(UserScripts.script(named: "auto-translate", injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        }
        return scripts
    }

    func reloadUserScripts() {
        for tab in tabs {
            applyUserScripts(to: tab)
        }
    }

    private func applyUserScripts(to tab: Tab) {
        let controller = tab.webView.configuration.userContentController
        controller.removeAllUserScripts()
        userScripts(for: tab.appliedBlockingMode).forEach { controller.addUserScript($0) }
    }

    // MARK: - 사이트별 광고 차단

    /// 탭이 url로 이동하기 직전. 그 사이트의 차단 방식이 지금 얹힌 것과 다르면 규칙 목록과 스크립트를
    /// 갈아 끼운다 — 이동 정책을 결정하기 전에 바꿔야 그 문서와 하위 요청부터 새 방식이 먹는다.
    func applyBlocking(to tab: Tab, for url: URL) {
        if tab.bypassBlockerForNextLoad { return }   // 이번 로드는 규칙 없이 간다
        let mode = blockingModes.mode(for: url)
        guard mode != tab.appliedBlockingMode else { return }
        tab.appliedBlockingMode = mode
        applyRuleLists(to: tab)
        applyUserScripts(to: tab)
    }

    /// 탭의 방식에 맞는 규칙 목록을 얹는다. 감지 회피 목록이 아직 없으면 전체 목록을 임시로 얹고
    /// 컴파일을 시작한다 — 끝나면 그 방식의 탭들에 갈아 끼운다.
    private func applyRuleLists(to tab: Tab) {
        let controller = tab.webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        switch tab.appliedBlockingMode {
        case .full:
            ruleLists.forEach { controller.add($0) }
        case .networkOnly:
            if let lists = networkRuleLists {
                lists.forEach { controller.add($0) }
            } else {
                ruleLists.forEach { controller.add($0) }
                Task { @MainActor in await self.ensureNetworkRuleLists() }
            }
        case .off:
            break
        }
    }

    /// 감지 회피 목록을 준비한다. 여럿이 동시에 불러도 컴파일은 한 번. 끝나면 그 방식으로 열려 있는
    /// 탭에 바로 얹는다 — 새로고침은 하지 않는다.
    func ensureNetworkRuleLists() async {
        if networkRuleLists != nil { return }
        if networkListsTask == nil {
            networkListsTask = Task { @MainActor in await FilterManager.shared.loadNetworkOnlyRuleLists() }
        }
        guard let task = networkListsTask else { return }
        let lists = await task.value
        guard networkRuleLists == nil else { return }
        networkRuleLists = lists
        for tab in tabs where tab.appliedBlockingMode == .networkOnly {
            applyRuleLists(to: tab)
        }
    }

    /// 차단기가 막은 주소를 이 한 번만 규칙 없이 연다. 문서가 커밋되면 규칙을 다시 건다 —
    /// 그 페이지 안의 광고 요청은 그때부터 다시 막힌다. 사이트 설정은 건드리지 않는다.
    func loadBypassingBlocker(_ url: URL, in tab: Tab) {
        tab.blocked = nil
        tab.loadError = nil
        tab.loadErrorDetail = nil
        tab.bypassBlockerForNextLoad = true
        tab.appliedBlockingMode = .off
        tab.webView.configuration.userContentController.removeAllContentRuleLists()
        tab.webView.load(URLRequest(url: url))
    }

    /// 끊어 둔 딴 사이트 이동을 사용자가 열기로 했다. 규칙은 그대로 둔 채 그 주소로 간다 —
    /// 고정 탭이면 새 탭으로.
    func openBlockedTarget(_ url: URL, in tab: Tab) {
        tab.blocked = nil
        tab.coordinator.open(url, in: tab.webView)
    }

    /// 메뉴에서 이 사이트의 차단 방식을 바꿨다. 저장하고 이 탭에 바로 적용한 뒤 새로고침한다.
    /// 같은 사이트의 다른 탭은 다음 이동 때 따라온다.
    func setBlockingMode(_ mode: BlockingMode, for tab: Tab) {
        guard let url = tab.webView.url ?? tab.lastURL else { return }
        blockingModes.set(mode, for: url)
        Task { @MainActor in
            if mode == .networkOnly { await ensureNetworkRuleLists() }
            applyBlocking(to: tab, for: url)
            tab.webView.reload()
        }
    }

    func newTab(id: UUID = UUID()) {
        let tab = Tab(id: id, configuration: Self.makeConfiguration())
        userScripts(for: .full).forEach { tab.webView.configuration.userContentController.addUserScript($0) }
        ruleLists.forEach { tab.webView.configuration.userContentController.add($0) }
        tab.coordinator.onMainFrameNavigation = { [weak self, weak tab] url in
            guard let tab else { return }
            self?.applyBlocking(to: tab, for: url)
        }
        let base = tab.coordinator.onCommit
        tab.coordinator.onCommit = { [weak self, weak tab] url in
            base?(url)
            guard let tab else { return }
            // 규칙 없이 연 문서가 떴다 — 이제부터는 사이트 설정대로 다시 건다.
            if tab.bypassBlockerForNextLoad {
                tab.bypassBlockerForNextLoad = false
                self?.applyBlocking(to: tab, for: url)
            }
            self?.history.record(url: url, tabID: tab.id)
            self?.saveState()
        }
        // SPA 이동은 didCommit이 안 뜬다 — 로드 없는 주소 변화로 찍는다. 주소만 고친 것
        // (replaceState)은 새 방문이 아니다 — 재생 위치·스크롤을 주소에 계속 적는 사이트가 있다.
        tab.onURLChange = { [weak self, weak tab] url, replaced in
            guard let tab else { return }
            self?.history.record(url: url, tabID: tab.id, replacing: replaced)
            guard !replaced else { return }
            // SPA에는 로드 완료 신호가 없다. 새 화면이 그려질 틈을 준 뒤 찍는다.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                tab.captureSnapshot()
            }
        }
        // 찍은 그림은 지금 방문에 붙어 디스크로 간다 — 탭이 죽어도 카드에 그림이 남는다.
        tab.onSnapshot = { [weak self, weak tab] image in
            guard let self, let tab, let visit = self.history.lastVisit(tabID: tab.id) else { return }
            SnapshotStore.shared.store(image, for: visit.id)
        }
        tab.onTitleChange = { [weak self, weak tab] title, url in
            guard let tab else { return }
            self?.history.updateTitle(title, url: url, tabID: tab.id)
        }
        tab.coordinator.onOpenInNewTab = { [weak self, weak tab] url in
            guard let tab else { return }
            self?.openLinkInNewTab(url, from: tab)
        }
        tabs.append(tab)
        activate(tab)
    }

    /// 링크 롱탭 "새 탭에서 열기". 새 탭으로 전환하고, 방문 기록에는 원래 탭의 마지막
    /// 방문을 부모로 이어 가지를 만든다.
    func openLinkInNewTab(_ url: URL, from sourceTab: Tab) {
        let parent = history.lastVisit(tabID: sourceTab.id)
        newTab()
        guard let tab = activeTab else { return }
        if let parent { history.setParent(parent.id, forNextVisitIn: tab.id) }
        // 고정 탭에서 갈라진 탭은 격자에서 그 고정 그룹에 묶인다.
        if sourceTab.sticky { tab.stickyParentID = sourceTab.id }
        tab.webView.load(URLRequest(url: url))
    }

    func prepareFilters() async {
        ruleLists = await FilterManager.shared.loadRuleLists()
        // 필터 본문이 바뀌었을 수 있다 — 감지 회피 목록은 다음에 필요할 때 다시 컴파일한다.
        networkRuleLists = nil
        networkListsTask = nil
        for tab in tabs {
            applyRuleLists(to: tab)
        }
    }

    func close(_ tab: Tab) {
        // 절전 중인 탭은 웹뷰가 빈 페이지를 물고 있다 — 주소·이력은 저장해 둔 것을 쓴다.
        let url = tab.hibernated ? tab.lastURL : (tab.webView.url ?? tab.lastURL)
        let state = tab.pendingInteractionState ?? (tab.webView.interactionState as? Data)
        if let url {
            closedTabs.append(ClosedTab(url: url, state: state, tabID: tab.id,
                                        sticky: tab.sticky, stickyParentID: tab.stickyParentID))
            if closedTabs.count > Self.closedLimit { closedTabs.removeFirst(closedTabs.count - Self.closedLimit) }
        }
        tabs.removeAll { $0 === tab }
        if tabs.isEmpty { newTab() }
        if activeTab === tab, let last = tabs.last {
            activate(last)
        }
        saveState()
    }

    /// 마지막으로 닫은 탭을 새 탭으로 되살린다. 이력이 남아 있으면 이력째, 없으면 주소만.
    func reopenClosedTab() {
        guard let closed = closedTabs.last else { return }
        reopen(closed)
    }

    /// 닫은 탭 하나를 골라 되살린다. 새 탭은 새 ID로 시작하고, 방문 기록에서는 옛 카드의
    /// 마지막 방문을 부모로 이어 붙는다 — 옛 카드는 과거 기록으로 남는다.
    func reopen(_ closed: ClosedTab) {
        guard let index = closedTabs.lastIndex(where: { $0.tabID == closed.tabID && $0.url == closed.url }) else { return }
        closedTabs.remove(at: index)
        newTab()
        guard let tab = activeTab else { return }
        if let parent = history.lastVisit(tabID: closed.tabID) {
            history.setParent(parent.id, forNextVisitIn: tab.id)
        }
        tab.lastURL = closed.url
        tab.sticky = closed.sticky
        tab.stickyParentID = closed.stickyParentID
        if let state = closed.state {
            tab.webView.interactionState = state
        } else {
            tab.webView.load(URLRequest(url: closed.url))
        }
        saveState()
    }

    func reopenClosedTabFromGrid() {
        reopenClosedTab()
        pendingCollapse = false
        zoomProgress = 1
        showingGrid = false
    }


    func activate(_ tab: Tab) {
        // 그림은 보는 탭만 들고 있다. 안 보는 탭의 카드는 디스크 그림으로 그린다.
        if let previous = activeTab, previous !== tab { previous.thumbnail = nil }
        activeTab = tab
        tab.lastActivatedAt = Date()
        if tab.hibernated || tab.webView.url == nil {
            tab.hibernated = false
            tab.reloadWhenShown = false
            restoreContent(of: tab)
        } else if tab.reloadWhenShown {
            tab.reloadWhenShown = false
            tab.webView.reload()
        }
        enforceLiveLimit()
    }

    /// 빈 웹뷰에 페이지를 되살린다. 이력이 있으면 이력째, 없으면 주소만.
    private func restoreContent(of tab: Tab) {
        if let state = tab.pendingInteractionState {
            tab.pendingInteractionState = nil
            tab.webView.interactionState = state
            // 못 쓰는 상태값(WebKit 판 차이·파일 손상)이면 웹뷰가 조용히 무시한다 —
            // 이력 복원이 안 걸렸으면 주소라도 연다.
            if tab.webView.backForwardList.currentItem == nil, let url = tab.lastURL {
                tab.webView.load(URLRequest(url: url))
            }
        } else if let url = tab.lastURL {
            tab.webView.load(URLRequest(url: url))
        }
    }

    func saveState() {
        // 주소가 없는 탭은 저장 목록에서 빠진다 — tabs 기준 인덱스를 쓰면 복원 때 어긋나므로
        // 저장되는 목록 안에서의 자리를 센다.
        let saved = tabs.filter { $0.lastURL != nil }
        defaults.set(saved.compactMap { $0.lastURL?.absoluteString }, forKey: Self.stateKey)
        // 탭 ID를 주소와 나란히 저장한다 — 재시작 후에도 방문 기록 카드가 산 탭에 붙는다.
        defaults.set(saved.map { $0.id.uuidString }, forKey: Self.idsKey)
        let index = saved.firstIndex { $0 === activeTab } ?? max(saved.count - 1, 0)
        defaults.set(index, forKey: Self.activeKey)
        defaults.set(tabs.filter(\.sticky).map { $0.id.uuidString }, forKey: Self.stickyIDsKey)
        // 자식 → 고정 부모. "자식ID:부모ID" 짝으로 저장한다.
        defaults.set(tabs.compactMap { tab in tab.stickyParentID.map { "\(tab.id.uuidString):\($0.uuidString)" } },
                     forKey: Self.stickyParentsKey)
        defaults.set(closedTabs.map { $0.url.absoluteString }, forKey: Self.closedKey)
        defaults.set(closedTabs.map { $0.tabID.uuidString }, forKey: Self.closedIDsKey)
        defaults.set(closedTabs.map { $0.sticky ? "1" : "0" }, forKey: Self.closedStickyKey)
        defaults.set(closedTabs.map { $0.stickyParentID?.uuidString ?? "" }, forKey: Self.closedParentsKey)
    }

    /// 백그라운드로 빠질 때 부른다. 탭마다 뒤로가기 이력(interactionState)을 파일로 남긴다 —
    /// 여기 저장돼야 iOS가 앱을 죽여도 재시작 때 이력째 돌아온다. 없어진 탭의 파일은 지운다.
    func saveInteractionStates() {
        let fm = FileManager.default
        try? fm.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        var kept: Set<String> = []
        for tab in tabs {
            // 복원 뒤 아직 화면에 안 붙은 탭은 웹뷰가 비어 있다 — 읽어 둔 이력을 그대로 다시 쓴다.
            let data = tab.pendingInteractionState
                ?? (tab.webView.url != nil ? tab.webView.interactionState as? Data : nil)
            guard let data else { continue }
            try? data.write(to: stateDirectory.appendingPathComponent(tab.id.uuidString), options: .atomic)
            kept.insert(tab.id.uuidString)
        }
        for name in (try? fm.contentsOfDirectory(atPath: stateDirectory.path)) ?? [] where !kept.contains(name) {
            try? fm.removeItem(at: stateDirectory.appendingPathComponent(name))
        }
    }

    func restoreState() {
        let closedURLs = (defaults.stringArray(forKey: Self.closedKey) ?? []).compactMap(URL.init(string:))
        let closedIDs = (defaults.stringArray(forKey: Self.closedIDsKey) ?? []).compactMap(UUID.init(uuidString:))
        let closedSticky = defaults.stringArray(forKey: Self.closedStickyKey) ?? []
        let closedParents = defaults.stringArray(forKey: Self.closedParentsKey) ?? []
        closedTabs = closedURLs.enumerated().map { offset, url in
            ClosedTab(url: url, state: nil,
                      tabID: closedIDs.indices.contains(offset) ? closedIDs[offset] : UUID(),
                      sticky: closedSticky.indices.contains(offset) && closedSticky[offset] == "1",
                      stickyParentID: closedParents.indices.contains(offset)
                          ? UUID(uuidString: closedParents[offset]) : nil)
        }
        let urls = (defaults.stringArray(forKey: Self.stateKey) ?? []).compactMap(URL.init(string:))
        let ids = (defaults.stringArray(forKey: Self.idsKey) ?? []).compactMap(UUID.init(uuidString:))
        for (offset, url) in urls.enumerated() {
            // 옛 저장본에는 ID가 없다 — 짝이 안 맞으면 새 ID로 연다.
            newTab(id: ids.indices.contains(offset) ? ids[offset] : UUID())
            activeTab?.lastURL = url
            // 백그라운드 때 저장해 둔 뒤로가기 이력. activate가 소비한다.
            if let tab = activeTab {
                tab.pendingInteractionState =
                    try? Data(contentsOf: stateDirectory.appendingPathComponent(tab.id.uuidString))
            }
        }
        if tabs.isEmpty { newTab() }
        let stickyIDs = Set((defaults.stringArray(forKey: Self.stickyIDsKey) ?? []).compactMap(UUID.init(uuidString:)))
        for tab in tabs where stickyIDs.contains(tab.id) { tab.sticky = true }
        var parents: [UUID: UUID] = [:]
        for pair in defaults.stringArray(forKey: Self.stickyParentsKey) ?? [] {
            let pieces = pair.split(separator: ":").map(String.init)
            if pieces.count == 2, let child = UUID(uuidString: pieces[0]), let parent = UUID(uuidString: pieces[1]) {
                parents[child] = parent
            }
        }
        for tab in tabs { tab.stickyParentID = parents[tab.id] }
        // newTab()이 매번 activeTab을 덮으므로 루프가 끝난 뒤 저장된 자리로 되돌린다.
        // 로드는 하지 않는다 — 화면에 붙을 때 ContentView가 activate()로 연다.
        let index = defaults.integer(forKey: Self.activeKey)
        activeTab = tabs.indices.contains(index) ? tabs[index] : tabs[tabs.count - 1]
        // 되살린 탭은 내린 채로 시작한다 — 고를 때 이력째 불러온다. 보는 탭은 activate가 불러온다.
        for tab in tabs where tab !== activeTab { tab.hibernated = true }
        SnapshotStore.shared.prune(keeping: Set(history.visits.map(\.id)))
    }

    // MARK: - 타임라인

    /// 타임라인 카드가 업는 탭의 현재 상태. 저장하지 않고 볼 때마다 판정한다 — 탭은 계속
    /// 죽고 살아나므로 저장하면 어긋난다.
    enum TabStatus {
        case current      // 지금 보고 있는 탭
        case open         // 열려 있는 다른 탭
        case restorable   // 닫혔지만 되살릴 수 있는 탭
        case gone         // 기록만 남은 탭
    }

    func status(ofTabID id: UUID) -> TabStatus {
        if activeTab?.id == id { return .current }
        if tabs.contains(where: { $0.id == id }) { return .open }
        if closedTabs.contains(where: { $0.tabID == id }) { return .restorable }
        return .gone
    }

    func tab(withID id: UUID) -> Tab? {
        tabs.first { $0.id == id }
    }

    /// 격자에서 카드를 끌어다 놓았다. 끌던 카드를 놓은 자리에 넣고 나머지를 민다.
    /// 배열 순서가 곧 저장 순서라 옮기고 저장하면 재시작 뒤에도 유지된다.
    func move(tabID: UUID, onto targetID: UUID) {
        guard tabID != targetID,
              let from = tabs.firstIndex(where: { $0.id == tabID }),
              let to = tabs.firstIndex(where: { $0.id == targetID }) else { return }
        let moving = tabs.remove(at: from)
        // 오른쪽으로 옮기면 제거 때문에 대상 자리가 하나 당겨져 to가 곧 '대상 뒤'가 되고,
        // 왼쪽으로 옮기면 대상 자리가 그대로라 to가 곧 '대상 앞'이다.
        tabs.insert(moving, at: min(to, tabs.count))
        saveState()
    }

    /// 탭 카드가 보여줄 그림의 열쇠. 그림은 탭이 아니라 방문에 붙어 있으므로 그 탭의
    /// 마지막 방문을 찾는다 — 재시작해서 탭 객체가 비어 있어도 그림이 나온다.
    func snapshotID(forTabID id: UUID) -> UUID? {
        history.lastVisit(tabID: id)?.id
    }

    /// 타임라인 카드 머리를 눌렀다. 산 탭이면 전환, 되살릴 수 있으면 통째 복원, 기록만이면
    /// 마지막 페이지를 새 탭으로.
    func openRun(_ run: HistoryRun) {
        switch status(ofTabID: run.tabID) {
        case .current:
            break
        case .open:
            if let tab = tab(withID: run.tabID) { activate(tab) }
        case .restorable:
            if let closed = closedTabs.last(where: { $0.tabID == run.tabID }) { reopen(closed) }
        case .gone:
            openInNewTab(run.last)
        }
    }

    /// 타임라인에서 방문 하나를 눌렀다. 산 탭이면 전환하고, 그 주소가 뒤로가기 목록에 있으면
    /// 그 지점으로 이동한다 — 산 탭에 그냥 로드하면 앞쪽 이력이 잘린다. 목록에 없거나 죽은
    /// 탭이면 새 탭으로 연다.
    func openVisit(_ visit: Visit) {
        guard let tab = tab(withID: visit.tabID) else {
            openInNewTab(visit)
            return
        }
        activate(tab)
        let target = HistoryStore.stripFragment(visit.url)
        if let current = tab.webView.url, HistoryStore.stripFragment(current) == target { return }
        let list = tab.webView.backForwardList
        let items = list.backList + [list.currentItem].compactMap { $0 } + list.forwardList
        if let item = items.last(where: { HistoryStore.stripFragment($0.url) == target }) {
            tab.webView.go(to: item)
        } else {
            openInNewTab(visit)
        }
    }

    /// 방문 주소를 새 탭으로 연다. 새 탭의 첫 기록은 그 방문을 부모로 이어 붙는다.
    private func openInNewTab(_ visit: Visit) {
        newTab()
        guard let tab = activeTab else { return }
        history.setParent(visit.id, forNextVisitIn: tab.id)
        tab.webView.load(URLRequest(url: visit.url))
    }

    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        return configuration
    }
}
