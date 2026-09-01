import SwiftUI
import WebKit

struct ContentView: View {
    @State private var store = TabStore()
    @State private var pendingURL: URL?
    /// 격자에서 각 카드가 놓인 자리(화면 좌표). 활성 탭 것을 골라 접는 목표로 쓴다.
    @State private var cardFrames: [UUID: CGRect] = [:]
    @Environment(\.scenePhase) private var scenePhase

    // 격자는 늘 배치해 두고 투명도로만 감춘다. 눌린 순간에 띄우면 카드가 자기 자리를
    // 보고하기 전에 접기가 시작돼, 아직 기본값인 화면 중앙에서 줄다가 도중에 목표가
    // 바뀌며 위치가 튄다.
    var body: some View {
        ZStack {
            // 격자가 아래, 페이지가 위. 반대로 두면 줄어드는 페이지를 카드가 가린다.
            TabGridView(store: store, onCardFrame: { id, frame in
                cardFrames[id] = frame
                // 접기 대기 중에 활성 탭 카드가 자리를 잡으면(격자 스크롤이 방금 배치)
                // 그때 접기를 시작한다.
                if id == store.activeTab?.id, usableCollapseTarget(frame) {
                    store.beginCollapse()
                }
            })
                .opacity(store.showingGrid ? 1 : 0)
                .animation(nil, value: store.showingGrid)
                // 접기가 끝난 상태에서만 만질 수 있다. 펼치는 동안(진행률 상태는 이미 1)
                // 밑에 깔린 격자가 눌리는 것을 막는다.
                .allowsHitTesting(store.showingGrid && store.zoomProgress == 0)
            if let tab = store.activeTab {
                // BrowserView에 .id(tab.id)를 걸지 않는다. 탭을 바꿀 때 뷰가 통째로 새로
                // 만들어지면 웹뷰 자리를 아직 모르는 상태로 시작해 접힘 계산이 무너진다.
                // 웹뷰 교체는 BrowserView 안에서 웹뷰에만 건 .id가 맡는다.
                BrowserView(tab: tab, store: store, cardFrame: cardFrames[tab.id] ?? .zero)
                    .allowsHitTesting(store.zoomProgress == 1)
            }
            ForEach(Translator.sources, id: \.self) { TranslationBridge(source: $0) }
        }
        .task {
            // 세션 쿠키를 첫 페이지 로드 전에 되살린다 — activate()가 로드를 시작하기 전이어야
            // 로그인 풀린 화면이 먼저 뜨지 않는다.
            let cookieStore = WKWebsiteDataStore.default().httpCookieStore
            await SessionCookieStore.shared.restore(into: cookieStore)
            SessionCookieStore.shared.attach(to: cookieStore)
            store.restoreState()
            CloudSync.shared.start()
            await store.prepareFilters()
            if let tab = store.activeTab {
                store.activate(tab)
            }
            if let url = pendingURL {
                pendingURL = nil
                open(url)
            }
        }
        .onOpenURL { url in
            guard url.scheme == "http" || url.scheme == "https" else { return }
            if !store.ruleLists.isEmpty {
                open(url)
            } else {
                pendingURL = url
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .background {
                store.saveState()
                store.saveInteractionStates()
            }
        }
        .onChange(of: store.showingGrid) { _, showing in
            guard showing else { return }
            // 활성 탭 카드 자리가 이미 화면 안에 있으면 바로 접는다. 없으면(새 탭·스크롤 밖)
            // 격자의 scrollTo가 카드를 배치하고 onCardFrame이 이어받는다. 그래도 못 잡으면
            // 애니메이션 없이 접는다 — 원점으로 날아가는 것보다 낫다.
            if let id = store.activeTab?.id, let frame = cardFrames[id], usableCollapseTarget(frame) {
                store.beginCollapse()
            } else {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    store.collapseInstantly()
                }
            }
        }
    }

    /// 접기 목표로 쓸 수 있는 카드 자리인가 — 값이 있고 화면과 겹쳐야 한다. 화면 밖의 낡은
    /// 자리로 접으면 페이지가 밖으로 날아간다.
    private func usableCollapseTarget(_ frame: CGRect) -> Bool {
        frame != .zero && UIScreen.main.bounds.intersects(frame)
    }

    private func open(_ url: URL) {
        store.newTab()
        store.activeTab?.webView.load(URLRequest(url: url))
        store.zoomProgress = 1
        store.showingGrid = false
    }
}

/// 격자와 페이지를 오갈 때 쓰는 곡선. 목표를 살짝 지나쳤다 되돌아오는 스프링.
extension Animation {
    static var tabSwitch: Animation { .spring(duration: 0.2, bounce: 0.18) }
}
