import UIKit
import SnapKit

/// 比例设置弹窗：分别调整大窗（主画面）和小窗（画中画）的开关、比例，以及小窗圆角。
final class AspectSettingsViewController: UIViewController {

    /// 设置变化后的回调。
    var onChange: ((AspectSettings) -> Void)?
    /// 弹窗内当前正在编辑的比例设置。
    private var settings: AspectSettings

    /// 主画面比例选择控件。
    private let mainSegmented = UISegmentedControl(items: AspectRatio.allCases.map { $0.rawValue })
    /// 上下分屏开关。
    private let splitSwitch = UISwitch()
    /// 前摄像头小窗开关。
    private let pipSwitch = UISwitch()
    /// 前摄像头小窗比例选择控件。
    private let pipSegmented = UISegmentedControl(items: AspectRatio.allCases.map { $0.rawValue })
    /// 前摄像头小窗圆角滑杆。
    private let cornerSlider = UISlider()
    /// 前摄像头小窗圆角数值标签。
    private let cornerValueLabel = UILabel()
    /// 主画面比例配置区域。
    private lazy var mainRatioSection = makeControlSection(title: "大窗比例（主画面）", control: mainSegmented)
    /// 上下分屏开关区域。
    private lazy var splitSwitchRow = SheetCard.makeRow("上下分屏", splitSwitch)
    /// 上下分屏交互提示区域。
    private lazy var splitHintSection = makeHintSection("默认前摄在上、后摄在下；长按任一半屏可切换上下顺序；单指上下滑动分屏区域可修改上下内容显示占比。")
    /// 前摄像头小窗开关区域。
    private lazy var pipSwitchRow = SheetCard.makeRow("前摄像头小窗口", pipSwitch)
    /// 前摄像头小窗比例配置区域。
    private lazy var pipRatioSection = makeControlSection(title: "小窗比例（画中画）", control: pipSegmented)
    /// 前摄像头小窗圆角配置区域。
    private lazy var cornerSection = makeSliderSection(title: "小窗圆角", slider: cornerSlider, valueLabel: cornerValueLabel)

    init(settings: AspectSettings) {
        self.settings = settings
        if self.settings.isSplitScreenEnabled {
            self.settings.isPiPEnabled = false
        }
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let card = SheetCard(title: "比例")
        card.onClose = { [weak self] in self?.dismiss(animated: true) }
        card.pin(to: view)

        mainSegmented.selectedSegmentIndex = AspectRatio.allCases.firstIndex(of: settings.main) ?? 0
        applySegmentedStyle(mainSegmented)
        mainSegmented.addTarget(self, action: #selector(valueChanged), for: .valueChanged)

        splitSwitch.isOn = settings.isSplitScreenEnabled
        splitSwitch.onTintColor = .systemGreen
        splitSwitch.addTarget(self, action: #selector(valueChanged), for: .valueChanged)

        pipSwitch.isOn = settings.isPiPEnabled
        pipSwitch.onTintColor = .systemGreen
        pipSwitch.addTarget(self, action: #selector(valueChanged), for: .valueChanged)

        pipSegmented.selectedSegmentIndex = AspectRatio.allCases.firstIndex(of: settings.pip.aspect) ?? 0
        applySegmentedStyle(pipSegmented)
        pipSegmented.addTarget(self, action: #selector(valueChanged), for: .valueChanged)

        cornerSlider.minimumValue = 0
        cornerSlider.maximumValue = 1
        cornerSlider.value = Float(settings.pip.cornerRatio)
        applySliderStyle(cornerSlider)
        cornerSlider.addTarget(self, action: #selector(valueChanged), for: .valueChanged)

        cornerValueLabel.textColor = UIColor.white.withAlphaComponent(0.58)
        cornerValueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        cornerValueLabel.textAlignment = .right
        updateCornerLabel()

        card.addContent(splitSwitchRow)
        card.addContent(splitHintSection)
        card.addContent(mainRatioSection)
        card.addContent(pipSwitchRow)
        card.addContent(pipRatioSection)
        card.addContent(cornerSection)
        updatePiPControlsVisibility()
    }

    private func makeControlSection(title: String, control: UIView) -> UIView {
        let container = makeSectionContainer()
        let titleLabel = SheetCard.makeLabel(title)
        let stack = UIStackView(arrangedSubviews: [titleLabel, control])
        stack.axis = .vertical
        stack.spacing = 10
        container.addSubview(stack)

        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(14)
        }

        control.snp.makeConstraints { make in
            make.height.equalTo(34)
        }
        return container
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

    private func makeSliderSection(title: String, slider: UISlider, valueLabel: UILabel) -> UIView {
        let container = makeSectionContainer()
        let titleLabel = SheetCard.makeLabel(title)
        let labelRow = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        labelRow.axis = .horizontal
        labelRow.alignment = .center
        labelRow.spacing = 8

        let stack = UIStackView(arrangedSubviews: [labelRow, slider])
        stack.axis = .vertical
        stack.spacing = 4
        container.addSubview(stack)

        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(14)
        }

        valueLabel.snp.makeConstraints { make in
            make.width.equalTo(50)
        }
        slider.snp.makeConstraints { make in
            make.height.equalTo(24)
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

    private func applySliderStyle(_ slider: UISlider) {
        slider.setMinimumTrackImage(makeSliderTrackImage(color: UIColor.white.withAlphaComponent(0.82)), for: .normal)
        slider.setMaximumTrackImage(makeSliderTrackImage(color: UIColor.white.withAlphaComponent(0.16)), for: .normal)
        slider.setThumbImage(makeSliderThumbImage(), for: .normal)
        slider.setThumbImage(makeSliderThumbImage(diameter: 20), for: .highlighted)
    }

    private func makeSliderTrackImage(color: UIColor) -> UIImage {
        let height: CGFloat = 4
        let size = CGSize(width: height, height: height)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            color.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: height / 2).fill()
        }
        return image.resizableImage(withCapInsets: UIEdgeInsets(top: 0, left: height / 2, bottom: 0, right: height / 2))
    }

    private func makeSliderThumbImage(diameter: CGFloat = 18) -> UIImage {
        let padding: CGFloat = 5
        let size = CGSize(width: diameter + padding * 2, height: diameter + padding * 2)
        return UIGraphicsImageRenderer(size: size).image { context in
            let rect = CGRect(x: padding, y: padding, width: diameter, height: diameter)
            context.cgContext.setShadow(offset: CGSize(width: 0, height: 2), blur: 5, color: UIColor.black.withAlphaComponent(0.28).cgColor)
            UIColor.white.setFill()
            UIBezierPath(ovalIn: rect).fill()
        }
    }

    private func updateCornerLabel() {
        // 1:1 且圆角拉满 = 圆形
        let isSquare = AspectRatio.allCases[pipSegmented.selectedSegmentIndex] == .r1x1
        if isSquare && cornerSlider.value >= 0.98 {
            cornerValueLabel.text = "圆形"
        } else {
            cornerValueLabel.text = "\(Int(cornerSlider.value * 100))%"
        }
    }

    private func updatePiPControlsVisibility() {
        let isSplitScreenEnabled = settings.isSplitScreenEnabled
        let isPiPEnabled = settings.isPiPEnabled
        mainRatioSection.isHidden = isSplitScreenEnabled
        splitHintSection.isHidden = !isSplitScreenEnabled
        pipSwitch.isEnabled = !isSplitScreenEnabled
        pipSwitchRow.alpha = isSplitScreenEnabled ? 0.45 : 1
        pipRatioSection.isHidden = !isPiPEnabled || isSplitScreenEnabled
        cornerSection.isHidden = !isPiPEnabled || isSplitScreenEnabled
    }

    @objc private func valueChanged() {
        settings.main = AspectRatio.allCases[mainSegmented.selectedSegmentIndex]
        settings.isSplitScreenEnabled = splitSwitch.isOn
        if settings.isSplitScreenEnabled {
            settings.isPiPEnabled = false
            pipSwitch.isOn = false
        } else {
            settings.isPiPEnabled = pipSwitch.isOn
        }
        settings.pip.aspect = AspectRatio.allCases[pipSegmented.selectedSegmentIndex]
        settings.pip.cornerRatio = CGFloat(cornerSlider.value)
        updateCornerLabel()
        updatePiPControlsVisibility()
        onChange?(settings)
    }
}
