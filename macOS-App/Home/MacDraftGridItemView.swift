import AppKit
import AVFoundation
import SnapKit

final class MacDraftGridItemView: NSControl {
    static let itemSize = CGSize(width: 170, height: 226)

    var onOpen: (() -> Void)?
    var onDelete: (() -> Void)?

    private let thumbnailLayer = CALayer()
    private let titleLabel = NSTextField(labelWithString: "")
    private let durationLabel = NSTextField(labelWithString: "")
    private let tagLabel = NSTextField(labelWithString: "草稿")
    private let deleteButton = NSButton(title: "", target: nil, action: nil)
    private var currentID: UUID?

    var isEditingDrafts = false {
        didSet { deleteButton.isHidden = !isEditingDrafts }
    }

    init(project: RecordingProject) {
        super.init(frame: CGRect(origin: .zero, size: Self.itemSize))
        setupUI()
        configure(with: project)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { Self.itemSize }

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.96).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.25).cgColor
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.16).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 16
        layer?.shadowOffset = CGSize(width: 0, height: 4)

        let thumbnailView = NSView()
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 13
        thumbnailView.layer?.cornerCurve = .continuous
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.layer?.backgroundColor = NSColor.controlColor.withAlphaComponent(0.04).cgColor
        thumbnailView.layer?.addSublayer(thumbnailLayer)
        addSubview(thumbnailView)

        tagLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        tagLabel.textColor = .white
        tagLabel.alignment = .center
        tagLabel.wantsLayer = true
        tagLabel.layer?.cornerRadius = 5
        tagLabel.layer?.cornerCurve = .continuous
        tagLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        thumbnailView.addSubview(tagLabel)

        durationLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        durationLabel.textColor = .white
        durationLabel.alignment = .center
        durationLabel.wantsLayer = true
        durationLabel.layer?.cornerRadius = 5
        durationLabel.layer?.cornerCurve = .continuous
        durationLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        thumbnailView.addSubview(durationLabel)

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        deleteButton.image = NSImage(named: "close_icon") //NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
//        deleteButton.contentTintColor = .systemRed
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.isHidden = true
        deleteButton.isBordered = false
        addSubview(deleteButton)

        snp.makeConstraints { make in
            make.width.equalTo(Self.itemSize.width)
            make.height.equalTo(Self.itemSize.height)
        }

        thumbnailView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(190)
        }

        tagLabel.snp.makeConstraints { make in
            make.trailing.bottom.equalToSuperview().inset(8)
            make.width.equalTo(38)
            make.height.equalTo(20)
        }

        durationLabel.snp.makeConstraints { make in
            make.leading.bottom.equalToSuperview().inset(8)
            make.height.equalTo(20)
            make.width.greaterThanOrEqualTo(48)
        }

        titleLabel.snp.makeConstraints { make in
            make.top.equalTo(thumbnailView.snp.bottom).offset(10)
            make.leading.trailing.equalToSuperview().inset(2)
        }

        deleteButton.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(4)
            make.trailing.equalToSuperview().offset(-4)
            make.size.equalTo(20)
        }

        thumbnailView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                               object: thumbnailView,
                                               queue: .main) { [weak self, weak thumbnailView] _ in
            guard let self, let thumbnailView else { return }
            self.thumbnailLayer.frame = thumbnailView.bounds
        }
    }

    func configure(with project: RecordingProject) {
        currentID = project.id
        tagLabel.isHidden = !project.isDraft
        titleLabel.stringValue = Self.title(for: project)
        let duration = Int(project.duration.rounded())
        durationLabel.stringValue = String(format: " %02d:%02d ", duration / 60, duration % 60)
        thumbnailLayer.contents = nil
        guard let url = project.mainVideoURL else { return }
        let targetID = project.id
        DispatchQueue.global(qos: .userInitiated).async {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 420, height: 420)
            let image = try? generator.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil)
            DispatchQueue.main.async {
                if self.currentID == targetID {
                    self.thumbnailLayer.contentsGravity = .resizeAspectFill
                    self.thumbnailLayer.contents = image
                }
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        if isEditingDrafts { return }
        onOpen?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onDelete?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    @objc private func deleteTapped() {
        onDelete?()
    }

    private static func title(for project: RecordingProject) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "今天 HH:mm"
        if !Calendar.current.isDateInToday(project.createdAt) {
            formatter.dateFormat = "M月d日 HH:mm"
        }
        return formatter.string(from: project.createdAt)
    }
}
