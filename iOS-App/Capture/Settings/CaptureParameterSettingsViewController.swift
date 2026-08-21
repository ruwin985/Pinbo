import UIKit
import SnapKit

/// 录制参数弹窗：分别选择前后摄像头的录制分辨率和帧率。
final class CaptureParameterSettingsViewController: UIViewController {

    var onChange: ((VideoCaptureSettings) -> Void)?
    private var settings: VideoCaptureSettings

    private let availableBackResolutions: [CaptureVideoResolution]
    private let availableFrontResolutions: [CaptureVideoResolution]
    private let backFrameRatesProvider: (CaptureVideoResolution) -> [CaptureFrameRate]
    private let frontFrameRatesProvider: (CaptureVideoResolution) -> [CaptureFrameRate]
    private let showsFrontSettings: Bool
    private let frontSectionTitle: String
    private var availableBackFrameRates: [CaptureFrameRate]
    private var availableFrontFrameRates: [CaptureFrameRate]

    private let backResolutionSegmented = UISegmentedControl()
    private let backFrameRateSegmented = UISegmentedControl()
    private let frontResolutionSegmented = UISegmentedControl()
    private let frontFrameRateSegmented = UISegmentedControl()
    private lazy var backSection = makeCameraSection(title: "后摄像头（主画面）",
                                                     resolutionControl: backResolutionSegmented,
                                                     frameRateControl: backFrameRateSegmented)
    private lazy var frontSection = makeCameraSection(title: frontSectionTitle,
                                                      resolutionControl: frontResolutionSegmented,
                                                      frameRateControl: frontFrameRateSegmented)
    private lazy var hintSection = makeHintSection(showsFrontSettings
        ? "每个摄像头只显示当前设备双摄模式支持的规格；4K 或 120fps 不支持时会自动隐藏。"
        : "当前未启用前摄像头小窗口，仅显示主画面支持的规格；4K 或 120fps 不支持时会自动隐藏。")

    init(settings: VideoCaptureSettings,
         availableBackResolutions: [CaptureVideoResolution],
         backFrameRatesProvider: @escaping (CaptureVideoResolution) -> [CaptureFrameRate],
         availableFrontResolutions: [CaptureVideoResolution],
         frontFrameRatesProvider: @escaping (CaptureVideoResolution) -> [CaptureFrameRate],
         showsFrontSettings: Bool = true,
         frontSectionTitle: String = "前摄像头（小窗）") {
        self.availableBackResolutions = availableBackResolutions.isEmpty ? [.p480] : availableBackResolutions
        self.availableFrontResolutions = availableFrontResolutions.isEmpty ? [.p480] : availableFrontResolutions
        self.backFrameRatesProvider = backFrameRatesProvider
        self.frontFrameRatesProvider = frontFrameRatesProvider
        self.showsFrontSettings = showsFrontSettings
        self.frontSectionTitle = frontSectionTitle

        let back = Self.normalized(settings.back,
                                   resolutions: self.availableBackResolutions,
                                   frameRatesProvider: backFrameRatesProvider)
        let front = Self.normalized(settings.front,
                                    resolutions: self.availableFrontResolutions,
                                    frameRatesProvider: frontFrameRatesProvider)
        self.settings = VideoCaptureSettings(back: back, front: front)
        self.availableBackFrameRates = Self.safeFrameRates(backFrameRatesProvider(back.resolution))
        self.availableFrontFrameRates = Self.safeFrameRates(frontFrameRatesProvider(front.resolution))
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let card = SheetCard(title: "参数")
        card.onClose = { [weak self] in self?.dismiss(animated: true) }
        card.pin(to: view)

        configureSegmented(backResolutionSegmented,
                           items: availableBackResolutions.map { $0.displayName },
                           selectedIndex: availableBackResolutions.firstIndex(of: settings.back.resolution) ?? 0)
        configureSegmented(backFrameRateSegmented,
                           items: availableBackFrameRates.map { $0.displayName },
                           selectedIndex: availableBackFrameRates.firstIndex(of: settings.back.frameRate) ?? 0)
        if showsFrontSettings {
            configureSegmented(frontResolutionSegmented,
                               items: availableFrontResolutions.map { $0.displayName },
                               selectedIndex: availableFrontResolutions.firstIndex(of: settings.front.resolution) ?? 0)
            configureSegmented(frontFrameRateSegmented,
                               items: availableFrontFrameRates.map { $0.displayName },
                               selectedIndex: availableFrontFrameRates.firstIndex(of: settings.front.frameRate) ?? 0)
        }

        backResolutionSegmented.addTarget(self, action: #selector(backResolutionChanged), for: .valueChanged)
        backFrameRateSegmented.addTarget(self, action: #selector(backFrameRateChanged), for: .valueChanged)
        if showsFrontSettings {
            frontResolutionSegmented.addTarget(self, action: #selector(frontResolutionChanged), for: .valueChanged)
            frontFrameRateSegmented.addTarget(self, action: #selector(frontFrameRateChanged), for: .valueChanged)
        }

        card.addContent(backSection)
        if showsFrontSettings {
            card.addContent(frontSection)
        }
        card.addContent(hintSection)
    }

    private static func normalized(_ settings: CameraCaptureSettings,
                                   resolutions: [CaptureVideoResolution],
                                   frameRatesProvider: (CaptureVideoResolution) -> [CaptureFrameRate]) -> CameraCaptureSettings {
        let safeResolutions = resolutions.isEmpty ? [.p480] : resolutions
        let resolution = safeResolutions.contains(settings.resolution) ? settings.resolution : (safeResolutions.first ?? .p480)
        let frameRates = safeFrameRates(frameRatesProvider(resolution))
        let frameRate = frameRates.contains(settings.frameRate) ? settings.frameRate : (frameRates.first ?? .fps24)
        return CameraCaptureSettings(resolution: resolution, frameRate: frameRate)
    }

    private static func safeFrameRates(_ frameRates: [CaptureFrameRate]) -> [CaptureFrameRate] {
        frameRates.isEmpty ? [.fps24, .fps30] : frameRates
    }

    private func configureSegmented(_ segmented: UISegmentedControl,
                                    items: [String],
                                    selectedIndex: Int) {
        segmented.removeAllSegments()
        for (index, item) in items.enumerated() {
            segmented.insertSegment(withTitle: item, at: index, animated: false)
        }
        segmented.selectedSegmentIndex = max(0, min(selectedIndex, max(items.count - 1, 0)))
        applySegmentedStyle(segmented)
    }

    private func makeCameraSection(title: String,
                                   resolutionControl: UIView,
                                   frameRateControl: UIView) -> UIView {
        let container = makeSectionContainer()
        let titleLabel = SheetCard.makeLabel(title)
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)

        let stack = UIStackView(arrangedSubviews: [
            titleLabel,
            makeLabeledControl(title: "分辨率", control: resolutionControl),
            makeLabeledControl(title: "帧速率", control: frameRateControl)
        ])
        stack.axis = .vertical
        stack.spacing = 12
        container.addSubview(stack)

        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(14)
        }
        return container
    }

    private func makeLabeledControl(title: String, control: UIView) -> UIView {
        let label = SheetCard.makeLabel(title)
        let stack = UIStackView(arrangedSubviews: [label, control])
        stack.axis = .vertical
        stack.spacing = 8
        control.snp.makeConstraints { make in
            make.height.equalTo(34)
        }
        return stack
    }

    private func makeHintSection(_ text: String) -> UIView {
        let container = makeSectionContainer()
        let label = SheetCard.makeLabel(text)
        label.numberOfLines = 0
        label.textColor = UIColor.white.withAlphaComponent(0.62)
        container.addSubview(label)

        label.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(14)
        }
        return container
    }

    private func makeSectionContainer() -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor.white.withAlphaComponent(0.075)
        container.layer.cornerRadius = 18
        container.layer.cornerCurve = .continuous
        container.layer.borderWidth = 0.6
        container.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        return container
    }

    private func applySegmentedStyle(_ segmented: UISegmentedControl) {
        segmented.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        segmented.selectedSegmentTintColor = UIColor.white.withAlphaComponent(0.24)
        segmented.setTitleTextAttributes([
            .foregroundColor: UIColor.white.withAlphaComponent(0.6),
            .font: UIFont.systemFont(ofSize: 13, weight: .semibold)
        ], for: .normal)
        segmented.setTitleTextAttributes([
            .foregroundColor: UIColor.white,
            .font: UIFont.systemFont(ofSize: 13, weight: .semibold)
        ], for: .selected)
    }

    @objc private func backResolutionChanged() {
        guard backResolutionSegmented.selectedSegmentIndex >= 0,
              backResolutionSegmented.selectedSegmentIndex < availableBackResolutions.count else { return }
        settings.back.resolution = availableBackResolutions[backResolutionSegmented.selectedSegmentIndex]
        availableBackFrameRates = Self.safeFrameRates(backFrameRatesProvider(settings.back.resolution))
        if !availableBackFrameRates.contains(settings.back.frameRate) {
            settings.back.frameRate = availableBackFrameRates.first ?? .fps24
        }
        configureSegmented(backFrameRateSegmented,
                           items: availableBackFrameRates.map { $0.displayName },
                           selectedIndex: availableBackFrameRates.firstIndex(of: settings.back.frameRate) ?? 0)
        notifyChange()
    }

    @objc private func backFrameRateChanged() {
        guard backFrameRateSegmented.selectedSegmentIndex >= 0,
              backFrameRateSegmented.selectedSegmentIndex < availableBackFrameRates.count else { return }
        settings.back.frameRate = availableBackFrameRates[backFrameRateSegmented.selectedSegmentIndex]
        notifyChange()
    }

    @objc private func frontResolutionChanged() {
        guard frontResolutionSegmented.selectedSegmentIndex >= 0,
              frontResolutionSegmented.selectedSegmentIndex < availableFrontResolutions.count else { return }
        settings.front.resolution = availableFrontResolutions[frontResolutionSegmented.selectedSegmentIndex]
        availableFrontFrameRates = Self.safeFrameRates(frontFrameRatesProvider(settings.front.resolution))
        if !availableFrontFrameRates.contains(settings.front.frameRate) {
            settings.front.frameRate = availableFrontFrameRates.first ?? .fps24
        }
        configureSegmented(frontFrameRateSegmented,
                           items: availableFrontFrameRates.map { $0.displayName },
                           selectedIndex: availableFrontFrameRates.firstIndex(of: settings.front.frameRate) ?? 0)
        notifyChange()
    }

    @objc private func frontFrameRateChanged() {
        guard frontFrameRateSegmented.selectedSegmentIndex >= 0,
              frontFrameRateSegmented.selectedSegmentIndex < availableFrontFrameRates.count else { return }
        settings.front.frameRate = availableFrontFrameRates[frontFrameRateSegmented.selectedSegmentIndex]
        notifyChange()
    }

    private func notifyChange() {
        onChange?(settings)
    }
}
