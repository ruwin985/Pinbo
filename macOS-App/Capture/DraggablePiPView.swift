import AppKit
import SnapKit

final class DraggablePiPView: NSView {
    var onLayoutChanged: (() -> Void)?
    private var dragStartLocation: CGPoint = .zero
    private var originalFrame: CGRect = .zero

    init(contentView: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 20
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        addSubview(contentView)
        contentView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        guard let superview else { return }
        dragStartLocation = superview.convert(event.locationInWindow, from: nil)
        originalFrame = frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        let current = superview.convert(event.locationInWindow, from: nil)
        let dx = current.x - dragStartLocation.x
        let dy = current.y - dragStartLocation.y
        var next = originalFrame.offsetBy(dx: dx, dy: dy)
        next.origin.x = min(max(16, next.origin.x), max(16, superview.bounds.width - next.width - 16))
        next.origin.y = min(max(16, next.origin.y), max(16, superview.bounds.height - next.height - 16))
        frame = next
        onLayoutChanged?()
    }

    func normalizedLayout(in container: NSView) -> (center: CGPoint, size: CGSize, cornerRadius: CGFloat) {
        guard container.bounds.width > 0, container.bounds.height > 0 else {
            return (CGPoint(x: 0.82, y: 0.22), CGSize(width: 0.22, height: 0.22), layer?.cornerRadius ?? 0)
        }
        let center = CGPoint(x: frame.midX / container.bounds.width,
                             y: 1 - (frame.midY / container.bounds.height))
        let size = CGSize(width: frame.width / container.bounds.width,
                           height: frame.height / container.bounds.height)
        return (center, size, layer?.cornerRadius ?? 0)
    }
}

/// macOS 录制页中的可拖动字幕显示区域。
final class DraggableSubtitleView: NSView {
    /// 字幕区域位置发生变化后的归一化布局回调。
    var onLayoutChanged: ((SubtitleLayout) -> Void)?

    /// 字幕内容标签。
    private let subtitleLabel = NSTextField(labelWithString: "")
    /// 开始拖动时鼠标在父视图中的位置。
    private var dragStartLocation: CGPoint = .zero
    /// 开始拖动时字幕区域的原始位置。
    private var originalFrame: CGRect = .zero

    /// 创建字幕显示区域并配置外观与内部布局。
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.systemYellow.withAlphaComponent(0.5).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.32
        layer?.shadowRadius = 16
        layer?.shadowOffset = CGSize(width: 0, height: -4)

        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.cell?.wraps = true
        subtitleLabel.cell?.isScrollable = false
        addSubview(subtitleLabel)
        subtitleLabel.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 20))
        }
        showPlaceholder()
    }

    /// 不支持通过归档方式创建字幕区域。
    required init?(coder: NSCoder) { fatalError() }

    /// 记录拖动开始位置，并切换为闭合手型光标。
    override func mouseDown(with event: NSEvent) {
        guard let superview else { return }
        dragStartLocation = superview.convert(event.locationInWindow, from: nil)
        originalFrame = frame
        NSCursor.closedHand.push()
    }

    /// 根据鼠标位移更新字幕区域位置，并限制在预览画面范围内。
    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        let currentLocation = superview.convert(event.locationInWindow, from: nil)
        let horizontalOffset = currentLocation.x - dragStartLocation.x
        let verticalOffset = currentLocation.y - dragStartLocation.y
        frame = clampedFrame(originalFrame.offsetBy(dx: horizontalOffset, dy: verticalOffset), in: superview)
        onLayoutChanged?(normalizedLayout(in: superview))
    }

    /// 结束拖动后恢复普通手型光标。
    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()
        super.mouseUp(with: event)
    }

    /// 注册字幕区域的拖动提示光标。
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    /// 使用归一化布局在指定预览容器中放置字幕区域。
    func apply(layout: SubtitleLayout, in container: NSView) {
        guard container.bounds.width > 0, container.bounds.height > 0 else { return }
        let maximumWidth = max(180, container.bounds.width - 32)
        let preferredWidth = max(280, layout.maxWidth * container.bounds.width)
        let width = min(min(preferredWidth, 760), maximumWidth)
        let height = min(104, max(72, container.bounds.height - 32))
        let center = CGPoint(x: layout.center.x * container.bounds.width,
                             y: (1 - layout.center.y) * container.bounds.height)
        let proposedFrame = CGRect(x: center.x - width / 2,
                                   y: center.y - height / 2,
                                   width: width,
                                   height: height)
        frame = clampedFrame(proposedFrame, in: container)
    }

    /// 显示当前句字幕富文本。
    func showSubtitle(_ attributedText: NSAttributedString) {
        subtitleLabel.attributedStringValue = attributedText
        subtitleLabel.toolTip = attributedText.string
    }

    /// 清空当前句并展示等待语音的占位提示。
    func showPlaceholder() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        subtitleLabel.attributedStringValue = NSAttributedString(string: "等待语音字幕，可拖动调整位置", attributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5),
            .paragraphStyle: paragraph
        ])
        subtitleLabel.toolTip = "拖动字幕区域可以调整显示位置"
    }

    /// 返回字幕区域在指定容器中的归一化布局，供最终视频合成复用。
    func normalizedLayout(in container: NSView) -> SubtitleLayout {
        guard container.bounds.width > 0, container.bounds.height > 0 else { return SubtitleLayout() }
        return SubtitleLayout(center: CGPoint(x: frame.midX / container.bounds.width,
                                              y: 1 - frame.midY / container.bounds.height),
                              maxWidth: frame.width / container.bounds.width,
                              fontScale: 1)
    }

    /// 将字幕区域位置限制在预览容器内部，并保留安全边距。
    private func clampedFrame(_ proposedFrame: CGRect, in container: NSView) -> CGRect {
        var result = proposedFrame
        let margin: CGFloat = 16
        result.origin.x = min(max(margin, result.origin.x),
                              max(margin, container.bounds.width - result.width - margin))
        result.origin.y = min(max(margin, result.origin.y),
                              max(margin, container.bounds.height - result.height - margin))
        return result
    }
}
