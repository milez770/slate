import UIKit

/// 웹뷰에 손이 닿은 시각만 기록하는 제스처 인식기. 터치를 가로채지 않고 닿는 즉시 실패
/// 상태로 빠져 웹뷰의 스크롤·탭에는 영향이 없다. 이동 정책이 스크립트 주도 이동을
/// "사용자가 방금 만져서 난 것인가"로 가르는 데 쓴다.
final class TouchObserver: UIGestureRecognizer {
    var onTouch: (() -> Void)?

    static func make(onTouch: @escaping () -> Void) -> TouchObserver {
        let observer = TouchObserver()
        observer.onTouch = onTouch
        observer.cancelsTouchesInView = false
        observer.delaysTouchesBegan = false
        observer.delaysTouchesEnded = false
        return observer
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        onTouch?()
        state = .failed
    }
}
