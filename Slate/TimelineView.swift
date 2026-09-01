import SwiftUI

struct TimelineView: View {
    let store: TabStore
    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Set<UUID> = []
    @State private var searchText = ""
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Group {
                if store.history.visits.isEmpty {
                    ContentUnavailableView("방문 기록 없음", systemImage: "clock",
                                           description: Text("페이지를 열면 여기 쌓인다."))
                } else if searchText.isEmpty {
                    timelineList
                } else {
                    searchList
                }
            }
            .navigationTitle("방문 기록")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("전체 삭제", role: .destructive) { confirmClear = true }
                        .disabled(store.history.visits.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                }
            }
            .confirmationDialog("방문 기록을 전부 지운다", isPresented: $confirmClear,
                                titleVisibility: .visible) {
                Button("전부 삭제", role: .destructive) { store.history.removeAll() }
            }
        }
        .searchable(text: $searchText, prompt: "기록에서 찾기")
    }

    // MARK: - 목록

    private var timelineList: some View {
        List {
            if !store.history.pinned.isEmpty {
                Section("고정") {
                    ForEach(store.history.pinned) { visit in
                        pinnedRow(visit)
                    }
                }
            }
            ForEach(Array(daySections.enumerated()), id: \.element.day) { index, section in
                Section(dayLabel(section.day)) {
                    // 맨 위가 현재라는 걸 못 박는다. 아래로 갈수록 과거다.
                    if index == 0 { nowRow }
                    ForEach(section.runs) { run in
                        runRow(run)
                        if isExpanded(run) {
                            let steps = Array(run.visits.reversed())
                            ForEach(Array(steps.enumerated()), id: \.element.id) { offset, visit in
                                stepRow(visit, isOldest: offset == steps.count - 1)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var daySections: [(day: Date, runs: [HistoryRun])] {
        let runs = HistoryStore.runs(from: store.history.visits)
        let grouped = Dictionary(grouping: runs) { Calendar.current.startOfDay(for: $0.last.date) }
        return grouped.keys.sorted(by: >).map { (day: $0, runs: grouped[$0] ?? []) }
    }

    private func dayLabel(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "오늘" }
        if Calendar.current.isDateInYesterday(day) { return "어제" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: - 줄

    private var nowRow: some View {
        railRow(dot: .now, hidesTop: true) {
            HStack(spacing: 6) {
                Text("지금")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Image(systemName: "arrow.down")
                    .font(.system(size: 9, weight: .bold))
                Text("과거")
                    .font(.caption2)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
        }
    }

    /// 그룹이 펼쳐져 있나. 방문 id 하나라도 집합에 있으면 펼침 — 그룹 id는 맨 위 방문을
    /// 지우면 바뀌어서 열쇠로 못 쓴다.
    private func isExpanded(_ run: HistoryRun) -> Bool {
        run.visits.contains { expanded.contains($0.id) }
    }

    private func runRow(_ run: HistoryRun) -> some View {
        let status = store.status(ofTabID: run.tabID)
        let isLive = status == .current || status == .open
        return railRow(dot: isLive ? .live : .past) {
            HStack(spacing: 10) {
                Button {
                    store.openRun(run)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        snapshot(of: run.last, width: 62, height: 44, corner: 6)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                if status == .current { badge("현재") }
                                Text(displayTitle(run.last))
                                    .font(.subheadline)
                                    .lineLimit(1)
                            }
                            HStack(spacing: 4) {
                                if run.first.parentVisitID != nil {
                                    Image(systemName: "arrow.turn.up.left")
                                        .font(.system(size: 9))
                                }
                                Text(subtitle(for: run, status: status))
                                    .lineLimit(1)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if run.visits.count > 1 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            let ids = run.visits.map(\.id)
                            if isExpanded(run) {
                                ids.forEach { expanded.remove($0) }
                            } else {
                                expanded.formUnion(ids)
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded(run) ? 180 : 0))
                            .frame(width: 32, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("expandRunButton")
                }
            }
        }
        .swipeActions(edge: .trailing) {
            Button("삭제", role: .destructive) {
                store.history.remove(ids: run.visits.map(\.id))
            }
        }
    }

    /// 한 탭 안에서 밟아 간 페이지 하나. 목록 전체와 같이 최신이 위다 — 사슬의 출발점만
    /// 표시해 어느 쪽이 시작인지 보이게 한다.
    private func stepRow(_ visit: Visit, isOldest: Bool) -> some View {
        railRow(dot: .step) {
            Button {
                store.openVisit(visit)
                dismiss()
            } label: {
                HStack(spacing: 10) {
                    snapshot(of: visit, width: 44, height: 32, corner: 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayTitle(visit))
                            .font(.footnote)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Text(visit.date.formatted(date: .omitted, time: .shortened))
                                .monospacedDigit()
                            Text(hostDisplay(visit.url))
                                .lineLimit(1)
                            if isOldest { Text("시작").foregroundStyle(.tertiary) }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .swipeActions(edge: .trailing) {
            Button("삭제", role: .destructive) { store.history.remove(visit) }
        }
    }

    /// 고정 선반의 줄. 시간 레일 밖이라 레일 없이 그린다. 스와이프는 삭제가 아니라 해제다.
    private func pinnedRow(_ visit: Visit) -> some View {
        Button {
            store.openVisit(visit)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                snapshot(of: visit, width: 56, height: 40, corner: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle(visit))
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(hostDisplay(visit.url))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button("고정 해제") { store.history.setPinned(false, id: visit.id) }
                .tint(.orange)
        }
    }

    // MARK: - 레일

    private enum RailDot {
        case now, live, past, step
    }

    /// 왼쪽 세로줄 + 점. 줄이 끊기지 않게 줄은 칸 높이를 다 쓰고, 안쪽 내용에만 여백을 준다.
    private func railRow<Content: View>(dot: RailDot, hidesTop: Bool = false,
                                        @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            rail(dot: dot, hidesTop: hidesTop)
            content()
                .padding(.vertical, 8)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowSeparator(.hidden)
    }

    private func rail(dot: RailDot, hidesTop: Bool) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(hidesTop ? Color.clear : Color(.separator))
                .frame(width: 1)
            dotShape(dot)
            Rectangle()
                .fill(Color(.separator))
                .frame(width: 1)
        }
        .frame(width: 12)
    }

    @ViewBuilder
    private func dotShape(_ dot: RailDot) -> some View {
        switch dot {
        case .now:
            Circle()
                .fill(Color.accentColor)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(Color.accentColor.opacity(0.25), lineWidth: 4))
        case .live:
            Circle().fill(.green).frame(width: 8, height: 8)
        case .past:
            Circle().fill(Color(.tertiaryLabel)).frame(width: 7, height: 7)
        case .step:
            Circle().fill(Color(.separator)).frame(width: 4, height: 4)
        }
    }

    // MARK: - 조각

    private func snapshot(of visit: Visit, width: CGFloat, height: CGFloat,
                          corner: CGFloat) -> some View {
        // 위쪽을 잘라 보여준다 — 페이지는 제목·머리글이 맨 위에 있어 거기가 제일 잘 구분된다.
        PageSnapshotView(visitID: visit.id, placeholder: hostDisplay(visit.url))
            .frame(width: width, height: height, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: corner))
            .overlay(RoundedRectangle(cornerRadius: corner)
                .strokeBorder(Color(.separator), lineWidth: 0.5))
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.green.opacity(0.18), in: Capsule())
            .foregroundStyle(.green)
    }

    private func subtitle(for run: HistoryRun, status: TabStore.TabStatus) -> String {
        var parts = [hostDisplay(run.last.url)]
        if run.visits.count > 1 { parts.append("\(run.visits.count)단계") }
        parts.append(elapsedLabel(run.last.date))
        if status == .restorable { parts.append("되살리기") }
        return parts.joined(separator: " · ")
    }

    /// 오늘 안이면 얼마나 지났는지로 쓴다. 위에서 아래로 숫자가 커지므로 정렬 방향을 따로
    /// 적지 않아도 읽힌다. 어제부터는 날짜 구획이 이미 있으니 시각만.
    private func elapsedLabel(_ date: Date, now: Date = Date()) -> String {
        guard Calendar.current.isDateInToday(date) else {
            return date.formatted(date: .omitted, time: .shortened)
        }
        let seconds = max(now.timeIntervalSince(date), 0)
        if seconds < 60 { return "방금" }
        if seconds < 3600 { return "\(Int(seconds / 60))분 전" }
        return "\(Int(seconds / 3600))시간 전"
    }

    // MARK: - 검색

    private var searchList: some View {
        List {
            ForEach(searchResults) { visit in
                Button {
                    store.openVisit(visit)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        snapshot(of: visit, width: 56, height: 40, corner: 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayTitle(visit))
                                .font(.subheadline)
                                .lineLimit(1)
                            Text("\(hostDisplay(visit.url)) · \(visit.date.formatted(date: .numeric, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button("삭제", role: .destructive) { store.history.remove(visit) }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if searchResults.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private var searchResults: [Visit] {
        let query = searchText.lowercased()
        return store.history.visits.reversed().filter {
            ($0.title?.lowercased().contains(query) ?? false)
                || $0.url.absoluteString.lowercased().contains(query)
        }
    }

    private func displayTitle(_ visit: Visit) -> String {
        if let title = visit.title, !title.isEmpty { return title }
        return hostDisplay(visit.url)
    }

    private func hostDisplay(_ url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
