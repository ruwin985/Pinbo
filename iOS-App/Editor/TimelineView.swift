import UIKit
import SnapKit

/// 简化剪辑时间轴：时间刻度 + 视频轨道 + 字幕轨道 + 左右裁剪手柄。
final class TimelineView: UIView {

    var pixelsPerSecond: CGFloat = 90
    var duration: TimeInterval = 0 { didSet { normalizeTrimRange(); setNeedsLayout() } }
    var videoThumbnails: [UIImage] = [] { didSet { setNeedsLayout(); layoutIfNeeded() } }
    var subtitleSegments: [SubtitleSegment] = [] { didSet { setNeedsLayout(); layoutIfNeeded() } }

    var trimStart: TimeInterval = 0 {
        didSet {
            guard !updatingTrimRange else { return }
            normalizeTrimRange()
            setNeedsLayout()
        }
    }
    var trimEnd: TimeInterval = 0 {
        didSet {
            guard !updatingTrimRange else { return }
            normalizeTrimRange()
            setNeedsLayout()
        }
    }

    var onSeek: ((TimeInterval) -> Void)?
    var onTrimChanged: ((TimeInterval, TimeInterval) -> Void)?
    var onSubtitleTapped: ((UUID) -> Void)?

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let rulerView = UIView()
    private let videoTrack = UIView()
    private let subtitleTrack = UIView()
    private let selectionView = UIView()
    private let leftTrimOverlay = UIView()
    private let rightTrimOverlay = UIView()
    private let leftHandle = TrimHandleView(side: .left)
    private let rightHandle = TrimHandleView(side: .right)
    private let playhead = UIView()

    private let rulerHeight: CGFloat = 22
    private let videoHeight: CGFloat = 72
    private let subtitleHeight: CGFloat = 30
    private let gap: CGFloat = 8
    private let handleWidth: CGFloat = 18
    private let minTrimDuration: TimeInterval = 0.5

    private var leadInset: CGFloat { bounds.width / 2 }
    private var suppressSeek = false
    private var updatingTrimRange = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        backgroundColor = UIColor(white: 0.08, alpha: 1)

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.delegate = self
        addSubview(scrollView)
        scrollView.addSubview(contentView)
        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        videoTrack.backgroundColor = UIColor(white: 0.2, alpha: 1)
        videoTrack.layer.cornerRadius = 4
        videoTrack.clipsToBounds = true

        subtitleTrack.backgroundColor = UIColor(white: 0.14, alpha: 1)
        subtitleTrack.layer.cornerRadius = 4
        subtitleTrack.clipsToBounds = true

        selectionView.layer.borderColor = UIColor.white.cgColor
        selectionView.layer.borderWidth = 3
        selectionView.layer.cornerRadius = 6
        selectionView.isUserInteractionEnabled = false

        leftTrimOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        rightTrimOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        leftTrimOverlay.isUserInteractionEnabled = false
        rightTrimOverlay.isUserInteractionEnabled = false

        [rulerView, videoTrack, subtitleTrack, leftTrimOverlay, rightTrimOverlay, selectionView, leftHandle, rightHandle].forEach {
            contentView.addSubview($0)
        }

        playhead.backgroundColor = .white
        playhead.isUserInteractionEnabled = false
        addSubview(playhead)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        contentView.addGestureRecognizer(tap)
        leftHandle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleLeftTrim(_:))))
        rightHandle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleRightTrim(_:))))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        normalizeTrimRange()

        let trackWidth = CGFloat(duration) * pixelsPerSecond
        let contentWidth = leadInset * 2 + trackWidth
        let totalHeight = rulerHeight + videoHeight + subtitleHeight + gap * 2 + 12
        contentView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: totalHeight)
        scrollView.contentSize = contentView.frame.size

        rulerView.frame = CGRect(x: leadInset, y: 4, width: trackWidth, height: rulerHeight)
        videoTrack.frame = CGRect(x: leadInset, y: rulerView.frame.maxY + gap, width: trackWidth, height: videoHeight)
        subtitleTrack.frame = CGRect(x: leadInset, y: videoTrack.frame.maxY + gap, width: trackWidth, height: subtitleHeight)

        layoutRuler()
        layoutThumbnails()
        layoutSubtitles()
        layoutTrimViews()

        playhead.frame = CGRect(x: bounds.midX - 1, y: 0, width: 2, height: bounds.height)
    }

    private func layoutRuler() {
        rulerView.subviews.forEach { $0.removeFromSuperview() }
        guard duration > 0 else { return }
        let secs = Int(ceil(duration))
        for second in 0...secs {
            let x = CGFloat(second) * pixelsPerSecond
            let label = UILabel()
            label.text = String(format: "%02d:%02d", second / 60, second % 60)
            label.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            label.textColor = UIColor(white: 0.7, alpha: 1)
            label.sizeToFit()
            label.center = CGPoint(x: x, y: rulerHeight / 2)
            rulerView.addSubview(label)
        }
    }

    private func layoutThumbnails() {
        videoTrack.subviews.forEach { $0.removeFromSuperview() }
        guard !videoThumbnails.isEmpty, videoTrack.bounds.width > 0 else { return }
        let width = videoTrack.bounds.width / CGFloat(videoThumbnails.count)
        for (index, image) in videoThumbnails.enumerated() {
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.frame = CGRect(x: CGFloat(index) * width, y: 0, width: width, height: videoHeight)
            videoTrack.addSubview(imageView)
        }
    }

    private func layoutSubtitles() {
        subtitleTrack.subviews.forEach { $0.removeFromSuperview() }
        guard duration > 0 else { return }

        for segment in subtitleSegments {
            let start = clamped(segment.startTime, lower: 0, upper: duration)
            let end = clamped(max(segment.endTime, start), lower: 0, upper: duration)
            let width = max(2, CGFloat(end - start) * pixelsPerSecond)
            let x = CGFloat(start) * pixelsPerSecond

            let label = UILabel(frame: CGRect(x: x, y: 3, width: width, height: subtitleHeight - 6))
            label.backgroundColor = UIColor(red: 0.16, green: 0.42, blue: 0.95, alpha: 0.9)
            label.layer.cornerRadius = 4
            label.clipsToBounds = true
            label.text = segment.text.isEmpty ? "字幕" : segment.text
            label.textColor = .white
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.lineBreakMode = .byTruncatingTail
            label.textAlignment = .center
            subtitleTrack.addSubview(label)
        }
    }

    private func layoutTrimViews() {
        guard duration > 0 else { return }
        let startX = leadInset + CGFloat(trimStart) * pixelsPerSecond
        let endX = leadInset + CGFloat(trimEnd) * pixelsPerSecond
        let trackSelectionMinY = videoTrack.frame.minY
        let trackSelectionHeight = subtitleTrack.frame.maxY - videoTrack.frame.minY
        let selectionFrame = CGRect(x: startX, y: trackSelectionMinY, width: max(0, endX - startX), height: trackSelectionHeight)
        selectionView.frame = selectionFrame
        leftTrimOverlay.frame = CGRect(x: leadInset, y: trackSelectionMinY, width: max(0, startX - leadInset), height: trackSelectionHeight)
        rightTrimOverlay.frame = CGRect(x: endX, y: trackSelectionMinY, width: max(0, videoTrack.frame.maxX - endX), height: trackSelectionHeight)
        leftHandle.frame = CGRect(x: startX - handleWidth / 2, y: trackSelectionMinY - 3, width: handleWidth, height: trackSelectionHeight + 6)
        rightHandle.frame = CGRect(x: endX - handleWidth / 2, y: trackSelectionMinY - 3, width: handleWidth, height: trackSelectionHeight + 6)
        contentView.bringSubviewToFront(leftTrimOverlay)
        contentView.bringSubviewToFront(rightTrimOverlay)
        contentView.bringSubviewToFront(selectionView)
        contentView.bringSubviewToFront(leftHandle)
        contentView.bringSubviewToFront(rightHandle)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: contentView)
        if subtitleTrack.frame.contains(point) {
            let localX = point.x - subtitleTrack.frame.minX
            if let segment = subtitleSegments.first(where: { segment in
                let start = clamped(segment.startTime, lower: 0, upper: duration)
                let end = clamped(max(segment.endTime, start), lower: 0, upper: duration)
                let startX = CGFloat(start) * pixelsPerSecond
                let endX = CGFloat(end) * pixelsPerSecond
                return localX >= startX && localX <= endX
            }) {
                onSubtitleTapped?(segment.id)
                return
            }
        }

        let x = gesture.location(in: contentView).x - leadInset
        let time = clamped(TimeInterval(x / pixelsPerSecond), lower: trimStart, upper: trimEnd)
        onSeek?(time)
    }

    @objc private func handleLeftTrim(_ gesture: UIPanGestureRecognizer) {
        guard duration > 0 else { return }
        let translation = gesture.translation(in: contentView).x
        gesture.setTranslation(.zero, in: contentView)
        let minimumDuration = min(minTrimDuration, duration)
        trimStart = clamped(trimStart + TimeInterval(translation / pixelsPerSecond), lower: 0, upper: trimEnd - minimumDuration)
        notifyTrimChanged()
        if gesture.state == .began || gesture.state == .changed { onSeek?(trimStart) }
    }

    @objc private func handleRightTrim(_ gesture: UIPanGestureRecognizer) {
        guard duration > 0 else { return }
        let translation = gesture.translation(in: contentView).x
        gesture.setTranslation(.zero, in: contentView)
        let minimumDuration = min(minTrimDuration, duration)
        trimEnd = clamped(trimEnd + TimeInterval(translation / pixelsPerSecond), lower: trimStart + minimumDuration, upper: duration)
        notifyTrimChanged()
        if gesture.state == .began || gesture.state == .changed { onSeek?(trimEnd) }
    }

    private func notifyTrimChanged() {
        onTrimChanged?(trimStart, trimEnd)
    }

    private func normalizeTrimRange() {
        updatingTrimRange = true
        defer { updatingTrimRange = false }
        guard duration > 0 else {
            trimStart = 0
            trimEnd = 0
            return
        }
        if trimEnd <= 0 || trimEnd > duration { trimEnd = duration }
        let minimumDuration = min(minTrimDuration, duration)
        trimStart = clamped(trimStart, lower: 0, upper: max(0, trimEnd - minimumDuration))
        trimEnd = clamped(trimEnd, lower: min(duration, trimStart + minimumDuration), upper: duration)
    }

    func updatePlayhead(currentTime: TimeInterval) {
        suppressSeek = true
        let offset = CGFloat(clamped(currentTime, lower: 0, upper: duration)) * pixelsPerSecond
        scrollView.setContentOffset(CGPoint(x: offset, y: 0), animated: false)
        suppressSeek = false
    }

    private func clamped(_ value: TimeInterval, lower: TimeInterval, upper: TimeInterval) -> TimeInterval {
        guard upper >= lower else { return lower }
        return min(max(value, lower), upper)
    }
}

extension TimelineView: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !suppressSeek, (scrollView.isTracking || scrollView.isDecelerating) else { return }
        let time = max(0, min(TimeInterval(scrollView.contentOffset.x / pixelsPerSecond), duration))
        onSeek?(time)
    }
}

private final class TrimHandleView: UIView {
    enum Side { case left, right }

    private let grip = UIView()

    init(side: Side) {
        super.init(frame: .zero)
        backgroundColor = .white
        layer.cornerRadius = 5
        layer.maskedCorners = side == .left ? [.layerMinXMinYCorner, .layerMinXMaxYCorner] : [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        setupGrip()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupGrip() {
        grip.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        grip.layer.cornerRadius = 1
        addSubview(grip)
        grip.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.width.equalTo(2)
            make.height.equalTo(24)
        }
    }
}
