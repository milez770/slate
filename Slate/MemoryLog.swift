#if DEBUG
import Foundation
import os

/// 기기 측정용 기록. 실행 인자 -slate.memlog YES로 켜면 5초마다 앱 메모리와 원장 크기, 번역 줄 상태를
/// Library/Caches/memlog.txt에 한 줄씩 남기고, 메모리 부족 알림·웹 프로세스 종료는 일어난 순간 남긴다.
/// 디버그 빌드에만 있다.
@MainActor
enum MemoryLog {
    static let isEnabled = UserDefaults.standard.bool(forKey: "slate.memlog")
    private static let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("memlog.txt")
    private static var store: TabStore?

    static func start(_ store: TabStore) {
        guard isEnabled, self.store == nil else { return }
        self.store = store
        event("시작")
        Task { @MainActor in
            while true {
                sample()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    static func event(_ text: String) {
        guard isEnabled else { return }
        write("\(timestamp()) 사건 \(text)")
    }

    private static func sample() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let mb = { (bytes: Double) in String(format: "%.0f", bytes / 1_048_576) }
        let stats = TranslationStats.shared
        var fields = [
            "메모리 \(mb(Double(info.phys_footprint)))MB",
            "최고 \(mb(Double(info.ledger_phys_footprint_peak)))MB",
            "주소공간 \(mb(Double(info.virtual_size)))MB",
            "여유 \(mb(Double(os_proc_available_memory())))MB",
        ]
        if let store {
            fields += ["탭 \(store.tabs.count)", "산페이지 \(store.liveTabCount)", "방문 \(store.history.visits.count)"]
        }
        fields += [
            "원장 \(TranslationCache.shared.count)",
            "번역요청 \(stats.requested)", "번역 \(stats.translated)", "실패 \(stats.failed)",
            "대기 \(stats.queued)", "버림 \(stats.dropped)",
        ]
        write("\(timestamp()) " + fields.joined(separator: " "))
    }

    private static func timestamp() -> String {
        Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }

    private static func write(_ line: String) {
        let data = Data((line + "\n").utf8)
        try? LineLog.append(data, to: url)
    }
}
#endif
