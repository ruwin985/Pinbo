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
