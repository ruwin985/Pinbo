import UIKit

/// 比例设置弹窗：分别调整大窗（主画面）和小窗（画中画）的比例，以及小窗圆角。
final class AspectSettingsViewController: UIViewController {

    var onChange: ((AspectSettings) -> Void)?
    private var settings: AspectSettings

    private let mainSegmented = UISegmentedControl(items: AspectRatio.allCases.map { $0.rawValue })
    private let pipSegmented = UISegmentedControl(items: AspectRatio.allCases.map { $0.rawValue })
    private let cornerSlider = UISlider()
    private let cornerValueLabel = UILabel()

    init(settings: AspectSettings) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let card = SheetCard(title: "比例")
        card.onClose = { [weak self] in self?.dismiss(animated: true) }
        card.pin(to: view)

        let accent = UIColor(red: 1, green: 0.25, blue: 0.35, alpha: 1)

        mainSegmented.selectedSegmentIndex = AspectRatio.allCases.firstIndex(of: settings.main) ?? 0
        mainSegmented.selectedSegmentTintColor = accent
        mainSegmented.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        mainSegmented.addTarget(self, action: #selector(valueChanged), for: .valueChanged)

        pipSegmented.selectedSegmentIndex = AspectRatio.allCases.firstIndex(of: settings.pip.aspect) ?? 0
        pipSegmented.selectedSegmentTintColor = accent
        pipSegmented.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        pipSegmented.addTarget(self, action: #selector(valueChanged), for: .valueChanged)

        cornerSlider.minimumValue = 0
        cornerSlider.maximumValue = 1
        cornerSlider.value = Float(settings.pip.cornerRatio)
        cornerSlider.addTarget(self, action: #selector(valueChanged), for: .valueChanged)

        cornerValueLabel.textColor = UIColor(white: 0.7, alpha: 1)
        cornerValueLabel.font = .systemFont(ofSize: 13)
        updateCornerLabel()

        card.addContent(SheetCard.makeLabel("大窗比例（主画面）"))
        card.addContent(mainSegmented)
        card.addContent(SheetCard.makeLabel("小窗比例（画中画）"))
        card.addContent(pipSegmented)
        card.addContent(SheetCard.makeRow("小窗圆角", cornerValueLabel))
        card.addContent(cornerSlider)
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

    @objc private func valueChanged() {
        settings.main = AspectRatio.allCases[mainSegmented.selectedSegmentIndex]
        settings.pip.aspect = AspectRatio.allCases[pipSegmented.selectedSegmentIndex]
        settings.pip.cornerRatio = CGFloat(cornerSlider.value)
        updateCornerLabel()
        onChange?(settings)
    }
}
