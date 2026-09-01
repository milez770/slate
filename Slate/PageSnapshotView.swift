import SwiftUI

/// 방문 하나의 페이지 그림. 방금 찍은 그림이 손에 있으면 그걸 쓰고, 없으면 디스크에서
/// 불러 채운다. 둘 다 없으면 호스트 첫 글자를 깐다.
struct PageSnapshotView: View {
    var visitID: UUID?
    /// 살아 있는 탭이 들고 있는 최신 그림. 디스크본보다 우선한다.
    var preloaded: UIImage?
    var placeholder: String
    var blurRadius: CGFloat = 0

    @State private var loaded: UIImage?

    var body: some View {
        Group {
            if let image = preloaded ?? loaded {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: blurRadius)
            } else {
                ZStack {
                    Color(.systemGray5)
                    Text(initial)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: visitID) {
            guard preloaded == nil, let visitID else { return }
            loaded = await SnapshotStore.shared.load(for: visitID)
        }
    }

    private var initial: String {
        guard let first = placeholder.first else { return "?" }
        return String(first).uppercased()
    }
}
