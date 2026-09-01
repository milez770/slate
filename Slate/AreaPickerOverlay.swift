import SwiftUI

/// 웹뷰 위에 덮여 드래그로 사각형을 그리는 화면.
struct AreaPickerOverlay: View {
    var onCancel: () -> Void
    var onConfirm: (CGRect) -> Void

    @State private var start: CGPoint?
    @State private var current: CGPoint?

    /// 앱 아이콘 배경색 #29FF6C.
    private let brandGreen = Color(red: 41 / 255, green: 255 / 255, blue: 108 / 255)

    private var rect: CGRect? {
        guard let start, let current else { return nil }
        let frame = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                           width: abs(current.x - start.x), height: abs(current.y - start.y))
        return (frame.width < 8 || frame.height < 8) ? nil : frame
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            if let rect {
                Rectangle()
                    .fill(brandGreen.opacity(0.15))
                    .overlay(Rectangle().stroke(brandGreen, lineWidth: 2))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
            VStack {
                Text(rect == nil ? "제거할 광고를 드래그해서 선택" : "선택한 영역을 제거한다")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 12)
                Spacer()
                // 하단 바(주소창) 위에 뜨도록 바닥에서 충분히 띄운다.
                HStack(spacing: 10) {
                    pickerButton("xmark", "취소") { onCancel() }
                    pickerButton("arrow.uturn.backward", "다시 선택", disabled: rect == nil) {
                        start = nil
                        current = nil
                    }
                    Button {
                        if let rect { onConfirm(rect) }
                    } label: {
                        Label("제거", systemImage: "eye.slash")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(brandGreen, in: Capsule())
                    }
                    .disabled(rect == nil)
                    .opacity(rect == nil ? 0.4 : 1)
                }
                .padding(.bottom, 140)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if start == nil { start = value.startLocation }
                    current = value.location
                }
        )
    }

    private func pickerButton(_ icon: String, _ title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(brandGreen)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}
