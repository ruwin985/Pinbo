import UIKit
import SnapKit

/// 底部弹窗卡片：标题 + 关闭 + 垂直内容堆栈。半透明遮罩点击关闭。
final class SheetCard: UIView {

    /// 外部控制器提供的浮层关闭回调。
    var onClose: (() -> Void)?
    private let contentStack = UIStackView()
    private let card = UIView()
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let overlayView = UIView()
    private let dragHandleView = UIView()
    /// 顶部拖拽和浮层收起动画的协调器。
    private lazy var dragCoordinator = SheetCardDragCoordinator(sheetView: self, cardView: card)

    init(title: String) {
        super.init(frame: .zero)
        backgroundColor = UIColor.black.withAlphaComponent(0.22)

        card.backgroundColor = .clear
        card.layer.cornerRadius = 28
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 0.7
        card.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.28
        card.layer.shadowRadius = 28
        card.layer.shadowOffset = CGSize(width: 0, height: -8)
        card.clipsToBounds = false
        addSubview(card)

        blurView.layer.cornerRadius = 28
        blurView.layer.cornerCurve = .continuous
        blurView.clipsToBounds = true
        card.addSubview(blurView)

        overlayView.backgroundColor = UIColor.black.withAlphaComponent(0.42)
        overlayView.layer.cornerRadius = 28
        overlayView.layer.cornerCurve = .continuous
        overlayView.clipsToBounds = true
        card.addSubview(overlayView)

        dragHandleView.backgroundColor = UIColor.white.withAlphaComponent(0.34)
        dragHandleView.layer.cornerRadius = 2
        dragHandleView.layer.cornerCurve = .continuous
        dragHandleView.isUserInteractionEnabled = false
        card.addSubview(dragHandleView)

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)

        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(named: "close_icon"), for: .normal)
        closeButton.tintColor = UIColor.white.withAlphaComponent(0.86)
        closeButton.backgroundColor = UIColor.white.withAlphaComponent(0.1)
        closeButton.layer.cornerRadius = 15
        closeButton.layer.cornerCurve = .continuous
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        contentStack.axis = .vertical
        contentStack.spacing = 12

        let header = UIStackView(arrangedSubviews: [titleLabel])
        card.addSubview(header)
        card.addSubview(closeButton)
        card.addSubview(contentStack)

        card.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
        }

        blurView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        overlayView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        dragHandleView.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(10)
            make.centerX.equalToSuperview()
            make.width.equalTo(38)
            make.height.equalTo(4)
        }

        header.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(30)
            make.leading.equalToSuperview().offset(22)
        }

        closeButton.snp.makeConstraints { make in
            make.centerY.equalTo(header)
            make.trailing.equalToSuperview().inset(18)
            make.size.equalTo(30)
        }

        contentStack.snp.makeConstraints { make in
            make.top.equalTo(header.snp.bottom).offset(20)
            make.leading.trailing.equalToSuperview().inset(18)
            make.bottom.equalTo(card.safeAreaLayoutGuide).inset(24)
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(bgTapped(_:)))
        addGestureRecognizer(tap)
        dragCoordinator.onDismiss = { [weak self] in self?.onClose?() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func pin(to parent: UIView) {
        parent.addSubview(self)
        snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    func addContent(_ v: UIView) { contentStack.addArrangedSubview(v) }

    @objc private func closeTapped() { dragCoordinator.closeAnimated() }
    @objc private func bgTapped(_ g: UITapGestureRecognizer) {
        // 仅点击卡片外区域关闭
        if !card.frame.contains(g.location(in: self)) { dragCoordinator.closeAnimated() }
    }

    // MARK: - Builders

    static func makeLabel(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.textColor = UIColor.white.withAlphaComponent(0.72)
        l.font = .systemFont(ofSize: 13, weight: .medium)
        return l
    }

    static func makeRow(_ title: String, _ control: UIView) -> UIView {
        let label = makeLabel(title)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = UIColor.white.withAlphaComponent(0.88)

        let stack = UIStackView(arrangedSubviews: [label, control])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 14

        let row = UIView()
        row.backgroundColor = UIColor.white.withAlphaComponent(0.075)
        row.layer.cornerRadius = 16
        row.layer.cornerCurve = .continuous
        row.layer.borderWidth = 0.6
        row.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        row.addSubview(stack)

        stack.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(14)
            make.top.bottom.equalToSuperview().inset(12)
        }

        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.snp.makeConstraints { make in
            make.height.greaterThanOrEqualTo(50)
        }
        return row
    }
}

enum AppDialogActionStyle {
    case primary
    case cancel
    case destructive
}

struct AppDialogAction {
    let title: String
    let style: AppDialogActionStyle
    let handler: ((AppDialogViewController) -> Void)?

    init(title: String, style: AppDialogActionStyle = .primary, handler: ((AppDialogViewController) -> Void)? = nil) {
        self.title = title
        self.style = style
        self.handler = handler
    }
}

final class AppDialogViewController: UIViewController {
    struct Layout {
        var maxWidth: CGFloat = 490
        var centerYOffset: CGFloat = 0
    }

    private let dialogTitle: String
    private let message: String
    private let initialText: String?
    private let placeholder: String?
    private let actions: [AppDialogAction]
    private let layout: Layout
    private let card = UIView()
    private var inputField: UITextField?

    var inputText: String {
        inputField?.text ?? initialText ?? ""
    }

    init(title: String,
         message: String,
         initialText: String? = nil,
         placeholder: String? = nil,
         layout: Layout = Layout(),
         actions: [AppDialogAction]) {
        self.dialogTitle = title
        self.message = message
        self.initialText = initialText
        self.placeholder = placeholder
        self.layout = layout
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.56)

        card.backgroundColor = UIColor(white: 0.12, alpha: 1)
        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        view.addSubview(card)

        let titleLabel = UILabel()
        titleLabel.text = dialogTitle
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        let messageLabel = UILabel()
        messageLabel.text = message
        messageLabel.textColor = UIColor.white.withAlphaComponent(0.74)
        messageLabel.font = .systemFont(ofSize: 14, weight: .regular)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        let contentStack = UIStackView(arrangedSubviews: [titleLabel, messageLabel])
        contentStack.axis = .vertical
        contentStack.spacing = 10
        card.addSubview(contentStack)

        if initialText != nil || placeholder != nil {
            let textField = UITextField()
            textField.text = initialText
            textField.placeholder = placeholder
            textField.textColor = .white
            textField.tintColor = .white
            textField.returnKeyType = .done
            textField.delegate = self
            textField.clearButtonMode = .whileEditing
            textField.backgroundColor = UIColor.white.withAlphaComponent(0.1)
            textField.layer.cornerRadius = 12
            textField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
            textField.leftViewMode = .always
            inputField = textField
            contentStack.addArrangedSubview(textField)
            textField.snp.makeConstraints { make in
                make.height.equalTo(44)
            }
            DispatchQueue.main.async { textField.becomeFirstResponder() }
        }

        let buttonStack = UIStackView()
        buttonStack.axis = actions.count > 2 ? .vertical : .horizontal
        buttonStack.distribution = .fillEqually
        buttonStack.spacing = 10
        card.addSubview(buttonStack)

        for (index, action) in actions.enumerated() {
            let button = UIButton(type: .system)
            button.tag = index
            button.setTitle(action.title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
            button.layer.cornerRadius = 14
            button.layer.cornerCurve = .continuous
            applyStyle(action.style, to: button)
            button.addTarget(self, action: #selector(actionTapped(_:)), for: .touchUpInside)
            buttonStack.addArrangedSubview(button)
            button.snp.makeConstraints { make in
                make.height.equalTo(46)
            }
        }

        card.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.centerY.equalToSuperview().offset(layout.centerYOffset)
            make.leading.greaterThanOrEqualToSuperview().offset(28)
            make.trailing.lessThanOrEqualToSuperview().inset(28)
            make.width.lessThanOrEqualTo(layout.maxWidth)
        }

        contentStack.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(24)
            make.leading.trailing.equalToSuperview().inset(20)
        }

        buttonStack.snp.makeConstraints { make in
            make.top.equalTo(contentStack.snp.bottom).offset(22)
            make.leading.trailing.equalToSuperview().inset(20)
            make.bottom.equalToSuperview().inset(20)
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    private func applyStyle(_ style: AppDialogActionStyle, to button: UIButton) {
        switch style {
        case .primary:
            button.applyAppPrimaryButtonStyle(cornerRadius: 14)
        case .cancel:
            button.backgroundColor = UIColor.white.withAlphaComponent(0.12)
            button.setTitleColor(.white.withAlphaComponent(0.88), for: .normal)
        case .destructive:
            button.backgroundColor = AppTheme.destructive
            button.setTitleColor(.white, for: .normal)
        }
    }

    @objc private func actionTapped(_ sender: UIButton) {
        view.endEditing(true)
        let action = actions[sender.tag]
        let dialog = self
        dismiss(animated: true) {
            action.handler?(dialog)
        }
    }

    @objc private func backgroundTapped(_ gesture: UITapGestureRecognizer) {
        if !card.frame.contains(gesture.location(in: view)) {
            view.endEditing(true)
            dismiss(animated: true)
        }
    }
}

extension AppDialogViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

extension UIViewController {
    func presentAppDialog(title: String, message: String, actions: [AppDialogAction]) {
        present(AppDialogViewController(title: title, message: message, actions: actions), animated: true)
    }

    func presentAppMessage(title: String, message: String, buttonTitle: String = "好", onOK: (() -> Void)? = nil) {
        presentAppDialog(title: title, message: message, actions: [
            AppDialogAction(title: buttonTitle) { _ in onOK?() }
        ])
    }

    func presentAppConfirmation(title: String,
                                message: String,
                                confirmTitle: String,
                                cancelTitle: String = "取消",
                                confirmStyle: AppDialogActionStyle = .primary,
                                onConfirm: @escaping () -> Void) {
        presentAppDialog(title: title, message: message, actions: [
            AppDialogAction(title: cancelTitle, style: .cancel),
            AppDialogAction(title: confirmTitle, style: confirmStyle) { _ in onConfirm() },
        ])
    }

    func presentAppTextInput(title: String,
                             message: String,
                             text: String,
                             placeholder: String? = nil,
                             confirmTitle: String = "保存",
                             onConfirm: @escaping (String) -> Void) {
        let dialog = AppDialogViewController(title: title,
                                             message: message,
                                             initialText: text,
                                             placeholder: placeholder,
                                             layout: AppDialogViewController.Layout(centerYOffset: -150),
                                             actions: [
                                                AppDialogAction(title: "取消", style: .cancel),
                                                AppDialogAction(title: confirmTitle) { dialog in
                                                    onConfirm(dialog.inputText)
                                                },
                                             ])
        present(dialog, animated: true)
    }

    func showToast(_ message: String) {
        view.viewWithTag(982_417)?.removeFromSuperview()

        let label = UILabel()
        label.tag = 982_417
        label.text = "  \(message)  "
        label.textColor = .white
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.backgroundColor = UIColor.black.withAlphaComponent(0.76)
        label.layer.cornerRadius = 18
        label.layer.masksToBounds = true
        label.alpha = 0
        view.addSubview(label)

        label.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.leading.greaterThanOrEqualToSuperview().offset(32)
            make.trailing.lessThanOrEqualToSuperview().inset(32)
            make.bottom.equalTo(view.safeAreaLayoutGuide).inset(128)
            make.height.greaterThanOrEqualTo(36)
        }

        UIView.animate(withDuration: 0.18, animations: {
            label.alpha = 1
        }) { _ in
            UIView.animate(withDuration: 0.22, delay: 1.45, options: [.curveEaseInOut], animations: {
                label.alpha = 0
            }) { _ in
                label.removeFromSuperview()
            }
        }
    }
}
