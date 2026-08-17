import UIKit
import SnapKit

/// 权限引导弹窗（仿快手"现在就开始拍摄"）：相机 / 录音 / 相册 / 一键开启。
/// 每一项点击会触发系统权限弹窗；"一键开启"依次申请全部。
final class PermissionSheetViewController: UIViewController {

    /// 全部关键权限（相机 + 麦克风/语音）就绪后回调；相册为可选不阻塞。
    var onReady: (() -> Void)?

    private let card = UIView()
    private let cameraRow = PermissionRow(icon: "camera", title: "开启相机")
    private let micRow = PermissionRow(icon: "mic", title: "开启录音")
    private let photoRow = PermissionRow(icon: "photo", title: "开启相册")
    private let goButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        setupUI()
        refreshStates()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshStates()
    }

    private func setupUI() {
        card.backgroundColor = UIColor(white: 0.15, alpha: 1)
        card.layer.cornerRadius = 20
        view.addSubview(card)

        let title = UILabel()
        title.text = "现在就开始拍摄"
        title.textColor = .white
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.textAlignment = .center

        let subtitle = UILabel()
        subtitle.text = "开启以下权限，记录和分享美好生活"
        subtitle.textColor = UIColor(white: 0.7, alpha: 1)
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textAlignment = .center

        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(named: "close_icon"), for: .normal)
        closeButton.tintColor = UIColor(white: 0.7, alpha: 1)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        goButton.setTitle("一键开启", for: .normal)
        goButton.setTitleColor(.white, for: .normal)
        goButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        goButton.backgroundColor = UIColor(red: 1, green: 0.25, blue: 0.35, alpha: 1)
        goButton.layer.cornerRadius = 26
        goButton.addTarget(self, action: #selector(oneTapEnable), for: .touchUpInside)

        cameraRow.onTap = { [weak self] in self?.enableCamera() }
        micRow.onTap = { [weak self] in self?.enableMic() }
        photoRow.onTap = { [weak self] in self?.enablePhoto() }

        let stack = UIStackView(arrangedSubviews: [title, subtitle, cameraRow, micRow, photoRow, goButton])
        stack.axis = .vertical
        stack.spacing = 14
        stack.setCustomSpacing(22, after: subtitle)
        card.addSubview(stack)
        card.addSubview(closeButton)

        card.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.trailing.equalToSuperview().inset(24)
        }

        closeButton.snp.makeConstraints { make in
            make.top.trailing.equalToSuperview().inset(16)
        }

        stack.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(24)
            make.leading.trailing.equalToSuperview().inset(20)
            make.bottom.equalToSuperview().inset(24)
        }

        cameraRow.snp.makeConstraints { make in
            make.height.equalTo(54)
        }
        micRow.snp.makeConstraints { make in
            make.height.equalTo(54)
        }
        photoRow.snp.makeConstraints { make in
            make.height.equalTo(54)
        }
        goButton.snp.makeConstraints { make in
            make.height.equalTo(52)
        }
    }

    private func refreshStates() {
        cameraRow.setGranted(PermissionManager.cameraGranted)
        micRow.setGranted(PermissionManager.micGranted)
        photoRow.setGranted(PermissionManager.photoGranted)
    }

    // MARK: - Actions

    private func enableCamera() {
        if PermissionManager.cameraGranted { return }
        PermissionManager.requestCamera { [weak self] _ in self?.refreshStates() }
    }

    private func enableMic() {
        if PermissionManager.micGranted { return }
        PermissionManager.requestMicAndSpeech { [weak self] _, _ in self?.refreshStates() }
    }

    private func enablePhoto() {
        if PermissionManager.photoGranted { return }
        PermissionManager.requestPhoto { [weak self] _ in self?.refreshStates() }
    }

    @objc private func oneTapEnable() {
        PermissionManager.requestCamera { [weak self] _ in
            PermissionManager.requestMicAndSpeech { _, _ in
                PermissionManager.requestPhoto { _ in
                    guard let self else { return }
                    self.refreshStates()
                    if PermissionManager.cameraGranted && PermissionManager.micGranted {
                        self.dismiss(animated: true) { self.onReady?() }
                    }
                }
            }
        }
    }

    @objc private func closeTapped() { dismiss(animated: true) }
}

/// 权限行按钮。
private final class PermissionRow: UIControl {
    var onTap: (() -> Void)?
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let check = UIImageView(image: UIImage(systemName: "checkmark"))

    init(icon: String, title: String) {
        super.init(frame: .zero)
        layer.cornerRadius = 27
        layer.borderWidth = 1
        layer.borderColor = UIColor(white: 0.4, alpha: 1).cgColor

        iconView.image = UIImage(systemName: icon)
        iconView.tintColor = .white
        titleLabel.text = title
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 16)
        check.tintColor = UIColor(white: 0.6, alpha: 1)
        check.isHidden = true

        let stack = UIStackView(arrangedSubviews: [iconView, titleLabel])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.isUserInteractionEnabled = false
        addSubview(stack)
        addSubview(check)

        stack.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }

        check.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(20)
            make.centerY.equalToSuperview()
        }

        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() { onTap?() }

    func setGranted(_ granted: Bool) {
        check.isHidden = !granted
        titleLabel.textColor = granted ? UIColor(white: 0.6, alpha: 1) : .white
        iconView.tintColor = granted ? UIColor(white: 0.6, alpha: 1) : .white
    }
}
