import AppKit
import SnapKit

/// macOS 录制参数浮窗，负责选择屏幕录制的分辨率和帧速率。
final class MacRecordingParameterViewController: NSViewController {
    /// 参数变化回调，由录制页负责应用到采集源。
    var onChange: ((MacRecordingSettings) -> Void)?
    /// 是否允许继续编辑参数。
    var isInteractionEnabled = true {
        didSet {
            resolutionControl.isEnabled = isInteractionEnabled
            frameRateControl.isEnabled = isInteractionEnabled
        }
    }

    /// 当前正在编辑的录制参数。
    private var settings: MacRecordingSettings
    /// 当前录制目标支持的分辨率选项。
    private let availableResolutions: [MacRecordingResolution]
    /// 分辨率选择控件。
    private let resolutionControl: NSPopUpButton
    /// 帧速率选择控件。
    private let frameRateControl: NSSegmentedControl

    /// 使用当前参数和录制目标支持的分辨率创建参数浮窗。
    init(settings: MacRecordingSettings,
         availableResolutions: [MacRecordingResolution]) {
        self.settings = settings
        self.availableResolutions = availableResolutions
        let resolutionControl = NSPopUpButton(frame: .zero, pullsDown: false)
        resolutionControl.addItems(withTitles: availableResolutions.map { $0.displayName })
        self.resolutionControl = resolutionControl
        self.frameRateControl = NSSegmentedControl(labels: MacRecordingSettings.supportedFrameRates.map { $0.displayName },
                                                   trackingMode: .selectOne,
                                                   target: nil,
                                                   action: nil)
        super.init(nibName: nil, bundle: nil)
    }

    /// 不支持从 storyboard 反序列化参数浮窗。
    required init?(coder: NSCoder) {
        fatalError("参数浮窗不支持 storyboard 初始化")
    }

    /// 构建参数浮窗内容。
    override func loadView() {
        let rootView = NSView()
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view = rootView
    }

    /// 配置控件、布局和初始选中值。
    override func viewDidLoad() {
        super.viewDidLoad()

        let titleLabel = NSTextField(labelWithString: "录制参数")
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .labelColor

        let hintLabel = NSTextField(labelWithString: "默认使用当前目标的原生最大像素，也可选择较低分辨率。")
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byWordWrapping

        configureResolutionControl()
        configureControl(frameRateControl)
        resolutionControl.target = self
        resolutionControl.action = #selector(resolutionChanged)
        frameRateControl.target = self
        frameRateControl.action = #selector(frameRateChanged)
        selectCurrentValues()

        let stack = NSStackView(views: [
            titleLabel,
            hintLabel,
            makeRow(title: "分辨率", control: resolutionControl),
            makeRow(title: "帧速率", control: frameRateControl)
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        view.addSubview(stack)

        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(20)
        }
        resolutionControl.snp.makeConstraints { make in
            make.width.equalTo(250)
            make.height.equalTo(28)
        }
        frameRateControl.snp.makeConstraints { make in
            make.width.equalTo(250)
            make.height.equalTo(28)
        }
    }

    /// 配置分段控件的通用外观。
    private func configureControl(_ control: NSSegmentedControl) {
        control.segmentStyle = .rounded
        control.trackingMode = .selectOne
        control.controlSize = .small
    }

    /// 配置分辨率下拉控件的外观。
    private func configureResolutionControl() {
        resolutionControl.bezelStyle = .rounded
        resolutionControl.controlSize = .small
        resolutionControl.font = .systemFont(ofSize: 12)
    }

    /// 创建一行带标题的参数控件。
    private func makeRow(title: String, control: NSControl) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .right

        let row = NSStackView(views: [titleLabel, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        titleLabel.snp.makeConstraints { make in
            make.width.equalTo(52)
        }
        return row
    }

    /// 根据当前参数同步控件选中状态。
    private func selectCurrentValues() {
        let resolutionIndex = availableResolutions.firstIndex {
            $0.hasSameDimensions(as: settings.resolution)
        } ?? max(0, availableResolutions.count - 1)
        let frameRateIndex = MacRecordingSettings.supportedFrameRates.firstIndex(of: settings.frameRate) ?? 0
        resolutionControl.selectItem(at: resolutionIndex)
        frameRateControl.selectedSegment = frameRateIndex
    }

    /// 响应分辨率选择变化。
    @objc private func resolutionChanged() {
        let index = resolutionControl.indexOfSelectedItem
        guard availableResolutions.indices.contains(index) else { return }
        settings.resolution = availableResolutions[index]
        onChange?(settings)
    }

    /// 响应帧速率选择变化。
    @objc private func frameRateChanged() {
        let index = frameRateControl.selectedSegment
        guard MacRecordingSettings.supportedFrameRates.indices.contains(index) else { return }
        settings.frameRate = MacRecordingSettings.supportedFrameRates[index]
        onChange?(settings)
    }
}
