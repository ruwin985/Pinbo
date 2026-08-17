import UIKit
import SnapKit

final class TeleprompterPanelView: UIView {
    private enum Defaults {
        static let fontSize: Float = 28
        static let backgroundAlpha: Float = 0.5
        static let speedMultiplier: Float = 1.0
        static let horizontalInset: CGFloat = 16
    }

    private let backgroundBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let backgroundOverlayView = UIView()
    private let headerView = UIView()
    private let dragHandleView = UIView()
    private let headerSeparatorView = UIView()
    private let titleLabel = UILabel()
    private let deleteButton = UIButton(type: .custom)
    private let closeButton = UIButton(type: .custom)
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let controlsContainer = UIView()
    private let settingsToggleButton = UIButton(type: .system)
    private let controlsStack = UIStackView()
    private let fontSizeSlider = UISlider()
    private let backgroundAlphaSlider = UISlider()
    private let scrollSpeedSlider = UISlider()
    private let fontSizeValueLabel = UILabel()
    private let backgroundAlphaValueLabel = UILabel()
    private let scrollSpeedValueLabel = UILabel()
    private var backgroundAlphaRow: UIView?
    private var scrollSpeedRow: UIView?

    private var displayLink: CADisplayLink?
    private var lastScrollTime: CFTimeInterval = 0
    private var dragStartFrame: CGRect = .zero
    private var isSettingsExpanded = false

    var onClose: (() -> Void)?
    var maximumBottomY: CGFloat?
    private(set) var hasCustomPosition = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
        applyFontSize()
        applyBackgroundAlpha()
        applyScrollSpeedLabel()
        updatePlaceholderVisibility()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        stopAutoScroll()
    }

    func startAutoScroll() {
        guard !isHidden else { return }
        guard !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        endEditing(true)
        stopAutoScroll()
        lastScrollTime = 0
        let link = CADisplayLink(target: self, selector: #selector(handleScrollStep(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stopAutoScroll() {
        displayLink?.invalidate()
        displayLink = nil
        lastScrollTime = 0
    }

    func fitInsideSuperview() {
        guard let container = superview else { return }
        frame = clamped(frame: frame, in: container)
    }

    func dismissKeyboard() {
        endEditing(true)
    }
}

private extension TeleprompterPanelView {
    func setupUI() {
        backgroundColor = .clear
        layer.cornerRadius = 24
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.7
        layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 24
        layer.shadowOffset = CGSize(width: 0, height: 12)
        clipsToBounds = false

        backgroundBlurView.layer.cornerRadius = 24
        backgroundBlurView.layer.cornerCurve = .continuous
        backgroundBlurView.clipsToBounds = true
        addSubview(backgroundBlurView)

        backgroundOverlayView.layer.cornerRadius = 24
        backgroundOverlayView.layer.cornerCurve = .continuous
        backgroundOverlayView.clipsToBounds = true
        addSubview(backgroundOverlayView)

        headerView.backgroundColor = .clear
        addSubview(headerView)

        dragHandleView.backgroundColor = UIColor.white.withAlphaComponent(0.32)
        dragHandleView.layer.cornerRadius = 2
        dragHandleView.layer.cornerCurve = .continuous
        headerView.addSubview(dragHandleView)

        headerSeparatorView.backgroundColor = UIColor.white.withAlphaComponent(0.1)
        headerView.addSubview(headerSeparatorView)

        titleLabel.text = "提示词"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        headerView.addSubview(titleLabel)

//        deleteButton.setTitle("删除", for: .normal)
        deleteButton.setImage(UIImage(named: "delete_icon"), for: .normal)
//        deleteButton.tintColor = UIColor.systemRed.withAlphaComponent(0.92)
//        deleteButton.setTitleColor(UIColor.systemRed.withAlphaComponent(0.92), for: .normal)
//        deleteButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
//        deleteButton.backgroundColor = UIColor.white.withAlphaComponent(0.1)
//        deleteButton.layer.cornerRadius = 15
//        deleteButton.layer.cornerCurve = .continuous
//        deleteButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
//        deleteButton.semanticContentAttribute = .forceLeftToRight
        deleteButton.addTarget(self, action: #selector(deletePromptTapped), for: .touchUpInside)
        headerView.addSubview(deleteButton)

        closeButton.setImage(UIImage(named: "close_icon"), for: .normal)
//        closeButton.tintColor = UIColor.white.withAlphaComponent(0.86)
//        closeButton.backgroundColor = UIColor.white.withAlphaComponent(0.1)
//        closeButton.layer.cornerRadius = 15
//        closeButton.layer.cornerCurve = .continuous
        closeButton.contentEdgeInsets = UIEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        headerView.addSubview(closeButton)

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handleHeaderPan(_:)))
        panGesture.cancelsTouchesInView = false
        panGesture.delegate = self
        headerView.addGestureRecognizer(panGesture)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(headerTapped))
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = self
        headerView.addGestureRecognizer(tapGesture)

        textView.backgroundColor = .clear
        textView.textColor = .white
        textView.tintColor = .white
        textView.font = .systemFont(ofSize: CGFloat(Defaults.fontSize), weight: .semibold)
        textView.keyboardDismissMode = .interactive
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 18, left: 16, bottom: 18, right: 16)
        textView.delegate = self
        addSubview(textView)

        placeholderLabel.text = "点击输入拍摄时要朗读的提示词"
        placeholderLabel.textColor = UIColor.white.withAlphaComponent(0.38)
        placeholderLabel.font = .systemFont(ofSize: 17, weight: .regular)
        placeholderLabel.numberOfLines = 0
        textView.addSubview(placeholderLabel)

        controlsContainer.backgroundColor = UIColor.white.withAlphaComponent(0.07)
        controlsContainer.layer.cornerRadius = 18
        controlsContainer.layer.cornerCurve = .continuous
        controlsContainer.layer.borderWidth = 0.7
        controlsContainer.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        addSubview(controlsContainer)

        settingsToggleButton.setImage(UIImage(systemName: "chevron.up"), for: .normal)
        settingsToggleButton.tintColor = UIColor.white.withAlphaComponent(0.72)
        settingsToggleButton.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        settingsToggleButton.layer.cornerRadius = 11
        settingsToggleButton.layer.cornerCurve = .continuous
        settingsToggleButton.addTarget(self, action: #selector(settingsToggleTapped), for: .touchUpInside)
        controlsContainer.addSubview(settingsToggleButton)

        controlsStack.axis = .vertical
        controlsStack.spacing = 6
        controlsStack.isLayoutMarginsRelativeArrangement = true
        controlsStack.layoutMargins = UIEdgeInsets(top: 0, left: 12, bottom: 12, right: 12)
        controlsContainer.addSubview(controlsStack)

        configureSliders()
        let fontSizeRow = makeSliderRow(title: "提示词大小", slider: fontSizeSlider, valueLabel: fontSizeValueLabel)
        let alphaRow = makeSliderRow(title: "背景透明度", slider: backgroundAlphaSlider, valueLabel: backgroundAlphaValueLabel)
        let speedRow = makeSliderRow(title: "滚动速度", slider: scrollSpeedSlider, valueLabel: scrollSpeedValueLabel)
        backgroundAlphaRow = alphaRow
        scrollSpeedRow = speedRow
        controlsStack.addArrangedSubview(fontSizeRow)
        controlsStack.addArrangedSubview(alphaRow)
        controlsStack.addArrangedSubview(speedRow)
        applySettingsExpansion(animated: false)

        backgroundBlurView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        backgroundOverlayView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        headerView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(54)
        }

        dragHandleView.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(8)
            make.centerX.equalToSuperview()
            make.width.equalTo(36)
            make.height.equalTo(4)
        }

        titleLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(16)
            make.centerY.equalToSuperview().offset(4)
        }

        closeButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(12)
            make.centerY.equalTo(titleLabel.snp.centerY)
            make.size.equalTo(30)
        }

        deleteButton.snp.makeConstraints { make in
            make.trailing.equalTo(closeButton.snp.leading).offset(-8)
            make.centerY.equalTo(titleLabel.snp.centerY)
            make.size.equalTo(30)
        }

        headerSeparatorView.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
            make.height.equalTo(1 / UIScreen.main.scale)
        }

        textView.snp.makeConstraints { make in
            make.top.equalTo(headerView.snp.bottom)
            make.leading.trailing.equalToSuperview().inset(4)
            make.bottom.equalTo(controlsContainer.snp.top).offset(-10)
        }

        placeholderLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(18)
            make.leading.equalToSuperview().offset(19)
            make.trailing.equalToSuperview().inset(19)
        }

        controlsContainer.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview().inset(12)
        }

        settingsToggleButton.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(8)
            make.centerX.equalToSuperview()
            make.width.equalTo(52)
            make.height.equalTo(22)
        }

        controlsStack.snp.makeConstraints { make in
            make.top.equalTo(settingsToggleButton.snp.bottom).offset(4)
            make.leading.trailing.bottom.equalToSuperview()
        }
    }

    func configureSliders() {
        fontSizeSlider.minimumValue = 20
        fontSizeSlider.maximumValue = 42
        fontSizeSlider.value = Defaults.fontSize
        fontSizeSlider.addTarget(self, action: #selector(fontSizeChanged), for: .valueChanged)

        backgroundAlphaSlider.minimumValue = 0
        backgroundAlphaSlider.maximumValue = 1
        backgroundAlphaSlider.value = Defaults.backgroundAlpha
        backgroundAlphaSlider.addTarget(self, action: #selector(backgroundAlphaChanged), for: .valueChanged)

        scrollSpeedSlider.minimumValue = 0.5
        scrollSpeedSlider.maximumValue = 1.5
        scrollSpeedSlider.value = Defaults.speedMultiplier
        scrollSpeedSlider.addTarget(self, action: #selector(scrollSpeedChanged), for: .valueChanged)

        [fontSizeSlider, backgroundAlphaSlider, scrollSpeedSlider].forEach { slider in
            slider.setMinimumTrackImage(makeSliderTrackImage(color: UIColor.white.withAlphaComponent(0.82)), for: .normal)
            slider.setMaximumTrackImage(makeSliderTrackImage(color: UIColor.white.withAlphaComponent(0.16)), for: .normal)
            slider.setThumbImage(makeSliderThumbImage(), for: .normal)
            slider.setThumbImage(makeSliderThumbImage(diameter: 20), for: .highlighted)
        }
    }

    func makeSliderRow(title: String, slider: UISlider, valueLabel: UILabel) -> UIView {
        let rowContainer = UIView()
        rowContainer.backgroundColor = UIColor.white.withAlphaComponent(0.055)
        rowContainer.layer.cornerRadius = 14
        rowContainer.layer.cornerCurve = .continuous

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.textColor = UIColor.white.withAlphaComponent(0.76)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)

        valueLabel.textColor = UIColor.white.withAlphaComponent(0.58)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        valueLabel.textAlignment = .right

        let labelRow = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        labelRow.axis = .horizontal
        labelRow.alignment = .center
        labelRow.spacing = 8

        let contentStack = UIStackView(arrangedSubviews: [labelRow, slider])
        contentStack.axis = .vertical
        contentStack.spacing = 2
        rowContainer.addSubview(contentStack)

        contentStack.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(12)
            make.top.bottom.equalToSuperview().inset(7)
        }

        valueLabel.snp.makeConstraints { make in
            make.width.equalTo(48)
        }

        slider.snp.makeConstraints { make in
            make.height.equalTo(24)
        }

        rowContainer.snp.makeConstraints { make in
            make.height.equalTo(52)
        }
        return rowContainer
    }

    func makeSliderTrackImage(color: UIColor) -> UIImage {
        let height: CGFloat = 4
        let size = CGSize(width: height, height: height)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            color.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: height / 2).fill()
        }
        return image.resizableImage(withCapInsets: UIEdgeInsets(top: 0, left: height / 2, bottom: 0, right: height / 2))
    }

    func makeSliderThumbImage(diameter: CGFloat = 18) -> UIImage {
        let padding: CGFloat = 5
        let size = CGSize(width: diameter + padding * 2, height: diameter + padding * 2)
        return UIGraphicsImageRenderer(size: size).image { context in
            let rect = CGRect(x: padding, y: padding, width: diameter, height: diameter)
            context.cgContext.setShadow(offset: CGSize(width: 0, height: 2), blur: 5, color: UIColor.black.withAlphaComponent(0.28).cgColor)
            UIColor.white.setFill()
            UIBezierPath(ovalIn: rect).fill()
        }
    }

    func updatePlaceholderVisibility() {
        placeholderLabel.isHidden = !textView.text.isEmpty
    }

    func applyFontSize() {
        let fontSize = CGFloat(round(fontSizeSlider.value))
        textView.font = .systemFont(ofSize: fontSize, weight: .semibold)
        fontSizeValueLabel.text = "\(Int(fontSize))"
    }

    func applyBackgroundAlpha() {
        let alphaValue = CGFloat(backgroundAlphaSlider.value)
        backgroundOverlayView.backgroundColor = UIColor.black.withAlphaComponent(alphaValue)
        backgroundBlurView.alpha = min(1, alphaValue * 1.25)
        backgroundAlphaValueLabel.text = "\(Int(round(alphaValue * 100)))%"
    }

    func applySettingsExpansion(animated: Bool) {
        backgroundAlphaRow?.isHidden = !isSettingsExpanded
        scrollSpeedRow?.isHidden = !isSettingsExpanded
        let symbolName = isSettingsExpanded ? "chevron.down" : "chevron.up"
        settingsToggleButton.setImage(UIImage(systemName: symbolName), for: .normal)
        let animations = {
            self.layoutIfNeeded()
            self.superview?.layoutIfNeeded()
        }
        if animated {
            UIView.animate(withDuration: 0.28,
                           delay: 0,
                           usingSpringWithDamping: 0.9,
                           initialSpringVelocity: 0.35,
                           options: [.beginFromCurrentState, .allowUserInteraction]) {
                animations()
            }
        } else {
            animations()
        }
    }

    func applyScrollSpeedLabel() {
        let multiplier = scrollSpeedSlider.value
        if abs(multiplier - Defaults.speedMultiplier) < 0.05 {
            scrollSpeedValueLabel.text = "正常"
        } else {
            scrollSpeedValueLabel.text = String(format: "%.1fx", multiplier)
        }
    }

    func clamped(frame proposedFrame: CGRect, in container: UIView) -> CGRect {
        var nextFrame = proposedFrame
        let safeInsets = container.safeAreaInsets
        let minimumX = Defaults.horizontalInset
        let maximumX = max(minimumX, container.bounds.width - proposedFrame.width - Defaults.horizontalInset)
        let minimumY = safeInsets.top + 4
        let safeBottomY = container.bounds.height - safeInsets.bottom - Defaults.horizontalInset
        let maximumBottom = min(safeBottomY, maximumBottomY ?? safeBottomY)
        let maximumY = max(minimumY, maximumBottom - proposedFrame.height)
        nextFrame.origin.x = min(max(proposedFrame.origin.x, minimumX), maximumX)
        nextFrame.origin.y = min(max(proposedFrame.origin.y, minimumY), maximumY)
        return nextFrame
    }

    @objc func deletePromptTapped() {
        stopAutoScroll()
        textView.text = ""
        textView.setContentOffset(.zero, animated: false)
        updatePlaceholderVisibility()
    }

    @objc func closeTapped() {
        stopAutoScroll()
        endEditing(true)
        onClose?()
    }

    @objc func fontSizeChanged() {
        applyFontSize()
    }

    @objc func backgroundAlphaChanged() {
        applyBackgroundAlpha()
    }

    @objc func scrollSpeedChanged() {
        applyScrollSpeedLabel()
    }

    @objc func settingsToggleTapped() {
        isSettingsExpanded.toggle()
        applySettingsExpansion(animated: true)
    }

    @objc func headerTapped() {
        dismissKeyboard()
    }

    @objc func handleHeaderPan(_ gesture: UIPanGestureRecognizer) {
        guard let container = superview else { return }
        switch gesture.state {
        case .began:
            hasCustomPosition = true
            dragStartFrame = frame
        case .changed:
            let translation = gesture.translation(in: container)
            let proposedFrame = dragStartFrame.offsetBy(dx: translation.x, dy: translation.y)
            frame = clamped(frame: proposedFrame, in: container)
        case .ended, .cancelled, .failed:
            frame = clamped(frame: frame, in: container)
        default:
            break
        }
    }

    @objc func handleScrollStep(_ link: CADisplayLink) {
        guard textView.bounds.height > 0 else { return }
        if lastScrollTime == 0 {
            lastScrollTime = link.timestamp
            return
        }

        let elapsed = link.timestamp - lastScrollTime
        lastScrollTime = link.timestamp
        let minimumOffsetY = -textView.adjustedContentInset.top
        let maximumOffsetY = max(minimumOffsetY,
                                 textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom)
        guard maximumOffsetY > minimumOffsetY else {
            stopAutoScroll()
            return
        }

        let lineHeight = textView.font?.lineHeight ?? CGFloat(Defaults.fontSize * 1.2)
        let pointsPerSecond = max(6, lineHeight / 3 * CGFloat(scrollSpeedSlider.value))
        let currentOffsetY = max(textView.contentOffset.y, minimumOffsetY)
        let nextOffsetY = min(maximumOffsetY, currentOffsetY + pointsPerSecond * CGFloat(elapsed))
        textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: nextOffsetY), animated: false)

        if nextOffsetY >= maximumOffsetY {
            stopAutoScroll()
        }
    }
}

extension TeleprompterPanelView: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        updatePlaceholderVisibility()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        dismissKeyboard()
    }
}

extension TeleprompterPanelView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var touchedView = touch.view
        while let currentView = touchedView, currentView !== headerView {
            if currentView is UIControl { return false }
            touchedView = currentView.superview
        }
        return true
    }
}
