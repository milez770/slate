import SwiftUI
import UIKit

/// Safari 스타일 주소창. 포커스 시작 시 전체 URL로 바꾸고 selectAll, 종료 시 원래 표시값(host)으로 복귀는
/// 호출부(BrowserView)가 `text`/`isFocused` 바인딩을 통해 관리한다.
struct AddressField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var editingValue: () -> String
    var onSubmit: (String) -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.clearButtonMode = .whileEditing
        field.keyboardType = .webSearch
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.returnKeyType = .go
        field.placeholder = "검색 또는 웹사이트 이름 입력"
        field.textAlignment = .center
        field.accessibilityIdentifier = "addressTextField"
        // 텍스트 길이만큼 폭을 우기면 하단 바 버튼들이 화면 밖으로 밀린다.
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.text = text
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged), for: .editingChanged)
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.parent = self
        if !uiView.isFirstResponder, uiView.text != text {
            uiView.text = text
        }
        uiView.textAlignment = isFocused ? .left : .center
        // becomeFirstResponder/resignFirstResponder를 updateUIView 안에서 동기 호출하면
        // 델리게이트가 그 자리에서 SwiftUI 상태(parent.text/isFocused)를 써서
        // "뷰 갱신 중 상태 변경" 루프가 된다 — 한 틱 미룬다.
        if isFocused, !uiView.isFirstResponder {
            DispatchQueue.main.async { uiView.becomeFirstResponder() }
        } else if !isFocused, uiView.isFirstResponder {
            DispatchQueue.main.async { uiView.resignFirstResponder() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: AddressField
        init(_ parent: AddressField) { self.parent = parent }

        @objc func editingChanged(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            let full = parent.editingValue()
            textField.text = full
            textField.selectAll(nil)
            DispatchQueue.main.async {
                self.parent.text = full
                self.parent.isFocused = true
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            DispatchQueue.main.async {
                self.parent.isFocused = false
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit(textField.text ?? "")
            textField.resignFirstResponder()
            return true
        }
    }
}
