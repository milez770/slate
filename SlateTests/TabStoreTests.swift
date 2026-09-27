import WebKit
import XCTest
@testable import Slate

final class TabStoreTests: XCTestCase {
    @MainActor func testNewTabBecomesActive() {
        let store = TabStore(defaults: UserDefaults(suiteName: #function)!)
        store.newTab()
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertTrue(store.activeTab === store.tabs[0])
    }
    @MainActor func testCloseLastTabOpensFreshOne() {
        let store = TabStore(defaults: UserDefaults(suiteName: #function)!)
        store.newTab()
        store.close(store.tabs[0])
        XCTAssertEqual(store.tabs.count, 1)
    }
    @MainActor func testClosedTabIsReopenedWithItsURL() {
        let store = TabStore(defaults: UserDefaults(suiteName: #function)!)
        store.newTab()
        store.tabs[0].lastURL = URL(string: "https://one.example")!
        store.newTab()
        store.close(store.tabs[0])
        XCTAssertEqual(store.closedTabs.map(\.url), [URL(string: "https://one.example")!])
        store.reopenClosedTab()
        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertEqual(store.activeTab?.lastURL, URL(string: "https://one.example")!)
        XCTAssertTrue(store.closedTabs.isEmpty, "되살린 탭은 목록에서 빠진다")
    }

    @MainActor func testClosedBlankTabIsNotRecorded() {
        let store = TabStore(defaults: UserDefaults(suiteName: #function)!)
        store.newTab()
        store.newTab()
        store.close(store.tabs[0])
        XCTAssertTrue(store.closedTabs.isEmpty)
    }

    /// 메모리 부족 알림이 오면 보는 탭만 남기고 나머지 페이지를 내린다. 주소는 남고, 다시 고르면 돌아온다.
    @MainActor func testMemoryWarningHibernatesInactiveTabsAndActivateRestores() async throws {
        let store = TabStore(defaults: UserDefaults(suiteName: #function)!)
        store.newTab()
        store.newTab()
        let a = store.tabs[0], b = store.tabs[1]
        // 창에 붙어 있어야 웹뷰가 로드를 진행한다.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        for tab in [a, b] {
            tab.webView.frame = window.bounds
            window.addSubview(tab.webView)
        }
        window.isHidden = false
        a.webView.loadHTMLString("<p>A</p>", baseURL: URL(string: "https://a.example/")!)
        b.webView.loadHTMLString("<p>B</p>", baseURL: URL(string: "https://b.example/")!)
        try await waitUntil(describe: {
            "a.url=\(String(describing: a.webView.url)) a.loading=\(a.webView.isLoading) a.last=\(String(describing: a.lastURL)) b.url=\(String(describing: b.webView.url)) b.loading=\(b.webView.isLoading) b.last=\(String(describing: b.lastURL))"
        }) { !a.webView.isLoading && !b.webView.isLoading && a.lastURL != nil && b.lastURL != nil }
        store.activate(a)

        store.relieveMemoryPressure()
        XCTAssertFalse(a.hibernated, "보는 탭은 그대로")
        XCTAssertTrue(b.hibernated)
        XCTAssertNotNil(b.pendingInteractionState, "뒤로가기 이력을 들고 있다")
        XCTAssertEqual(store.liveTabCount, 1)
        try await waitUntil { b.webView.url?.absoluteString == "about:blank" }
        XCTAssertEqual(b.lastURL, URL(string: "https://b.example/")!, "빈 페이지 로드가 주소를 덮지 않는다")

        store.activate(b)
        XCTAssertFalse(b.hibernated)
        XCTAssertNil(b.pendingInteractionState, "복원에 썼다")
        try await waitUntil { b.webView.url?.host == "b.example" }
    }

    /// 페이지가 떠 있는 탭에서 차단기가 이동을 막으면 오류 화면이 아니라 띠다. 빈 탭이면 오류 화면에
    /// "차단 없이 열기" 근거(blockedURL)가 남는다.
    @MainActor func testBlockedNavigationShowsBannerWhenPageExistsAndErrorWhenNot() async throws {
        let store = TabStore(defaults: UserDefaults(suiteName: #function)!)
        store.newTab()
        let tab = store.tabs[0]
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        tab.webView.frame = window.bounds
        window.addSubview(tab.webView)
        window.isHidden = false
        let blocked = URL(string: "https://ads.example/land")!
        let error = NSError(domain: "WebKitErrorDomain", code: 104,
                            userInfo: [NSURLErrorFailingURLErrorKey: blocked, NSLocalizedDescriptionKey: "차단"])

        tab.coordinator.onFail?(error)
        XCTAssertEqual(tab.loadError, "차단", "빈 탭의 첫 로드가 막히면 오류 화면")
        XCTAssertEqual(tab.blockedURL, blocked)

        tab.coordinator.onStart?()
        tab.webView.loadHTMLString("<p>A</p>", baseURL: URL(string: "https://a.example/")!)
        try await waitUntil { !tab.webView.isLoading && tab.webView.url?.host == "a.example" && tab.lastURL?.host == "a.example" }
        tab.coordinator.onFail?(error)
        XCTAssertNil(tab.loadError, "페이지가 있으면 오류 화면을 덮지 않는다")
        XCTAssertEqual(tab.blockedURL, blocked, "띠로 알린다")
        XCTAssertEqual(tab.lastURL?.host, "a.example", "주소창은 원래 페이지")
    }

    /// 차단기가 광고 이동을 막았을 때 방금 누른 같은 사이트 링크가 있으면 그 링크로 간다.
    /// 고정 탭이면 새 탭으로.
    @MainActor func testBlockedAdRedirectFollowsTappedLink() async throws {
        let store = TabStore(defaults: UserDefaults(suiteName: #function)!)
        store.newTab()
        let tab = store.tabs[0]
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        tab.webView.frame = window.bounds
        window.addSubview(tab.webView)
        window.isHidden = false
        tab.webView.loadHTMLString("<p>A</p>", baseURL: URL(string: "https://a.example/")!)
        try await waitUntil { !tab.webView.isLoading && tab.webView.url?.host == "a.example" }
        let ad = URL(string: "https://ads.example/land")!
        let detail = URL(string: "https://a.example/detail/1")!
        let error = NSError(domain: "WebKitErrorDomain", code: 104,
                            userInfo: [NSURLErrorFailingURLErrorKey: ad, NSLocalizedDescriptionKey: "차단"])

        tab.coordinator.noteClickIntent(detail, prevented: true)
        tab.coordinator.onFail?(error)
        XCTAssertNil(tab.loadError)
        XCTAssertEqual(tab.blockedURL, ad)
        XCTAssertEqual(tab.blockedKind, .recovered)
        try await waitUntil { tab.webView.url?.path == "/detail/1" }
        // 시험 환경엔 네트워크가 없어 그 로드는 실패하고 주소는 원래 페이지로 돌아온다.
        try await waitUntil { !tab.webView.isLoading && tab.webView.url?.path == "/" }

        tab.sticky = true
        var opened: URL?
        tab.coordinator.onOpenInNewTab = { opened = $0 }
        tab.coordinator.noteClickIntent(detail, prevented: true)
        tab.coordinator.onFail?(error)
        XCTAssertEqual(opened, detail, "고정 탭이면 누른 링크를 새 탭으로")
    }

    /// "차단 없이 열기"는 그 로드 한 번만 규칙을 빼고, 문서가 커밋되면 사이트 설정대로 되돌린다.
    @MainActor func testBypassLoadSkipsRulesUntilCommit() {
        let store = TabStore(defaults: UserDefaults(suiteName: #function)!)
        store.newTab()
        let tab = store.tabs[0]
        let url = URL(string: "https://site7.com/detail/1")!
        tab.blockedURL = url
        tab.loadError = "차단"
        store.loadBypassingBlocker(url, in: tab)
        XCTAssertTrue(tab.bypassBlockerForNextLoad)
        XCTAssertEqual(tab.appliedBlockingMode, .off)
        XCTAssertNil(tab.blockedURL)
        XCTAssertNil(tab.loadError)
        store.applyBlocking(to: tab, for: url)
        XCTAssertEqual(tab.appliedBlockingMode, .off, "커밋 전에는 규칙을 다시 걸지 않는다")
        tab.coordinator.onCommit?(url)
        XCTAssertFalse(tab.bypassBlockerForNextLoad)
        XCTAssertEqual(tab.appliedBlockingMode, .full, "커밋되면 사이트 설정(전부 차단)으로 돌아온다")
    }

    @MainActor private func waitUntil(timeout: Duration = .seconds(25), describe: () -> String = { "" },
                                      _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { XCTFail("시간 안에 조건이 안 됐다 \(describe())"); return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @MainActor func testClosedTabsKeepOnlyLastTen() {
        let store = TabStore(defaults: UserDefaults(suiteName: #function)!)
        for i in 0..<12 {
            store.newTab()
            store.tabs.last?.lastURL = URL(string: "https://\(i).example")!
            store.close(store.tabs.last!)
        }
        XCTAssertEqual(store.closedTabs.count, 10)
        XCTAssertEqual(store.closedTabs.last?.url, URL(string: "https://11.example")!)
    }

    @MainActor func testClosedTabURLsSurviveRestart() {
        let d = UserDefaults(suiteName: #function)!
        d.removePersistentDomain(forName: #function)
        let a = TabStore(defaults: d)
        a.newTab()
        a.tabs[0].lastURL = URL(string: "https://one.example")!
        a.newTab()
        a.close(a.tabs[0])
        a.saveState()

        let b = TabStore(defaults: d)
        b.restoreState()
        XCTAssertEqual(b.closedTabs.map(\.url), [URL(string: "https://one.example")!])
        b.reopenClosedTab()
        XCTAssertEqual(b.activeTab?.lastURL, URL(string: "https://one.example")!)
    }

    @MainActor func testStateRoundtrip() {
        let d = UserDefaults(suiteName: #function)!
        d.removePersistentDomain(forName: #function)
        let a = TabStore(defaults: d)
        a.newTab()
        a.tabs[0].lastURL = URL(string: "https://example.com")!
        a.saveState()
        let b = TabStore(defaults: d)
        b.restoreState()
        XCTAssertEqual(b.tabs.map(\.lastURL), [URL(string: "https://example.com")!])
    }
    /// newTab()이 매번 activeTab을 덮으므로, 복원 후 손대지 않으면 늘 마지막 탭이 열린다.
    @MainActor func testActiveTabSurvivesRoundtrip() {
        let d = UserDefaults(suiteName: #function)!
        d.removePersistentDomain(forName: #function)
        let a = TabStore(defaults: d)
        for host in ["one", "two", "three"] {
            a.newTab()
            a.tabs.last?.lastURL = URL(string: "https://\(host).example")!
        }
        a.activate(a.tabs[1])
        a.saveState()

        let b = TabStore(defaults: d)
        b.restoreState()
        XCTAssertEqual(b.tabs.count, 3)
        XCTAssertTrue(b.activeTab === b.tabs[1], "가운데 탭을 보다 나갔으면 그 탭으로 돌아와야 한다")
    }

    /// 주소 없는 탭은 저장 목록에서 빠진다 — tabs 기준 인덱스를 그대로 쓰면 어긋난다.
    @MainActor func testActiveIndexSkipsBlankTabs() {
        let d = UserDefaults(suiteName: #function)!
        d.removePersistentDomain(forName: #function)
        let a = TabStore(defaults: d)
        a.newTab()                                                   // 주소 없는 빈 탭
        a.newTab()
        a.tabs[1].lastURL = URL(string: "https://one.example")!
        a.newTab()
        a.tabs[2].lastURL = URL(string: "https://two.example")!
        a.activate(a.tabs[2])
        a.saveState()

        let b = TabStore(defaults: d)
        b.restoreState()
        XCTAssertEqual(b.tabs.count, 2, "빈 탭은 복원되지 않는다")
        XCTAssertEqual(b.activeTab?.lastURL, URL(string: "https://two.example")!)
    }

    /// 저장된 인덱스가 탭 수보다 크면(저장 후 목록이 줄어든 경우) 마지막 탭으로 떨어진다.
    @MainActor func testOutOfRangeActiveIndexFallsBackToLast() {
        let d = UserDefaults(suiteName: #function)!
        d.removePersistentDomain(forName: #function)
        d.set(["https://one.example", "https://two.example"], forKey: "slate.tab.urls")
        d.set(9, forKey: "slate.tab.active")
        let store = TabStore(defaults: d)
        store.restoreState()
        XCTAssertTrue(store.activeTab === store.tabs[1])
    }

    @MainActor func testActivateLoadsRestoredTab() {
        let d = UserDefaults(suiteName: #function)!
        d.removePersistentDomain(forName: #function)
        d.set(["https://example.com", "https://example.org"], forKey: "slate.tab.urls")
        let store = TabStore(defaults: d)
        store.restoreState()
        let first = store.tabs[0]
        XCTAssertNil(first.webView.url)
        store.activate(first)
        XCTAssertNotNil(first.webView.url)
    }
    @MainActor func testBannerSweepDefaultsOn() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = TabStore(defaults: defaults)
        XCTAssertTrue(store.bannerSweepEnabled)
    }

    @MainActor func testDisablingBannerSweepRemovesScript() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = TabStore(defaults: defaults)
        store.newTab()
        let sources = { store.tabs[0].webView.configuration.userContentController.userScripts.map(\.source) }
        XCTAssertTrue(sources().contains { $0.contains("slateBannerSweeper") })
        store.bannerSweepEnabled = false
        XCTAssertFalse(sources().contains { $0.contains("slateBannerSweeper") })
        XCTAssertTrue(sources().contains { $0.contains("slateOverlayBuster") }, "오버레이 제거는 스위치와 무관하다")
    }

    @MainActor func testAutoTranslateDefaultsOn() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = TabStore(defaults: defaults)
        XCTAssertTrue(store.autoTranslateEnabled)
    }

    @MainActor func testDisablingAutoTranslateRemovesScript() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = TabStore(defaults: defaults)
        store.newTab()
        let sources = { store.tabs[0].webView.configuration.userContentController.userScripts.map(\.source) }
        XCTAssertTrue(sources().contains { $0.contains("slateAutoTranslate") })
        store.autoTranslateEnabled = false
        XCTAssertFalse(sources().contains { $0.contains("slateAutoTranslate") })
        XCTAssertFalse(defaults.bool(forKey: "slate.translate.auto"))
    }

    // MARK: - 방문 기록 연결 (탭 ID 영속·상태 판정)

    @MainActor private func makeHistory(_ name: String = #function) -> HistoryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-tabstore-history-\(name)-\(UUID().uuidString).json")
        return HistoryStore(fileURL: url)
    }

    /// 탭 ID가 재시작을 못 넘으면 방문 기록 카드가 산 탭에 붙지 못한다.
    @MainActor func testTabIDsSurviveRestart() {
        let d = UserDefaults(suiteName: #function)!
        d.removePersistentDomain(forName: #function)
        let a = TabStore(defaults: d, history: makeHistory())
        a.newTab()
        a.tabs[0].lastURL = URL(string: "https://one.example")!
        a.saveState()
        let savedID = a.tabs[0].id

        let b = TabStore(defaults: d, history: makeHistory())
        b.restoreState()
        XCTAssertEqual(b.tabs[0].id, savedID)
    }

    @MainActor func testClosedTabIDSurvivesRestart() {
        let d = UserDefaults(suiteName: #function)!
        d.removePersistentDomain(forName: #function)
        let a = TabStore(defaults: d, history: makeHistory())
        a.newTab()
        a.tabs[0].lastURL = URL(string: "https://one.example")!
        a.newTab()
        let closedID = a.tabs[0].id
        a.close(a.tabs[0])
        a.saveState()

        let b = TabStore(defaults: d, history: makeHistory())
        b.restoreState()
        XCTAssertEqual(b.closedTabs.map(\.tabID), [closedID])
    }

    @MainActor func testStatusJudgment() {
        let d = UserDefaults(suiteName: #function)!
        d.removePersistentDomain(forName: #function)
        let store = TabStore(defaults: d, history: makeHistory())
        for host in ["one", "two", "three"] {
            store.newTab()
            store.tabs.last?.lastURL = URL(string: "https://\(host).example")!
        }
        let closedID = store.tabs[0].id
        let openID = store.tabs[1].id
        let currentID = store.tabs[2].id
        store.close(store.tabs[0])

        XCTAssertEqual(store.status(ofTabID: currentID), .current)
        XCTAssertEqual(store.status(ofTabID: openID), .open)
        XCTAssertEqual(store.status(ofTabID: closedID), .restorable)
        XCTAssertEqual(store.status(ofTabID: UUID()), .gone)
    }

    /// 타임라인 카드에서 닫은 탭 하나를 골라 되살린다 — 다른 닫은 탭은 남는다.
    @MainActor func testReopenSpecificClosedTabLeavesOthers() {
        let d = UserDefaults(suiteName: #function)!
        d.removePersistentDomain(forName: #function)
        let store = TabStore(defaults: d, history: makeHistory())
        store.newTab()
        store.tabs[0].lastURL = URL(string: "https://one.example")!
        store.newTab()
        store.tabs[1].lastURL = URL(string: "https://two.example")!
        store.newTab()
        store.close(store.tabs[0])
        store.close(store.tabs[0])  // two.example
        XCTAssertEqual(store.closedTabs.count, 2)

        store.reopen(store.closedTabs[0])
        XCTAssertEqual(store.activeTab?.lastURL, URL(string: "https://one.example")!)
        XCTAssertEqual(store.closedTabs.map(\.url), [URL(string: "https://two.example")!])
    }

    /// 되살린 탭은 새 ID로 시작하고, 다음 첫 방문이 옛 카드의 마지막 방문을 부모로 문다.
    @MainActor func testReopenLinksNewVisitToOldCard() {
        let d = UserDefaults(suiteName: #function)!
        d.removePersistentDomain(forName: #function)
        let history = makeHistory()
        let store = TabStore(defaults: d, history: history)
        store.newTab()
        let oldID = store.tabs[0].id
        store.tabs[0].lastURL = URL(string: "https://one.example")!
        let parent = history.record(url: URL(string: "https://one.example")!, tabID: oldID)
        store.newTab()
        store.close(store.tabs[0])

        store.reopen(store.closedTabs[0])
        let newTab = store.activeTab!
        XCTAssertNotEqual(newTab.id, oldID, "되살린 탭은 새 ID")
        let first = history.record(url: URL(string: "https://one.example")!, tabID: newTab.id)
        XCTAssertEqual(first?.parentVisitID, parent?.id, "새 카드가 옛 카드에 이어진다")
    }

    // MARK: - 격자 접기 상태 전이

    /// openGrid()는 격자만 보이게 하고 접기는 대기 — 카드 자리 확보가 접기를 시작한다.
    @MainActor func testOpenGridWaitsForCollapseTarget() {
        let store = TabStore(defaults: UserDefaults(suiteName: #function)!, history: makeHistory())
        store.newTab()
        store.openGrid()
        XCTAssertTrue(store.showingGrid)
        XCTAssertTrue(store.pendingCollapse)
        XCTAssertEqual(store.zoomProgress, 1, "자리 잡히기 전에는 접지 않는다")
    }

    @MainActor func testBeginCollapseFiresOnceAndFolds() async {
        let store = TabStore(defaults: UserDefaults(suiteName: #function)!, history: makeHistory())
        store.newTab()
        store.openGrid()
        store.beginCollapse()
        XCTAssertFalse(store.pendingCollapse)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(store.zoomProgress, 0)
    }

    @MainActor func testCollapseInstantlyOnlyWhilePending() {
        let store = TabStore(defaults: UserDefaults(suiteName: #function)!, history: makeHistory())
        store.newTab()
        store.collapseInstantly()
        XCTAssertEqual(store.zoomProgress, 1, "격자가 안 열려 있으면 아무것도 안 한다")
        store.openGrid()
        store.collapseInstantly()
        XCTAssertEqual(store.zoomProgress, 0)
        XCTAssertFalse(store.pendingCollapse)
    }

    /// 링크 롱탭 "새 탭에서 열기"는 새 탭으로 전환하고, 방문 기록에서 원래 탭의 마지막
    /// 방문을 부모로 문다.
    @MainActor func testOpenLinkInNewTabLinksParentVisit() {
        let d = UserDefaults(suiteName: #function)!
        d.removePersistentDomain(forName: #function)
        let history = makeHistory()
        let store = TabStore(defaults: d, history: history)
        store.newTab()
        let source = store.tabs[0]
        let parent = history.record(url: URL(string: "https://one.example")!, tabID: source.id)

        store.openLinkInNewTab(URL(string: "https://two.example")!, from: source)
        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertTrue(store.activeTab !== source, "새 탭으로 전환한다")
        let first = history.record(url: URL(string: "https://two.example")!, tabID: store.activeTab!.id)
        XCTAssertEqual(first?.parentVisitID, parent?.id, "가지가 원래 탭에 이어진다")
    }

    // MARK: - 뒤로가기 이력 복원

    /// 앱이 백그라운드에서 죽었다 되살아나는 경로. 주소만 저장하면 뒤로가기 이력이 사라진다 —
    /// 백그라운드 진입 때 저장한 interactionState가 재시작 복원에서 이력째 돌아와야 한다.
    @MainActor func testBackHistorySurvivesRestart() async throws {
        let d = UserDefaults(suiteName: #function)!
        d.removePersistentDomain(forName: #function)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-tabstate-\(UUID().uuidString)", isDirectory: true)
        let a = TabStore(defaults: d, history: makeHistory(), stateDirectory: dir)
        a.newTab()
        let tab = a.tabs[0]
        // loadHTMLString은 이력 항목을 안 만든다 — 파일 로드로 진짜 이력을 쌓는다.
        let pages = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-pages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        for name in ["one", "two"] {
            let file = pages.appendingPathComponent("\(name).html")
            try "<html><body>\(name)</body></html>".write(to: file, atomically: true, encoding: .utf8)
            await withCheckedContinuation { continuation in
                let base = tab.coordinator.onFinish
                tab.coordinator.onFinish = { webView in
                    base?(webView)
                    tab.coordinator.onFinish = base
                    continuation.resume()
                }
                tab.webView.loadFileURL(file, allowingReadAccessTo: pages)
            }
        }
        XCTAssertTrue(tab.webView.canGoBack, "전제: 두 페이지를 실어 이력이 생겼다")
        a.saveState()
        a.saveInteractionStates()

        let b = TabStore(defaults: d, history: makeHistory(), stateDirectory: dir)
        b.restoreState()
        let restored = b.tabs[0]
        b.activate(restored)
        // 이력 복원이 비동기일 수 있다 — canGoBack이 설 때까지 기다린다.
        for _ in 0..<100 where !restored.webView.canGoBack {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(restored.webView.canGoBack, "복원 뒤에도 뒤로 갈 수 있어야 한다")
        XCTAssertEqual(restored.webView.backForwardList.backItem?.url.lastPathComponent, "one.html")
    }

    @MainActor func testPickAreaConvertsPointsToCSSPixels() {
        let store = TabStore(defaults: UserDefaults(suiteName: #function)!)
        store.newTab()
        let tab = store.tabs[0]
        let css = tab.cssRect(for: CGRect(x: 40, y: 100, width: 200, height: 60), scale: 2)
        XCTAssertEqual(css.origin.x, 20, accuracy: 0.01)
        XCTAssertEqual(css.origin.y, 50, accuracy: 0.01)
        XCTAssertEqual(css.width, 100, accuracy: 0.01)
        XCTAssertEqual(css.height, 30, accuracy: 0.01)
    }

    /// 오버레이는 화면 전체 좌표계, 웹뷰는 contentInset.top만큼 밀려 스크롤도 걸린다 —
    /// cssRect는 확대율로 나누기 전에 contentOffset을 먼저 더해 문서 좌표로 맞춰야 한다.
    @MainActor func testPickAreaAddsScrollOffsetBeforeScaling() {
        let store = TabStore(defaults: UserDefaults(suiteName: #function)!)
        store.newTab()
        let tab = store.tabs[0]
        let css = tab.cssRect(for: CGRect(x: 40, y: 100, width: 200, height: 60),
                               scale: 2, offset: CGPoint(x: 20, y: 118))
        XCTAssertEqual(css.origin.x, 30, accuracy: 0.01, "(40+20)/2")
        XCTAssertEqual(css.origin.y, 109, accuracy: 0.01, "(100+118)/2")
        XCTAssertEqual(css.width, 100, accuracy: 0.01, "너비·높이는 오프셋과 무관하다")
        XCTAssertEqual(css.height, 30, accuracy: 0.01)
    }

    @MainActor func testPickAreaReturnsEmptyWithNoPageLoaded() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = TabStore(defaults: defaults)
        store.newTab()
        let tab = store.tabs[0]
        // window.__slatePickArea가 없는 빈 웹뷰: JS 평가가 실패해도 빈 배열을 돌려줘야 한다.
        let rules = await tab.pickArea(CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertTrue(rules.isEmpty)
    }

    @MainActor func testSaveRulesWritesToInjectedStoreNotShared() async {
        // URL.host는 소문자로 정규화한다 — UUID를 그대로 쓰면 대문자 hex가 섞여 어긋난다.
        let host = "save-rules-test-\(UUID().uuidString.lowercased()).example"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-tests-\(#function)-\(UUID().uuidString).json")
        let store = SiteRuleStore(fileURL: tempURL)
        let tab = Tab(configuration: WKWebViewConfiguration(), ruleStore: store)

        await withCheckedContinuation { continuation in
            let base = tab.coordinator.onFinish
            tab.coordinator.onFinish = { webView in
                base?(webView)
                continuation.resume()
            }
            tab.webView.loadHTMLString("<html><body></body></html>", baseURL: URL(string: "https://" + host + "/")!)
        }

        tab.saveRules([])
        XCTAssertTrue(store.rules(for: host).isEmpty, "빈 배열은 아무것도 저장하지 않는다")

        let rule = SiteRule(kind: "selector", value: ".ad", added: Date())
        tab.saveRules([rule])
        XCTAssertEqual(store.rules(for: host), [rule], "주입한 저장소에는 들어가야 한다")
        XCTAssertTrue(SiteRuleStore.shared.rules(for: host).isEmpty, "Tab이 주입받지 않은 .shared에는 들어가면 안 된다")

        SiteRuleStore.shared.removeAll(host: host)
    }
}
