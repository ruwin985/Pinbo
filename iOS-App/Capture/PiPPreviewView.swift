import UIKit
import AVFoundation
import SnapKit

/// 画中画小窗：承载前摄内容视图（Metal 滤镜预览），支持拖动、双指缩放、圆角调整。
final class PiPPreviewView: UIView {

    private let contentView: UIView

    init(contentView: UIView) {
        self.contentView = contentView
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        layer.cornerRadius = 16
        layer.masksToBounds = true
        layer.borderWidth = 2
        layer.borderColor = UIColor.white.withAlphaComponent(0.8).cgColor

        contentView.isUserInteractionEnabled = false
        addSubview(contentView)
        contentView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pan)
        addGestureRecognizer(pinch)
        isUserInteractionEnabled = true
    }

    // 拖动
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let parent = superview else { return }
        let translation = gesture.translation(in: parent)
        center = CGPoint(x: center.x + translation.x, y: center.y + translation.y)
        gesture.setTranslation(.zero, in: parent)
        clampToParent()
        onLayoutChanged?()
    }

    // 缩放
    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .changed {
            let scale = gesture.scale
            let newWidth = (bounds.width * scale).clamped(to: 90...260)
            let ratio = newWidth / bounds.width
            let newHeight = bounds.height * ratio
            bounds.size = CGSize(width: newWidth, height: newHeight)
            gesture.scale = 1.0
            clampToParent()
            onLayoutChanged?()
        }
    }

    private func clampToParent() {
        guard let parent = superview else { return }
        let half = CGSize(width: bounds.width / 2, height: bounds.height / 2)
        center.x = min(max(center.x, half.width), parent.bounds.width - half.width)
        center.y = min(max(center.y, half.height), parent.bounds.height - half.height)
    }

    /// 布局改变回调（用于记录 PiPKeyframe）
    var onLayoutChanged: (() -> Void)?

    /// 当前归一化布局（相对父视图）
    func normalizedLayout(in parent: UIView) -> (center: CGPoint, size: CGSize, cornerRadius: CGFloat) {
        let w = parent.bounds.width
        let h = parent.bounds.height
        return (
            center: CGPoint(x: center.x / w, y: center.y / h),
            size: CGSize(width: bounds.width / w, height: bounds.height / h),
            cornerRadius: layer.cornerRadius
        )
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
