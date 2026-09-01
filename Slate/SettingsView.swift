import SwiftUI

struct SettingsView: View {
    let store: TabStore
    @State private var refreshing = false
    @State private var resetting = false
    @State private var message: String?
    @State private var lastUpdated: Date?
    @State private var syncEnabled = CloudSync.shared.isEnabled

    var body: some View {
        Form {
            Section("iCloud") {
                Toggle("방문 기록 동기화", isOn: $syncEnabled)
                    .onChange(of: syncEnabled) { _, on in CloudSync.shared.isEnabled = on }
                Text("방문 기록이 내 iCloud 계정에 저장돼 기기 사이를 오간다. 주소와 제목은 기기에서 암호화해 올린다. 로그인 상태(쿠키)는 올리지 않는다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("번역") {
                Toggle("일본어·중국어 자동 번역", isOn: Binding(
                    get: { store.autoTranslateEnabled },
                    set: { store.autoTranslateEnabled = $0 }
                ))
                Text("페이지의 일본어·중국어 글자를 한국어로 바꾼다. 나중에 뜨는 글자도 계속 바꾼다. 기기 안에서 번역한다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let stats = TranslationStats.shared
                Text("요청 \(stats.requested) · 번역 \(stats.translated) · 실패 \(stats.failed) · 원장 적중 \(stats.cacheHits) · 대기 \(stats.queued) · 준비된 원어 \(stats.prepared.isEmpty ? "없음" : stats.prepared.joined(separator: ","))")
                    .font(.caption2).foregroundStyle(.secondary)
                if !stats.lastError.isEmpty {
                    Text("마지막 오류: \(stats.lastError)").font(.caption2).foregroundStyle(.red)
                }
                if !stats.lastFailedText.isEmpty {
                    Text("마지막 실패 문장: \(stats.lastFailedText.prefix(80))").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Section("배너") {
                Toggle("배너 자동 제거", isOn: Binding(
                    get: { store.bannerSweepEnabled },
                    set: { store.bannerSweepEnabled = $0 }
                ))
                Text("이미지 배너가 줄지어 있으면 자동으로 지운다. 정상 요소가 사라지는 사이트에서 끈다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("광고 필터") {
                LabeledContent("마지막 갱신",
                    value: lastUpdated?.formatted(date: .abbreviated, time: .shortened) ?? "번들 초기값")
                Button(refreshing ? "갱신 중…" : "지금 갱신") {
                    refreshing = true
                    Task {
                        do {
                            try await FilterManager.shared.refresh()
                            await store.prepareFilters()
                            lastUpdated = FilterManager.shared.lastUpdated
                            message = "갱신 완료"
                        } catch {
                            message = "실패: \(error.localizedDescription)"
                        }
                        refreshing = false
                    }
                }
                .disabled(refreshing || resetting)
                Button(resetting ? "복원 중…" : "번들 초기값으로 되돌리기") {
                    resetting = true
                    Task {
                        await FilterManager.shared.resetToBundled()
                        await store.prepareFilters()
                        lastUpdated = FilterManager.shared.lastUpdated
                        message = "초기값 복원 완료"
                        resetting = false
                    }
                }
                .disabled(refreshing || resetting)
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            Section("직접 지운 광고") {
                if SiteRuleStore.shared.hosts.isEmpty {
                    Text("없음").foregroundStyle(.secondary)
                } else {
                    ForEach(SiteRuleStore.shared.hosts, id: \.self) { host in
                        DisclosureGroup(host) {
                            ForEach(SiteRuleStore.shared.rules(for: host)) { rule in
                                HStack(spacing: 12) {
                                    Toggle("", isOn: Binding(
                                        get: { rule.enabled },
                                        set: { SiteRuleStore.shared.setEnabled(rule, enabled: $0, host: host) }
                                    ))
                                    .labelsHidden()
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(rule.value)
                                            .font(.system(.footnote, design: .monospaced))
                                            .foregroundStyle(rule.enabled ? .primary : .secondary)
                                        Text(rule.enabled ? rule.added.formatted(date: .abbreviated, time: .omitted)
                                                          : "꺼짐 · " + rule.added.formatted(date: .abbreviated, time: .omitted))
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("삭제", role: .destructive) {
                                        SiteRuleStore.shared.remove(rule, host: host)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            Button("이 사이트 규칙 전부 삭제", role: .destructive) {
                                SiteRuleStore.shared.removeAll(host: host)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            lastUpdated = FilterManager.shared.lastUpdated
        }
    }
}
