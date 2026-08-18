import AppKit
import AVFoundation
import SnapKit

final class MacHomeViewController: NSViewController {
    var onOpenScreenRecording: (() -> Void)?
    var onOpenDraft: ((RecordingProject) -> Void)?

    private let headerBar = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "我的作品")
    private let editButton = NSButton(title: "编辑", target: nil, action: nil)
    private let screenRecordButton = NSButton(title: "去录制", target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let gridContainer = FlippedDocumentView()
    private let emptyStateLabel = NSTextField(labelWithString: "暂无作品，点击右上角去录制开始录屏吧~")

    private var drafts: [RecordingProject] = []
    private var cardViews: [MacDraftGridItemView] = []
    private var isEditingDrafts = false
    private var renderedColumnCount = 0

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        reloadDrafts()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadDrafts()
    }

    func reloadDrafts() {
        drafts = DraftStore.shared.loadAll()
        renderGrid()
    }

    private func setupUI() {
        headerBar.material = .headerView
        headerBar.blendingMode = .withinWindow
        headerBar.state = .active
        view.addSubview(headerBar)

        titleLabel.font = .systemFont(ofSize: 26, weight: .semibold)
        titleLabel.textColor = .labelColor

        editButton.target = self
        editButton.action = #selector(editTapped)
        editButton.bezelStyle = .rounded
        editButton.controlSize = .regular
        editButton.isEnabled = false

        screenRecordButton.target = self
        screenRecordButton.action = #selector(screenRecordTapped)
        screenRecordButton.bezelStyle = .rounded
        screenRecordButton.controlSize = .regular
        screenRecordButton.bezelColor = .controlAccentColor
        screenRecordButton.image = NSImage(systemSymbolName: "video.badge.plus", accessibilityDescription: nil)
        screenRecordButton.imagePosition = .imageLeading

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let headerStack = NSStackView(views: [titleLabel, spacer, editButton, screenRecordButton])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 14
        headerBar.addSubview(headerStack)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        view.addSubview(scrollView)

        scrollView.documentView = gridContainer

        emptyStateLabel.font = .systemFont(ofSize: 15, weight: .medium)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.alignment = .center
        view.addSubview(emptyStateLabel)

        headerBar.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(80)
        }

        headerStack.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(32)
            make.bottom.equalToSuperview().inset(16)
        }

        scrollView.snp.makeConstraints { make in
            make.top.equalTo(headerBar.snp.bottom).offset(30)
            make.leading.trailing.equalToSuperview().inset(42)
            make.bottom.equalToSuperview().inset(34)
        }

        emptyStateLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
    }

    private func renderGrid() {
        gridContainer.subviews.forEach { $0.removeFromSuperview() }
        cardViews.removeAll()

        let columns = currentColumnCount()
        renderedColumnCount = columns
        let columnSpacing: CGFloat = 24
        let rowSpacing: CGFloat = 28
        for (index, project) in drafts.enumerated() {
            let card = MacDraftGridItemView(project: project)
            card.isEditingDrafts = isEditingDrafts
            card.onOpen = { [weak self] in self?.onOpenDraft?(project) }
            card.onDelete = { [weak self] in self?.deleteDraft(project) }
            cardViews.append(card)
            gridContainer.addSubview(card)

            let column = index % columns
            let row = index / columns
            card.frame = CGRect(x: CGFloat(column) * (MacDraftGridItemView.itemSize.width + columnSpacing),
                                y: CGFloat(row) * (MacDraftGridItemView.itemSize.height + rowSpacing),
                                width: MacDraftGridItemView.itemSize.width,
                                height: MacDraftGridItemView.itemSize.height)
        }

        let rowCount = drafts.isEmpty ? 1 : Int(ceil(Double(drafts.count) / Double(columns)))
        let contentHeight = CGFloat(rowCount) * MacDraftGridItemView.itemSize.height + CGFloat(max(0, rowCount - 1)) * rowSpacing
        gridContainer.frame = CGRect(origin: .zero,
                                     size: CGSize(width: scrollView.contentView.bounds.width,
                                                  height: max(scrollView.contentView.bounds.height, contentHeight)))
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        emptyStateLabel.isHidden = !drafts.isEmpty
        editButton.isEnabled = !drafts.isEmpty
        editButton.title = isEditingDrafts ? "完成" : "编辑"
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let columns = currentColumnCount()
        if columns != renderedColumnCount {
            renderGrid()
        } else {
            gridContainer.setFrameSize(CGSize(width: scrollView.contentView.bounds.width,
                                              height: max(gridContainer.frame.height, scrollView.contentView.bounds.height)))
        }
    }

    private func currentColumnCount() -> Int {
        max(1, Int((view.bounds.width - 84 + 24) / (MacDraftGridItemView.itemSize.width + 24)))
    }

    @objc private func editTapped() {
        isEditingDrafts.toggle()
        for card in cardViews { card.isEditingDrafts = isEditingDrafts }
        editButton.title = isEditingDrafts ? "完成" : "编辑"
    }

    @objc private func screenRecordTapped() {
        isEditingDrafts = false
        onOpenScreenRecording?()
    }

    private func deleteDraft(_ project: RecordingProject) {
        let alert = NSAlert()
        alert.messageText = "删除作品？"
        alert.informativeText = "删除后无法恢复，确定要删除这个作品吗？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        let runDelete: () -> Void = { [weak self] in
            guard let self else { return }
            do {
                try DraftStore.shared.delete(project.id)
                self.drafts.removeAll { $0.id == project.id }
                if self.drafts.isEmpty { self.isEditingDrafts = false }
                self.renderGrid()
            } catch {
                self.showDeleteError(error)
            }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { runDelete() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            runDelete()
        }
    }

    private func showDeleteError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "删除失败"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.addButton(withTitle: "好")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
