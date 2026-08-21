import UIKit

/// 管理底部浮层顶部区域的拖拽、弹窗反馈和下滑收起动画。
final class SheetCardDragCoordinator: NSObject {

    /// 浮层完全收起后触发的外部关闭回调。
    var onDismiss: (() -> Void)?

    /// 承载遮罩背景的整屏容器视图。
    private weak var sheetView: UIView?

    /// 需要响应拖拽变形的底部卡片视图。
    private weak var cardView: UIView?

    /// 安装在卡片顶部区域的拖拽手势。
    private let panGesture: UIPanGestureRecognizer

    /// 标记当前是否已经进入关闭动画，避免重复触发 dismiss。
    private var isClosing = false

    /// 记录当前手势累计的纵向拖拽距离。
    private var currentDragDistance: CGFloat = 0

    /// 允许触发拖拽的卡片顶部高度。
    private let topInteractionHeight: CGFloat = 96

    /// 下滑交互用于计算缩放进度的最大距离。
    private let maximumInteractiveDistance: CGFloat = 180

    /// 上滑时允许卡片向上位移的最大距离。
    private let maximumUpwardOffset: CGFloat = 18

    /// 上滑时允许卡片放大的最大比例。
    private let maximumPopScaleIncrease: CGFloat = 0.018

    /// 遮罩背景完全展开时的透明度。
    private let maximumBackdropAlpha: CGFloat = 0.22

    /// 初始化并把顶部拖拽手势挂载到卡片上。
    init(sheetView: UIView, cardView: UIView) {
        self.sheetView = sheetView
        self.cardView = cardView
        self.panGesture = UIPanGestureRecognizer()
        super.init()
        panGesture.addTarget(self, action: #selector(handlePan(_:)))
        panGesture.cancelsTouchesInView = false
        panGesture.delaysTouchesBegan = false
        panGesture.delegate = self
        cardView.addGestureRecognizer(panGesture)
    }

    /// 播放统一的下滑收起动画，并在结束后通知外部关闭控制器。
    func closeAnimated(initialVelocity: CGFloat = 0) {
        guard let sheetView, let cardView, !isClosing else { return }
        isClosing = true
        sheetView.isUserInteractionEnabled = false
        cardView.layer.removeAllAnimations()
        let closingDistance = cardView.bounds.height + sheetView.safeAreaInsets.bottom + 80
        let velocity = max(0.6, min(abs(initialVelocity) / 900, 1.8))

        UIView.animate(withDuration: 0.28,
                       delay: 0,
                       usingSpringWithDamping: 1,
                       initialSpringVelocity: velocity,
                       options: [.beginFromCurrentState, .curveEaseIn],
                       animations: {
            cardView.transform = CGAffineTransform(translationX: 0, y: closingDistance)
            self.setBackdropAlpha(0)
        }, completion: { [weak self] _ in
            self?.onDismiss?()
        })
    }

    /// 响应顶部拖拽手势并区分上滑弹窗、下滑位移与松手收起。
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let cardView else { return }
        switch gesture.state {
        case .began:
            cardView.layer.removeAllAnimations()
            currentDragDistance = 0
        case .changed:
            currentDragDistance = gesture.translation(in: cardView).y
            updateInteractiveTransform(for: currentDragDistance)
        case .ended, .cancelled, .failed:
            finishPan(with: gesture.velocity(in: cardView).y)
        default:
            break
        }
    }

    /// 根据手势松手速度和距离决定关闭或恢复打开状态。
    private func finishPan(with velocity: CGFloat) {
        let shouldClose = currentDragDistance > 8 || velocity > 160
        let shouldPop = currentDragDistance < -2 || velocity < -80
        if shouldClose {
            closeAnimated(initialVelocity: velocity)
        } else if shouldPop {
            playUpwardPopAnimation(initialVelocity: velocity)
        } else {
            restoreOpenState()
        }
    }

    /// 根据实时拖拽距离更新卡片的位移、上滑缩放和遮罩透明度。
    private func updateInteractiveTransform(for dragDistance: CGFloat) {
        guard let cardView else { return }
        if dragDistance >= 0 {
            let limitedDistance = min(dragDistance, maximumInteractiveDistance)
            let progress = limitedDistance / maximumInteractiveDistance
            cardView.transform = CGAffineTransform(translationX: 0, y: dragDistance)
            setBackdropAlpha(maximumBackdropAlpha * (1 - progress * 0.65))
        } else {
            let limitedDistance = min(abs(dragDistance), maximumInteractiveDistance)
            let progress = limitedDistance / maximumInteractiveDistance
            let upwardOffset = min(maximumUpwardOffset, limitedDistance * 0.22)
            let scale = 1 + progress * maximumPopScaleIncrease
            cardView.transform = CGAffineTransform(translationX: 0, y: -upwardOffset).scaledBy(x: scale, y: scale)
            setBackdropAlpha(maximumBackdropAlpha)
        }
    }

    /// 播放上滑后的轻量弹窗回弹效果。
    private func playUpwardPopAnimation(initialVelocity: CGFloat) {
        guard let cardView else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let popTransform = CGAffineTransform(translationX: 0, y: -maximumUpwardOffset).scaledBy(x: 1.018, y: 1.018)

        UIView.animate(withDuration: 0.12,
                       delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
                       animations: {
            cardView.transform = popTransform
        }, completion: { [weak self] _ in
            self?.restoreOpenState(initialVelocity: abs(initialVelocity) / 900)
        })
    }

    /// 把卡片和背景遮罩恢复到完全打开状态。
    private func restoreOpenState(initialVelocity: CGFloat = 0.8) {
        guard let cardView else { return }
        UIView.animate(withDuration: 0.42,
                       delay: 0,
                       usingSpringWithDamping: 0.72,
                       initialSpringVelocity: initialVelocity,
                       options: [.beginFromCurrentState, .allowUserInteraction],
                       animations: {
            cardView.transform = .identity
            self.setBackdropAlpha(self.maximumBackdropAlpha)
        })
    }

    /// 更新整屏遮罩背景的透明度。
    private func setBackdropAlpha(_ alpha: CGFloat) {
        sheetView?.backgroundColor = UIColor.black.withAlphaComponent(alpha)
    }

    /// 判断触摸点是否落在需要保留原生交互的控件上。
    private func isTouchInsideControl(_ touch: UITouch) -> Bool {
        var currentView = touch.view
        while let view = currentView {
            if view is UIControl { return true }
            currentView = view.superview
        }
        return false
    }
}

extension SheetCardDragCoordinator: UIGestureRecognizerDelegate {

    /// 只接收卡片顶部区域且不属于按钮、开关等控件的触摸。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let cardView, gestureRecognizer === panGesture, !isClosing else { return false }
        let location = touch.location(in: cardView)
        return location.y >= 0 && location.y <= topInteractionHeight && !isTouchInsideControl(touch)
    }

    /// 仅在纵向拖拽明显时开始识别，避免抢占横向控件交互。
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panGesture else { return true }
        let velocity = panGesture.velocity(in: cardView)
        return abs(velocity.y) >= abs(velocity.x)
    }
}
