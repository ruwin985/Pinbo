import AppKit
import SnapKit

/// 录屏内容选择页。
final class SourcePickerViewController: NSViewController {
    /// 用户确认录制目标后的回调。
    var onStartRecording: ((ScreenCaptureTarget) -> Void)?
    /// 用户点击返回按钮后的回调。
    var onBack: (() -> Void)?

    /// 录屏目标数据提供器。
    private let provider = ScreenCaptureTargetProvider()
    /// 内容滚动容器。
    private let scrollView = NSScrollView()
    /// 录屏目标网格容器。
    private let gridView = NSGridView()
    /// 页面标题标签。
    private let titleLabel = NSTextField(labelWithString: "选择录屏内容")
    /// 页面说明标签。
    private let subtitleLabel = NSTextField(labelWithString: "支持选择桌面、所有桌面中正在展示的 App 窗口，在开始录制页面支持打开电脑摄像头作为小窗口。")
    /// 刷新可录制内容按钮。
    private let refreshButton = NSButton(title: "刷新", target: nil, action: nil)
    /// 返回首页按钮。
    private let backButton = NSButton(title: "", target: nil, action: nil)
    /// 确认选择按钮。
    private let startButton = NSButton(title: "确认", target: nil, action: nil)
    /// 页面状态提示标签。
    private let statusLabel = NSTextField(labelWithString: "")

    /// 当前展示的录屏目标列表。
    private var targets: [ScreenCaptureTarget] = []
    /// 当前选中的录屏目标。
    private var selectedTarget: ScreenCaptureTarget?
    /// 当前已创建的卡片视图。
    private var cardViews: [SourceCardView] = []

    /// 创建基础视图。
    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    /// 页面加载后配置 UI 并读取录屏目标。
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadTargets()
    }

    /// 搭建选择页整体 UI。
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

    /// 刷新可录制桌面和所有桌面中正在展示的窗口。
    private func loadTargets() {
        statusLabel.stringValue = "正在读取所有桌面中正在展示的窗口…"
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
                    self.statusLabel.stringValue = "已找到 \(targets.count) 个可录制内容。点击窗口卡片会定位到对应桌面并显示蓝色边框。"
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

    /// 按固定列数渲染录屏目标网格。
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

    /// 更新当前选中的录屏目标。
    private func select(_ target: ScreenCaptureTarget) {
        selectedTarget = target
        for card in cardViews {
            card.isSelected = card.captureTarget == target
        }
        startButton.isEnabled = true
        if ScreenCaptureTargetHighlighter.shared.focusAndHighlight(target) {
            statusLabel.stringValue = "已定位：\(target.title)"
        } else {
            statusLabel.stringValue = "已选择：\(target.title)。如需定位具体窗口，请在系统设置中允许辅助功能权限。"
        }
    }

    /// 为所有卡片加载缩略图。
    private func loadVisibleThumbnails() {
        for card in cardViews {
            provider.loadThumbnail(for: card.captureTarget) { [weak card] image in
                card?.setThumbnail(image)
            }
        }
    }

    /// 响应刷新按钮点击。
    @objc private func refreshTapped() {
        loadTargets()
    }

    /// 响应返回按钮点击。
    @objc private func backTapped() {
        onBack?()
    }

    /// 响应确认按钮点击。
    @objc private func startTapped() {
        guard let selectedTarget else { return }
        onStartRecording?(selectedTarget)
    }
}

/// 单个录屏目标卡片。
final class SourceCardView: NSControl {
    /// 卡片绑定的录屏目标。
    let captureTarget: ScreenCaptureTarget
    /// 用户选中卡片后的回调。
    var onSelect: (() -> Void)?

    /// 缩略图视图。
    private let imageView = NSImageView()
    /// 应用或桌面图标视图。
    private let iconView = NSImageView()
    /// 标题标签。
    private let titleLabel = NSTextField(labelWithString: "")
    /// 副标题标签。
    private let subtitleLabel = NSTextField(labelWithString: "")
    /// 缩略图加载中的占位标签。
    private let placeholderLabel = NSTextField(labelWithString: "预览生成中…")

    /// 是否处于选中状态。
    var isSelected: Bool = false {
        didSet { updateSelection() }
    }

    /// 使用录屏目标创建卡片。
    init(target: ScreenCaptureTarget) {
        self.captureTarget = target
        super.init(frame: .zero)
        setupUI()
        configure(target)
    }

    /// 不支持从 Interface Builder 创建。
    required init?(coder: NSCoder) { fatalError() }

    /// 卡片期望尺寸。
    override var intrinsicContentSize: NSSize { NSSize(width: 260, height: 190) }

    /// 搭建卡片 UI。
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

    /// 用录屏目标填充卡片文本和图标。
    private func configure(_ target: ScreenCaptureTarget) {
        titleLabel.stringValue = target.title
        subtitleLabel.stringValue = target.subtitle ?? ""
        subtitleLabel.isHidden = target.subtitle == nil
        iconView.image = target.icon
    }

    /// 更新卡片缩略图。
    func setThumbnail(_ image: NSImage?) {
        imageView.image = image
        placeholderLabel.isHidden = image != nil
    }

    /// 鼠标点击卡片时触发选择。
    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    /// 配置鼠标悬停手型光标。
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// 根据选中状态更新卡片描边和背景。
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
