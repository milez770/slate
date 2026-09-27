import Foundation
import Observation

/// 사이트별 광고 차단 방식.
enum BlockingMode: String, CaseIterable {
    /// 규칙 목록 전부와 광고 스크립트. 기본값.
    case full = "full"
    /// 요소 숨김 규칙을 뺀 목록. 광고 요청은 막고, 미끼 요소를 숨기지 않아 광고 차단 감지를 통과한다.
    case networkOnly = "network"
    /// 규칙 목록도 광고 스크립트도 없다.
    case off = "off"

    var label: String {
        switch self {
        case .full: return "전부 차단"
        case .networkOnly: return "감지 회피"
        case .off: return "끄기"
        }
    }
}

/// 등록 도메인 → 차단 방식. 기본(전부 차단)은 저장하지 않는다.
@MainActor
@Observable
final class BlockingModeStore {
    static let shared = BlockingModeStore(defaults: .standard)
    private static let key = "slate.blocking.modes"
    private let defaults: UserDefaults
    private(set) var modes: [String: BlockingMode] = [:]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let raw = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        modes = raw.compactMapValues(BlockingMode.init(rawValue:))
    }

    /// 저장 키. www 유무·서브도메인 차이를 등록 도메인으로 뭉갠다.
    nonisolated static func site(for url: URL) -> String? {
        url.host.map(BrowserCoordinator.registrableDomain)
    }

    func mode(for url: URL?) -> BlockingMode {
        guard let url, let site = Self.site(for: url) else { return .full }
        return modes[site] ?? .full
    }

    func set(_ mode: BlockingMode, for url: URL) {
        guard let site = Self.site(for: url) else { return }
        set(mode, site: site)
    }

    func set(_ mode: BlockingMode, site: String) {
        if mode == .full {
            modes.removeValue(forKey: site)
        } else {
            modes[site] = mode
        }
        defaults.set(modes.mapValues(\.rawValue), forKey: Self.key)
    }

    var sites: [String] { modes.keys.sorted() }
}
