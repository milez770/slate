import SwiftUI
import WebKit
import os

struct SettingsView: View {
    let store: TabStore
    @State private var refreshing = false
    @State private var resetting = false
    @State private var message: String?
    @State private var lastUpdated: Date?
    @State private var syncEnabled = CloudSync.shared.isEnabled
    @State private var cookieRules = CookieRuleStore.shared
    @State private var newCookieDomain = ""
    @State private var newCookieName = ""
    @State private var newCookieValue = ""
    @State private var newCookieDays = "365"

    var body: some View {
        Form {
            Section("iCloud") {
                Toggle("방문 기록 동기화", isOn: $syncEnabled)
                    .onChange(of: syncEnabled) { _, on in CloudSync.shared.isEnabled = on }
                Text("방문 기록이 내 iCloud 계정에 저장돼 기기 사이를 오간다. 주소와 제목은 기기에서 암호화해 올린다. 로그인 상태(쿠키)는 올리지 않는다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("방문 \(store.history.visits.count)개 · history.json \(ByteCountFormatter.string(fromByteCount: Int64(store.history.fileSize), countStyle: .file))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("탭 \(store.tabs.count)개(살아 있는 페이지 \(store.liveTabCount)) · 앱이 쓰는 메모리 \(ByteCountFormatter.string(fromByteCount: Int64(processFootprint()), countStyle: .memory)) · 더 쓸 수 있는 메모리 \(ByteCountFormatter.string(fromByteCount: Int64(os_proc_available_memory()), countStyle: .memory))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Section("번역") {
                Toggle("일본어·중국어 자동 번역", isOn: Binding(
                    get: { store.autoTranslateEnabled },
                    set: { store.autoTranslateEnabled = $0 }
                ))
                Text("페이지의 일본어·중국어 글자를 한국어로 바꾼다. 나중에 뜨는 글자도 계속 바꾼다. 기기 안에서 번역한다. 원문이 필요하면 더보기 메뉴의 \"원문 보기\"로 그 탭만 새로고침 없이 되돌린다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let stats = TranslationStats.shared
                Text("요청 \(stats.requested) · 번역 \(stats.translated) · 실패 \(stats.failed) · 원장 적중 \(stats.cacheHits) · 대기 \(stats.queued) · 준비된 원어 \(stats.prepared.isEmpty ? "없음" : stats.prepared.joined(separator: ","))")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("원장 \(TranslationCache.shared.count)항목 · translations.jsonl \(ByteCountFormatter.string(fromByteCount: Int64(TranslationCache.shared.fileSize), countStyle: .file))")
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
            Section("사이트별 광고 차단") {
                Text("더보기 메뉴의 \"이 사이트 광고 차단\"으로 바꾼 사이트. 감지 회피는 광고 요청은 막고 요소 숨김 규칙만 빼서 광고 차단 감지를 피한다. 끄기는 그 사이트에서 차단을 전부 끈다. 삭제하면 전부 차단으로 돌아간다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if store.blockingModes.sites.isEmpty {
                    Text("없음").foregroundStyle(.secondary)
                } else {
                    ForEach(store.blockingModes.sites, id: \.self) { site in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(site)
                                    .font(.system(.footnote, design: .monospaced))
                                Text(store.blockingModes.modes[site]?.label ?? "")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("삭제", role: .destructive) { store.blockingModes.set(.full, site: site) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            Section("쿠키 규칙") {
                Text("지정한 도메인에 쿠키를 미리 심는다. 해외에서 지역·연령 확인으로 막히는 사이트를, 그 확인을 통과하면 심어지는 쿠키를 직접 넣어 여는 데 쓴다. 앱을 켤 때 첫 로드 전에 심는다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(cookieRules.rules) { rule in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(rule.name)=\(rule.value)")
                                .font(.system(.footnote, design: .monospaced))
                                .lineLimit(1)
                            Text("\(rule.domain) · \(rule.expiresDays)일")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("삭제", role: .destructive) { cookieRules.remove(rule) }
                            .buttonStyle(.borderless)
                    }
                }
                VStack(spacing: 6) {
                    TextField("도메인 (예: .example.co.jp)", text: $newCookieDomain)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("쿠키 이름", text: $newCookieName)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("값", text: $newCookieValue)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("만료 (일)", text: $newCookieDays)
                        .keyboardType(.numberPad)
                }
                .font(.system(.footnote, design: .monospaced))
                Button("규칙 추가") {
                    let domain = newCookieDomain.trimmingCharacters(in: .whitespaces)
                    let name = newCookieName.trimmingCharacters(in: .whitespaces)
                    guard !domain.isEmpty, !name.isEmpty else { return }
                    let rule = CookieRule(domain: domain, name: name, value: newCookieValue,
                                          expiresDays: Int(newCookieDays) ?? 365)
                    cookieRules.add(rule)
                    Task {
                        // 재시작 안 해도 지금 심는다.
                        await cookieRules.inject(into: WKWebsiteDataStore.default().httpCookieStore)
                    }
                    newCookieDomain = ""; newCookieName = ""; newCookieValue = ""; newCookieDays = "365"
                }
                .disabled(newCookieDomain.trimmingCharacters(in: .whitespaces).isEmpty
                          || newCookieName.trimmingCharacters(in: .whitespaces).isEmpty)
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

/// 지금 이 프로세스가 쥔 메모리(phys_footprint). iOS가 한도를 잴 때 보는 값.
func processFootprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}
