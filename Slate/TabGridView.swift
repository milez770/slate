import SwiftUI

struct TabGridView: View {
    @Bindable var store: TabStore
    var onCardFrame: (UUID, CGRect) -> Void
    private let columns = [GridItem(.adaptive(minimum: 150))]
    /// 지금 카드를 끌어다 대고 있는 자리. 놓으면 여기로 들어간다.
    @State private var dropTarget: UUID?
    /// 방금 탭을 닫았다 — 되돌리기 토스트가 떠 있다.
    @State private var showUndo = false
    /// 닫을 때마다 하나씩 오른다. 토스트 자동 숨김 타이머를 최신 닫기에만 묶는 열쇠다.
    @State private var undoGeneration = 0
    /// 지금 끌고 있는 카드. 손끝에 뜬 사본과 겹쳐 보이지 않게 원래 자리는 비워 둔다.
    @State private var dragging: UUID?
    /// 손끝 사본을 실제 카드와 같은 크기로 그리려고 재 둔다. 카드 폭은 화면 폭에 따라 달라진다.
    @State private var cardSize = CGSize(width: 150, height: 220)

    var body: some View {
        ScrollViewReader { proxy in
            gridScroll
                .onChange(of: store.showingGrid) { _, showing in
                    // 끌던 도중 격자를 닫으면 드롭 알림이 안 온다 — 여기서 되돌린다.
                    dragging = nil
                    dropTarget = nil
                    guard showing, let id = store.activeTab?.id else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
        }
    }

    /// 고정 탭 하나와 거기서 갈라진 탭들.
    private var stickyGroups: [(parent: Tab, children: [Tab])] {
        store.tabs.filter(\.sticky).map { parent in
            (parent, store.tabs.filter { $0.stickyParentID == parent.id })
        }
    }

    /// 그룹에 묶이지 않은 나머지. 격자 본체에 깔린다.
    private var ungroupedTabs: [Tab] {
        let stickyIDs = Set(store.tabs.filter(\.sticky).map(\.id))
        return store.tabs.filter { tab in
            !tab.sticky && !(tab.stickyParentID.map { stickyIDs.contains($0) } ?? false)
        }
    }

    private var gridScroll: some View {
        ScrollView {
            // 고정 그룹은 격자 맨 위에서 리스트와 같이 스크롤된다.
            LazyVStack(spacing: 14) {
                ForEach(stickyGroups, id: \.parent.id) { group in
                    stickyGroupRow(group.parent, children: group.children)
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(ungroupedTabs) { tab in
                        tabCell(tab)
                    }
                }
            }
            .padding()
            // 순서가 바뀌면 카드들이 새 자리로 밀려간다. 격자에 순서 자체를 물려야
            // 위치 변화가 애니메이션된다 — 바꾸는 쪽의 withAnimation만으로는 안 걸린다.
            .animation(.snappy(duration: 0.28), value: store.tabs.map(\.id))
        }
        // 카드가 아닌 빈 곳에 놓으면 순서는 그대로 두고 비워둔 자리만 되살린다.
        .dropDestination(for: String.self) { _, _ in
            dragging = nil
            dropTarget = nil
            return true
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
    }

    /// 카드 + 닫기 버튼 한 벌. 격자 본체와 그룹 줄이 같이 쓴다.
    private func tabCell(_ tab: Tab, height: CGFloat = 220) -> some View {
        // 카드 전체가 활성화 버튼, 닫기는 그 위에 겹친 별도 버튼이다.
        // 조상 뷰에 탭 제스처를 걸면 닫기 버튼과 경합해 닫기가 안 눌린다.
        ZStack(alignment: .topTrailing) {
            card(tab, height: height)
            closeButton(tab)
            if tab.sticky {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 26, height: 26)
                    .background(Color.keyGreen, in: Circle())
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .id(tab.id)
    }

    /// 고정 그룹 한 줄. 머리에 호스트, 안에 고정 탭과 갈라진 탭들이 가로로 눕는다.
    /// 스크롤에도 상단에 붙어 있어야 해서 카드를 작게 쓴다.
    private func stickyGroupRow(_ parent: Tab, children: [Tab]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 15, height: 15)
                    .background(Color.keyGreen, in: Circle())
                Text(parent.lastURL?.host ?? "고정")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .top, spacing: 8) {
                // 고정 탭 카드는 스크롤 밖 — 갈라진 탭이 아무리 많아도 항상 이 자리다.
                tabCell(parent, height: 140)
                    .frame(width: 104)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(children) { child in
                            tabCell(child, height: 140).frame(width: 104)
                        }
                    }
                }
                // 둥근 모서리 밖으로 카드가 비어져 나오지 않게 스크롤 영역을 자른다.
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(10)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.keyGreen.opacity(0.5), lineWidth: 1))
    }

    private func card(_ tab: Tab, height: CGFloat = 220) -> some View {
        Button { store.pick(tab) } label: {
            cardFace(tab, height: height)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tabCard")
        // 끌고 있는 동안 원래 자리는 비운다. 안 비우면 손끝 사본과 둘로 보인다.
        .opacity(dragging == tab.id ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: dragging)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
            onCardFrame(tab.id, frame)
            // 폭이 실제로 달라질 때만 잡는다. 매번 대입하면 재정렬 애니메이션이 도는 동안
            // 프레임이 바뀔 때마다 격자 전체가 다시 그려져 화면이 반짝인다.
            if frame.width > 0, abs(frame.width - cardSize.width) > 0.5 {
                cardSize = CGSize(width: frame.width, height: frame.height)
            }
        }
        // 길게 눌러 끌면 순서를 바꾼다. 짧게 누르는 건 그대로 탭 전환이다.
        .onDrag {
            dragging = tab.id
            return NSItemProvider(object: tab.id.uuidString as NSString)
        } preview: {
            cardFace(tab)
                .frame(width: cardSize.width, height: cardSize.height)
        }
        .dropDestination(for: String.self) { items, _ in
            dropTarget = nil
            dragging = nil
            guard let raw = items.first, let dragged = UUID(uuidString: raw) else { return false }
            withAnimation(.snappy(duration: 0.25)) {
                store.move(tabID: dragged, onto: tab.id)
            }
            return true
        } isTargeted: { targeted in
            if targeted {
                dropTarget = tab.id
            } else if dropTarget == tab.id {
                dropTarget = nil
            }
        }
        .overlay {
            if dropTarget == tab.id {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
    }

    // scaledToFill 이미지를 ZStack에 바로 넣으면 이미지가 보고하는 "자연 크기"가 220pt보다
    // 훨씬 커서 ZStack 자체가 그 크기로 부풀고, 바깥 .frame(min:max:)이 그걸 다시 220으로
    // 눌러 담을 때 내용이 가운데 기준으로 잘려 맨 아래 정렬해둔 Text가 보이는 영역 밖으로
    // 밀려난다. 이미지 쪽에서 먼저 220으로 고정 + clipped()해 자연 크기 자체를 220으로 만든다.
    private func cardFace(_ tab: Tab, height: CGFloat = 220) -> some View {
        ZStack(alignment: .bottom) {
            // 내용이 한눈에 다 읽히지 않게 살짝 뭉갠다.
            PageSnapshotView(visitID: store.snapshotID(forTabID: tab.id),
                             preloaded: tab.thumbnail,
                             placeholder: tab.lastURL?.host ?? "",
                             blurRadius: 4)
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .clipped()

            Text(tab.lastURL?.host ?? "새 탭")
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.black.opacity(0.55))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private func closeButton(_ tab: Tab) -> some View {
        Button {
            store.close(tab)
            withAnimation(.snappy(duration: 0.2)) { showUndo = true }
            undoGeneration += 1
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.black.opacity(0.6), in: Circle())
                .padding(.top, 8)
                .padding(.trailing, 8)
                .frame(minWidth: 44, minHeight: 44, alignment: .topTrailing)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("closeTabButton")
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if showUndo {
                undoToast
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Button { store.newTabFromGrid() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("newTabButton")
        }
        .padding(.bottom, 8)
    }

    /// 탭을 닫은 직후 잠깐 뜨는 되돌리기. 시간이 지나면 조용히 사라진다.
    private var undoToast: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { showUndo = false }
            store.reopenClosedTab()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .semibold))
                Text("닫은 탭 되돌리기")
                    .font(.footnote.weight(.medium))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .barSurface(Capsule())
        .accessibilityIdentifier("undoCloseButton")
        .task(id: undoGeneration) {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { showUndo = false }
        }
    }
}
