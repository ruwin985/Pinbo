import AppKit
import SnapKit

final class SourcePickerViewController: NSViewController {
    var onStartRecording: ((ScreenCaptureTarget) -> Void)?
    var onBack: (() -> Void)?

    private let provider = ScreenCaptureTargetProvider()
    private let scrollView = NSScrollView()
    private let gridView = NSGridView()
    private let titleLabel = NSTextField(labelWithString: "选择录屏内容")
    private let subtitleLabel = NSTextField(labelWithString: "支持选择已打开的桌面、具体 App 窗口，并打开电脑摄像头作为小窗口。")
    private let refreshButton = NSButton(title: "刷新", target: nil, action: nil)
    private let backButton = NSButton(title: "", target: nil, action: nil)
    private let startButton = NSButton(title: "确认", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    private var targets: [ScreenCaptureTarget] = []
    private var selectedTarget: ScreenCaptureTarget?
    private var cardViews: [SourceCardView] = []

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadTargets()
    }

    private func setupUI() {
        titleLabel.font = .systemFont(ofSize: 30, weight: .semibold)
        titleLabel.textColor = .labelColor
        subtitleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        subtitleLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor

        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .regular

        backButton.target = self
        backButton.action = #selector(backTapped)
        backButton.bezelStyle = .inline
        backButton.isBordered = false
        backButton.image = NSImage(named: "nav_back")
        backButton.image?.isTemplate = true
        backButton.imagePosition = .imageOnly
        backButton.imageScaling = .scaleProportionallyDown
        backButton.contentTintColor = .labelColor

        startButton.target = self
        startButton.action = #selector(startTapped)
        startButton.bezelStyle = .rounded
        startButton.controlSize = .regular
        startButton.bezelColor = .controlAccentColor
        startButton.keyEquivalent = "\r"
        startButton.isEnabled = false

        let titleStack = NSStackView(views: [backButton, titleLabel])
        titleStack.orientation = .horizontal
        titleStack.spacing = 10
        titleStack.alignment = .centerY

        let textStack = NSStackView(views: [titleStack, subtitleLabel])
        textStack.orientation = .vertical
        textStack.spacing = 6
        textStack.alignment = .leading

        let buttonStack = NSStackView(views: [refreshButton, startButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 10
        buttonStack.alignment = .centerY

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let topStack = NSStackView(views: [textStack, spacer, buttonStack])
        topStack.orientation = .horizontal
        topStack.alignment = .centerY
        topStack.distribution = .fill
        view.addSubview(topStack)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        view.addSubview(scrollView)

        gridView.rowSpacing = 28
        gridView.columnSpacing = 34
        gridView.xPlacement = .leading
        gridView.yPlacement = .top
        scrollView.documentView = gridView

        view.addSubview(statusLabel)

        topStack.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top).offset(28)
            make.leading.trailing.equalToSuperview().inset(42)
        }

        backButton.snp.makeConstraints { make in
            make.size.equalTo(28)
        }

        scrollView.snp.makeConstraints { make in
            make.top.equalTo(topStack.snp.bottom).offset(30)
            make.leading.trailing.equalToSuperview().inset(42)
            make.bottom.equalTo(statusLabel.snp.top).offset(-16)
        }

        statusLabel.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(42)
            make.bottom.equalTo(view.safeAreaLayoutGuide.snp.bottom).offset(-24)
        }

        gridView.snp.makeConstraints { make in
            make.top.leading.equalTo(scrollView.contentView)
            make.width.lessThanOrEqualTo(scrollView.contentView.snp.width)
        }
    }

    private func loadTargets() {
        statusLabel.stringValue = "正在读取可录制的桌面和应用窗口…"
        refreshButton.isEnabled = false
        startButton.isEnabled = false
        provider.loadTargets { [weak self] result in
            guard let self else { return }
            self.refreshButton.isEnabled = true
            switch result {
            case .success(let targets):
                self.targets = targets
                self.selectedTarget = targets.first
                self.renderGrid()
                if targets.isEmpty {
                    self.statusLabel.stringValue = "没有找到可录制内容。请确认已授予屏幕录制权限。"
                    MacPermissionAlert.show(kind: .screenRecording, in: self.view.window)
                } else {
                    self.statusLabel.stringValue = "已找到 \(targets.count) 个可录制内容。首次录屏时 macOS 可能会弹出屏幕录制授权。"
                }
            case .failure(let error):
                self.targets = []
                self.selectedTarget = nil
                self.renderGrid()
                self.statusLabel.stringValue = "读取失败：\(error.localizedDescription)。请在系统设置中允许屏幕录制权限。"
                MacPermissionAlert.show(kind: .screenRecording, in: self.view.window)
            }
        }
    }

    private func renderGrid() {
        while gridView.numberOfRows > 0 {
            gridView.removeRow(at: 0)
        }
        cardViews.removeAll()

        let columns = 3
        var rowViews: [NSView] = []
        for (index, target) in targets.enumerated() {
            let card = SourceCardView(target: target)
            card.isSelected = target == selectedTarget
            card.onSelect = { [weak self] in self?.select(target) }
            cardViews.append(card)
            rowViews.append(card)

            if rowViews.count == columns || index == targets.count - 1 {
                while rowViews.count < columns {
                    rowViews.append(NSView())
                }
                gridView.addRow(with: rowViews)
                rowViews.removeAll()
            }
        }
        startButton.isEnabled = selectedTarget != nil
        loadVisibleThumbnails()
    }

    private func select(_ target: ScreenCaptureTarget) {
        selectedTarget = target
        for card in cardViews {
            card.isSelected = card.captureTarget == target
        }
        startButton.isEnabled = true
    }

    private func loadVisibleThumbnails() {
        for card in cardViews {
            provider.loadThumbnail(for: card.captureTarget) { [weak card] image in
                card?.setThumbnail(image)
            }
        }
    }

    @objc private func refreshTapped() {
        loadTargets()
    }

    @objc private func backTapped() {
        onBack?()
    }

    @objc private func startTapped() {
        guard let selectedTarget else { return }
        onStartRecording?(selectedTarget)
    }
}

final class SourceCardView: NSControl {
    let captureTarget: ScreenCaptureTarget
    var onSelect: (() -> Void)?

    private let imageView = NSImageView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let placeholderLabel = NSTextField(labelWithString: "预览生成中…")

    var isSelected: Bool = false {
        didSet { updateSelection() }
    }

    init(target: ScreenCaptureTarget) {
        self.captureTarget = target
        super.init(frame: .zero)
        setupUI()
        configure(target)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 260, height: 190) }

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.96).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.25).cgColor
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.14).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 16
        layer?.shadowOffset = CGSize(width: 0, height: 4)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 12
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor.controlColor.withAlphaComponent(0.04).cgColor
        addSubview(imageView)

        placeholderLabel.font = .systemFont(ofSize: 13, weight: .medium)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        addSubview(placeholderLabel)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .controlAccentColor
        addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.lineBreakMode = .byTruncatingTail
        addSubview(subtitleLabel)

        snp.makeConstraints { make in
            make.width.equalTo(260)
            make.height.equalTo(190)
        }

        imageView.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(22)
            make.leading.trailing.equalToSuperview().inset(24)
            make.height.equalTo(104)
        }

        placeholderLabel.snp.makeConstraints { make in
            make.center.equalTo(imageView)
        }

        iconView.snp.makeConstraints { make in
            make.leading.top.equalToSuperview().inset(12)
            make.size.equalTo(32)
        }

        titleLabel.snp.makeConstraints { make in
            make.top.equalTo(imageView.snp.bottom).offset(16)
            make.leading.trailing.equalToSuperview().inset(14)
        }

        subtitleLabel.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(4)
            make.leading.trailing.equalToSuperview().inset(14)
        }
        updateSelection()
    }

    private func configure(_ target: ScreenCaptureTarget) {
        titleLabel.stringValue = target.title
        subtitleLabel.stringValue = target.subtitle ?? ""
        subtitleLabel.isHidden = target.subtitle == nil
        iconView.image = target.icon
    }

    func setThumbnail(_ image: NSImage?) {
        imageView.image = image
        placeholderLabel.isHidden = image != nil
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func updateSelection() {
        if isSelected {
            layer?.borderWidth = 2.5
            layer?.borderColor = NSColor.systemBlue.cgColor
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        } else {
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.25).cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.96).cgColor
        }
    }
}
