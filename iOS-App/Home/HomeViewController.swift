import UIKit
import AVFoundation
import SnapKit

/// 首页：上方草稿网格（一排三个，可上下滚动），底部"去录制"呼吸动画圆形按钮。
final class HomeViewController: UIViewController {

    private var drafts: [RecordingProject] = []
    private lazy var collectionView: UICollectionView = makeCollectionView()
    private let recordButton = UIButton(type: .custom)
    private let recordOptionsBackdrop = UIControl()
    private let recordOptionsBubble = UIView()
    private let titleLabel = UILabel()
    private let editButton = UIButton(type: .system)
    private var isEditingDrafts = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        navigationController?.setNavigationBarHidden(true, animated: false)
        setupUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        reloadDrafts()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startBreathing()
    }

    // MARK: - UI

    private func setupUI() {
        titleLabel.text = "我的作品"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        view.addSubview(titleLabel)

        editButton.setTitle("编辑", for: .normal)
        editButton.setTitleColor(.white, for: .normal)
        editButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        editButton.addTarget(self, action: #selector(editTapped), for: .touchUpInside)
        view.addSubview(editButton)

        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(DraftCell.self, forCellWithReuseIdentifier: DraftCell.reuseID)
        view.addSubview(collectionView)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(draftLongPressed(_:)))
        collectionView.addGestureRecognizer(longPress)

        recordButton.backgroundColor = UIColor(red: 1, green: 0.25, blue: 0.35, alpha: 1)
        recordButton.layer.cornerRadius = 36
        recordButton.setImage(UIImage(systemName: "video.fill"), for: .normal)
        recordButton.tintColor = .white
        recordButton.addTarget(self, action: #selector(recordTapped), for: .touchUpInside)
        recordButton.layer.shadowColor = UIColor.systemPink.cgColor
        recordButton.layer.shadowRadius = 12
        recordButton.layer.shadowOpacity = 0.6
        recordButton.layer.shadowOffset = .zero
        view.addSubview(recordButton)

        let hint = UILabel()
        hint.text = "去录制"
        hint.textColor = .white
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.textAlignment = .center
        view.addSubview(hint)

        titleLabel.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(12)
            make.leading.equalToSuperview().offset(16)
        }

        editButton.snp.makeConstraints { make in
            make.centerY.equalTo(titleLabel)
            make.trailing.equalToSuperview().inset(16)
            make.leading.greaterThanOrEqualTo(titleLabel.snp.trailing).offset(12)
        }

        collectionView.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(12)
            make.leading.trailing.equalToSuperview()
            make.bottom.equalTo(recordButton.snp.top).offset(-16)
        }

        recordButton.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalTo(view.safeAreaLayoutGuide).inset(36)
            make.size.equalTo(72)
        }

        hint.snp.makeConstraints { make in
            make.centerX.equalTo(recordButton)
            make.top.equalTo(recordButton.snp.bottom).offset(6)
        }

        setupRecordOptionsBubble()
    }

    private func setupRecordOptionsBubble() {
        recordOptionsBackdrop.backgroundColor = UIColor.black.withAlphaComponent(0.001)
        recordOptionsBackdrop.alpha = 0
        recordOptionsBackdrop.isHidden = true
        recordOptionsBackdrop.addTarget(self, action: #selector(recordOptionsBackdropTapped), for: .touchUpInside)
        view.insertSubview(recordOptionsBackdrop, belowSubview: recordButton)
        recordOptionsBackdrop.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        recordOptionsBubble.alpha = 0
        recordOptionsBubble.transform = CGAffineTransform(translationX: 0, y: 14).scaledBy(x: 0.92, y: 0.92)
        recordOptionsBubble.layer.cornerRadius = 26
        recordOptionsBubble.layer.cornerCurve = .continuous
        recordOptionsBubble.layer.borderWidth = 0.7
        recordOptionsBubble.layer.borderColor = UIColor.white.withAlphaComponent(0.24).cgColor
        recordOptionsBubble.layer.shadowColor = UIColor.black.cgColor
        recordOptionsBubble.layer.shadowOpacity = 0.22
        recordOptionsBubble.layer.shadowRadius = 26
        recordOptionsBubble.layer.shadowOffset = CGSize(width: 0, height: 14)
        recordOptionsBubble.isHidden = true

        let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        blurView.layer.cornerRadius = 26
        blurView.layer.cornerCurve = .continuous
        blurView.clipsToBounds = true
        recordOptionsBubble.addSubview(blurView)
        blurView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        let tintView = UIView()
        tintView.backgroundColor = UIColor.white.withAlphaComponent(0.1)
        tintView.layer.cornerRadius = 26
        tintView.layer.cornerCurve = .continuous
        tintView.clipsToBounds = true
        recordOptionsBubble.addSubview(tintView)
        tintView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        let cameraButton = makeRecordOptionButton(icon: "video.fill", title: "摄像头录制", subtitle: "前后摄同框拍摄")
        cameraButton.addTarget(self, action: #selector(cameraRecordTapped), for: .touchUpInside)
        let screenButton = makeRecordOptionButton(icon: "rectangle.inset.filled.and.person.filled", title: "屏幕录制", subtitle: "屏幕 + 前摄悬浮窗")
        screenButton.addTarget(self, action: #selector(screenRecordTapped), for: .touchUpInside)

        let divider = UIView()
        divider.backgroundColor = UIColor.white.withAlphaComponent(0.12)

        let stack = UIStackView(arrangedSubviews: [cameraButton, divider, screenButton])
        stack.axis = .vertical
        stack.spacing = 0
        recordOptionsBubble.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8))
        }
        divider.snp.makeConstraints { make in
            make.height.equalTo(0.7)
        }

        let arrow = RecordOptionsArrowView()
        recordOptionsBubble.addSubview(arrow)
        arrow.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalToSuperview().offset(9)
            make.width.equalTo(24)
            make.height.equalTo(12)
        }

        view.insertSubview(recordOptionsBubble, belowSubview: recordButton)
        recordOptionsBubble.snp.makeConstraints { make in
            make.centerX.equalTo(recordButton)
            make.bottom.equalTo(recordButton.snp.top).offset(-18)
            make.width.equalTo(228)
        }
    }

    private func makeRecordOptionButton(icon: String, title: String, subtitle: String) -> UIButton {
        let button = UIButton(type: .system)
        button.tintColor = .white
        button.backgroundColor = .clear
        button.layer.cornerRadius = 20
        button.layer.cornerCurve = .continuous
        button.contentHorizontalAlignment = .fill

        let iconView = UIImageView(image: UIImage(systemName: icon))
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.backgroundColor = UIColor.white.withAlphaComponent(0.14)
        iconView.layer.cornerRadius = 17
        iconView.layer.cornerCurve = .continuous

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)

        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.62)
        subtitleLabel.font = .systemFont(ofSize: 12, weight: .medium)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = UIColor.white.withAlphaComponent(0.44)
        chevron.contentMode = .scaleAspectFit

        let stack = UIStackView(arrangedSubviews: [iconView, textStack, chevron])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.isUserInteractionEnabled = false
        button.addSubview(stack)

        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
        }
        iconView.snp.makeConstraints { make in
            make.size.equalTo(34)
        }
        chevron.snp.makeConstraints { make in
            make.width.equalTo(12)
        }
        button.snp.makeConstraints { make in
            make.height.equalTo(62)
        }

        button.addTarget(self, action: #selector(recordOptionTouchDown(_:)), for: .touchDown)
        button.addTarget(self, action: #selector(recordOptionTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return button
    }

    private func makeCollectionView() -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        let spacing: CGFloat = 8
        layout.minimumInteritemSpacing = spacing
        layout.minimumLineSpacing = spacing
        layout.sectionInset = UIEdgeInsets(top: 0, left: 16, bottom: 16, right: 16)
        let width = (UIScreen.main.bounds.width - 16 * 2 - spacing * 2) / 3
        layout.itemSize = CGSize(width: width, height: width * 16 / 9)
        return UICollectionView(frame: .zero, collectionViewLayout: layout)
    }

    // MARK: - Breathing

    private func startBreathing() {
        let anim = CABasicAnimation(keyPath: "transform.scale")
        anim.fromValue = 1.0
        anim.toValue = 1.12
        anim.duration = 1.1
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        recordButton.layer.add(anim, forKey: "breathing")

        let glow = CABasicAnimation(keyPath: "shadowRadius")
        glow.fromValue = 8
        glow.toValue = 20
        glow.duration = 1.1
        glow.autoreverses = true
        glow.repeatCount = .infinity
        recordButton.layer.add(glow, forKey: "glow")
    }

    // MARK: - Data

    private func reloadDrafts() {
        drafts = DraftStore.shared.loadAll()
        collectionView.reloadData()
    }

    private func setEditingDrafts(_ editing: Bool) {
        isEditingDrafts = editing
        editButton.setTitle(editing ? "取消" : "编辑", for: .normal)
        collectionView.visibleCells.compactMap { $0 as? DraftCell }.forEach { $0.isEditing = editing }
    }

    // MARK: - Actions

    @objc private func editTapped() {
        hideRecordOptions(animated: true)
        setEditingDrafts(!isEditingDrafts)
    }

    @objc private func draftLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: collectionView)
        guard collectionView.indexPathForItem(at: point) != nil else { return }
        setEditingDrafts(true)
    }

    @objc private func recordTapped() {
        if isEditingDrafts {
            setEditingDrafts(false)
            showRecordOptions()
            return
        }

        toggleRecordOptions()
    }

    @objc private func cameraRecordTapped() {
        hideRecordOptions(animated: true)
        openCameraRecorderWithPermissions()
    }

    @objc private func screenRecordTapped() {
        hideRecordOptions(animated: true)
        openScreenRecorder()
    }

    private func openScreenRecorder() {
        let recorder = ScreenRecordingViewController()
        navigationController?.pushViewController(recorder, animated: true)
    }

    @objc private func recordOptionsBackdropTapped() {
        hideRecordOptions(animated: true)
    }

    @objc private func recordOptionTouchDown(_ sender: UIButton) {
        UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            sender.backgroundColor = UIColor.white.withAlphaComponent(0.12)
            sender.transform = CGAffineTransform(scaleX: 0.985, y: 0.985)
        }
    }

    @objc private func recordOptionTouchUp(_ sender: UIButton) {
        UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            sender.backgroundColor = .clear
            sender.transform = .identity
        }
    }

    private func toggleRecordOptions() {
        recordOptionsBubble.isHidden ? showRecordOptions() : hideRecordOptions(animated: true)
    }

    private func showRecordOptions() {
        recordOptionsBackdrop.isHidden = false
        recordOptionsBubble.isHidden = false
        view.bringSubviewToFront(recordOptionsBackdrop)
        view.bringSubviewToFront(recordOptionsBubble)
        view.bringSubviewToFront(recordButton)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        UIView.animate(withDuration: 0.44,
                       delay: 0,
                       usingSpringWithDamping: 0.78,
                       initialSpringVelocity: 0.7,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.recordOptionsBackdrop.alpha = 1
            self.recordOptionsBubble.alpha = 1
            self.recordOptionsBubble.transform = .identity
        }
    }

    private func hideRecordOptions(animated: Bool) {
        guard !recordOptionsBubble.isHidden else { return }
        let updates = {
            self.recordOptionsBackdrop.alpha = 0
            self.recordOptionsBubble.alpha = 0
            self.recordOptionsBubble.transform = CGAffineTransform(translationX: 0, y: 14).scaledBy(x: 0.92, y: 0.92)
        }
        let completion: (Bool) -> Void = { _ in
            self.recordOptionsBackdrop.isHidden = true
            self.recordOptionsBubble.isHidden = true
        }
        if animated {
            UIView.animate(withDuration: 0.18,
                           delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut],
                           animations: updates,
                           completion: completion)
        } else {
            updates()
            completion(true)
        }
    }

    private func openCameraRecorderWithPermissions() {

        // 先检查关键权限，未就绪则弹权限引导
        if PermissionManager.cameraGranted && PermissionManager.micGranted {
            openRecorder()
        } else {
            let sheet = PermissionSheetViewController()
            sheet.modalPresentationStyle = .overFullScreen
            sheet.modalTransitionStyle = .crossDissolve
            sheet.onReady = { [weak self] in self?.openRecorder() }
            present(sheet, animated: true)
        }
    }

    private func openRecorder() {
        let recorder = RecordingViewController()
        navigationController?.pushViewController(recorder, animated: true)
    }

    private func openDraft(_ project: RecordingProject) {
        hideRecordOptions(animated: false)
        let editor = EditorViewController(project: project)
        navigationController?.pushViewController(editor, animated: true)
    }

    private func deleteDraft(at indexPath: IndexPath) {
        guard drafts.indices.contains(indexPath.item) else { return }
        let project = drafts[indexPath.item]
        presentAppConfirmation(title: "删除作品？",
                               message: "删除后无法恢复，确定要删除这个作品吗？",
                               confirmTitle: "删除",
                               confirmStyle: .destructive) { [weak self] in
            guard let self else { return }
            do {
                try DraftStore.shared.delete(project.id)
                self.drafts.removeAll { $0.id == project.id }
                self.collectionView.reloadData()
            } catch {
                self.presentAppMessage(title: "删除失败", message: error.localizedDescription)
            }
        }
    }
}

// MARK: - Collection

extension HomeViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { drafts.count }

    func collectionView(_ cv: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: DraftCell.reuseID, for: indexPath) as! DraftCell
        cell.configure(with: drafts[indexPath.item])
        cell.isEditing = isEditingDrafts
        cell.onDelete = { [weak self, weak cell] in
            guard let self,
                  let cell,
                  let currentIndexPath = self.collectionView.indexPath(for: cell) else { return }
            self.deleteDraft(at: currentIndexPath)
        }
        return cell
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !isEditingDrafts else { return }
        openDraft(drafts[indexPath.item])
    }
}

private final class RecordOptionsArrowView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.close()
        UIColor(white: 0.22, alpha: 0.92).setFill()
        path.fill()
    }
}
