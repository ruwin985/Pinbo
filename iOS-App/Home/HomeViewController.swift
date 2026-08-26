import UIKit
import AVFoundation
import SnapKit
import WebKit

/// 首页：上方草稿网格（一排三个，可上下滚动），底部"去录制"呼吸动画圆形按钮。
final class HomeViewController: UIViewController {

    private var drafts: [RecordingProject] = []
    private lazy var collectionView: UICollectionView = makeCollectionView()
    private lazy var emptyStateView = makeEmptyStateView()
    private let recordButton = UIButton(type: .custom)
    private let recordOptionsBackdrop = UIControl()
    private let recordOptionsBubble = UIView()
    private let menuButton = UIButton(type: .system)
    private let sideMenuBackdrop = UIControl()
    private let sideMenuPanel = UIView()
    private let titleLabel = UILabel()
    private let editButton = UIButton(type: .system)
    private let profileMenuItems = ProfileMenuItem.allCases
    private var sideMenuLeadingConstraint: Constraint?
    private var isEditingDrafts = false
    private var sideMenuWidth: CGFloat { min(UIScreen.main.bounds.width * 0.82, 320) }

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
        menuButton.setTitle("=", for: .normal)
        menuButton.setTitleColor(.white, for: .normal)
        menuButton.titleLabel?.font = .systemFont(ofSize: 28, weight: .semibold)
        menuButton.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        menuButton.layer.cornerRadius = 18
        menuButton.layer.cornerCurve = .continuous
        menuButton.addTarget(self, action: #selector(sideMenuTapped), for: .touchUpInside)
        view.addSubview(menuButton)

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

        emptyStateView.isHidden = true
        view.addSubview(emptyStateView)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(draftLongPressed(_:)))
        collectionView.addGestureRecognizer(longPress)

        recordButton.applyAppPrimaryButtonStyle(cornerRadius: 36, shadow: true)
        recordButton.setImage(UIImage(systemName: "video.fill"), for: .normal)
        recordButton.addTarget(self, action: #selector(recordTapped), for: .touchUpInside)
        recordButton.layer.shadowOffset = .zero
        view.addSubview(recordButton)

        let hint = UILabel()
        hint.text = "去录制"
        hint.textColor = .white
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.textAlignment = .center
        view.addSubview(hint)

        menuButton.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(12)
            make.centerY.equalTo(titleLabel)
            make.size.equalTo(36)
        }

        titleLabel.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(12)
            make.leading.equalTo(menuButton.snp.trailing).offset(10)
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

        emptyStateView.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.centerY.equalToSuperview().offset(-28)
            make.leading.trailing.equalToSuperview().inset(36)
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
        setupSideMenu()
    }

    private func setupSideMenu() {
        sideMenuBackdrop.backgroundColor = UIColor.black.withAlphaComponent(0.46)
        sideMenuBackdrop.alpha = 0
        sideMenuBackdrop.isHidden = true
        sideMenuBackdrop.addTarget(self, action: #selector(sideMenuBackdropTapped), for: .touchUpInside)
        view.addSubview(sideMenuBackdrop)
        sideMenuBackdrop.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        sideMenuPanel.backgroundColor = UIColor(white: 0.08, alpha: 1)
        sideMenuPanel.layer.cornerRadius = 28
        sideMenuPanel.layer.cornerCurve = .continuous
        sideMenuPanel.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        sideMenuPanel.layer.shadowColor = UIColor.black.cgColor
        sideMenuPanel.layer.shadowOpacity = 0.32
        sideMenuPanel.layer.shadowRadius = 28
        sideMenuPanel.layer.shadowOffset = CGSize(width: 12, height: 0)
        sideMenuPanel.clipsToBounds = false
        sideMenuPanel.isHidden = true
        view.addSubview(sideMenuPanel)
        sideMenuPanel.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview()
            make.width.equalTo(sideMenuWidth)
            sideMenuLeadingConstraint = make.leading.equalToSuperview().offset(-sideMenuWidth).constraint
        }

        let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        blurView.layer.cornerRadius = 28
        blurView.layer.cornerCurve = .continuous
        blurView.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        blurView.clipsToBounds = true
        sideMenuPanel.addSubview(blurView)
        blurView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        let contentView = UIView()
        sideMenuPanel.addSubview(contentView)
        contentView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        let titleLabel = UILabel()
        titleLabel.text = "个人中心"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)

        let subtitleLabel = UILabel()
        subtitleLabel.text = "服务说明与账户帮助"
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.58)
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .medium)

        let headerStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        headerStack.axis = .vertical
        headerStack.spacing = 6
        contentView.addSubview(headerStack)
        headerStack.snp.makeConstraints { make in
            make.top.equalTo(contentView.safeAreaLayoutGuide).offset(26)
            make.leading.trailing.equalToSuperview().inset(22)
        }

        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.spacing = 8

        for (index, item) in profileMenuItems.enumerated() {
            let itemView = ProfileMenuItemView(item: item)
            itemView.tag = index
            itemView.addTarget(self, action: #selector(sideMenuItemTapped(_:)), for: .touchUpInside)
            stackView.addArrangedSubview(itemView)
            itemView.snp.makeConstraints { make in
                make.height.equalTo(54)
            }
        }

        let scrollView = UIScrollView()
        scrollView.showsVerticalScrollIndicator = false
        contentView.addSubview(scrollView)
        scrollView.snp.makeConstraints { make in
            make.top.equalTo(headerStack.snp.bottom).offset(28)
            make.leading.trailing.equalToSuperview()
            make.bottom.equalTo(contentView.safeAreaLayoutGuide).inset(24)
        }

        scrollView.addSubview(stackView)
        stackView.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview()
            make.leading.trailing.equalToSuperview().inset(14)
            make.width.equalToSuperview().offset(-28)
        }
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
        iconView.tintColor = AppTheme.primary
        iconView.contentMode = .scaleAspectFit
        iconView.backgroundColor = AppTheme.primary.withAlphaComponent(0.18)
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

    private func makeEmptyStateView() -> UIView {
        let container = UIView()
        container.isUserInteractionEnabled = false

        let iconView = UIImageView(image: UIImage(systemName: "video.badge.plus"))
        iconView.tintColor = UIColor.white.withAlphaComponent(0.5)
        iconView.contentMode = .scaleAspectFit

        let titleLabel = UILabel()
        titleLabel.text = "还没有作品"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textAlignment = .center

        let subtitleLabel = UILabel()
        subtitleLabel.text = "快去拍摄吧，记录你的第一个视频"
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.58)
        subtitleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0

        let stackView = UIStackView(arrangedSubviews: [iconView, titleLabel, subtitleLabel])
        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.spacing = 10
        container.addSubview(stackView)

        iconView.snp.makeConstraints { make in
            make.size.equalTo(42)
        }
        stackView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        return container
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
        updateEmptyStateVisibility(animated: false)
    }

    private func updateEmptyStateVisibility(animated: Bool) {
        let shouldShowEmptyState = drafts.isEmpty
        if shouldShowEmptyState {
            emptyStateView.isHidden = false
        }
        let changes = {
            self.emptyStateView.alpha = shouldShowEmptyState ? 1 : 0
        }
        let completion: (Bool) -> Void = { _ in
            self.emptyStateView.isHidden = !shouldShowEmptyState
        }
        if animated {
            UIView.animate(withDuration: 0.2,
                           delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction],
                           animations: changes,
                           completion: completion)
        } else {
            changes()
            completion(true)
        }
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

    @objc private func sideMenuTapped() {
        showSideMenu()
    }

    @objc private func sideMenuBackdropTapped() {
        hideSideMenu(animated: true)
    }

    @objc private func sideMenuItemTapped(_ sender: UIControl) {
        guard profileMenuItems.indices.contains(sender.tag) else { return }
        let item = profileMenuItems[sender.tag]
        hideSideMenu(animated: true) { [weak self] in
            self?.handleProfileMenuItem(item)
        }
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

    private func showSideMenu() {
        hideRecordOptions(animated: true)
        if isEditingDrafts { setEditingDrafts(false) }

        sideMenuBackdrop.isHidden = false
        sideMenuPanel.isHidden = false
        view.bringSubviewToFront(sideMenuBackdrop)
        view.bringSubviewToFront(sideMenuPanel)
        view.layoutIfNeeded()

        sideMenuLeadingConstraint?.update(offset: 0)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        UIView.animate(withDuration: 0.38,
                       delay: 0,
                       usingSpringWithDamping: 0.86,
                       initialSpringVelocity: 0.55,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.sideMenuBackdrop.alpha = 1
            self.view.layoutIfNeeded()
        }
    }

    private func hideSideMenu(animated: Bool, completion: (() -> Void)? = nil) {
        guard !sideMenuPanel.isHidden else {
            completion?()
            return
        }

        sideMenuLeadingConstraint?.update(offset: -sideMenuWidth)
        let animations = {
            self.sideMenuBackdrop.alpha = 0
            self.view.layoutIfNeeded()
        }
        let finish: (Bool) -> Void = { _ in
            self.sideMenuBackdrop.isHidden = true
            self.sideMenuPanel.isHidden = true
            completion?()
        }

        if animated {
            UIView.animate(withDuration: 0.22,
                           delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut],
                           animations: animations,
                           completion: finish)
        } else {
            animations()
            finish(true)
        }
    }

    private func handleProfileMenuItem(_ item: ProfileMenuItem) {
        switch item {
        case .clearCache:
            presentClearCacheConfirmation()
        default:
            openProfileDocument(for: item)
        }
    }

    private func openProfileDocument(for item: ProfileMenuItem,
                                     cacheCleared: Bool = false,
                                     cleanupResult: AppStorageCleanupResult? = nil) {
        let controller = ProfileDocumentViewController(document: item.makeDocument(cacheCleared: cacheCleared,
                                                                                   cleanupResult: cleanupResult))
        navigationController?.pushViewController(controller, animated: true)
    }

    private func presentClearCacheConfirmation() {
        presentAppConfirmation(title: "清除缓存？",
                               message: "将清除临时录制文件、网页缓存和首页不可见的无效草稿残留，不会删除首页作品或相册视频。",
                               confirmTitle: "清除",
                               confirmStyle: .destructive) { [weak self] in
            self?.clearAppCache()
        }
    }

    private func clearAppCache() {
        AppStorageCleaner.clearCache(preserving: drafts) { [weak self] result in
            guard let self else { return }
            self.reloadDrafts()
            self.openProfileDocument(for: .clearCache, cacheCleared: true, cleanupResult: result)
        }
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
                self.updateEmptyStateVisibility(animated: true)
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

private enum ProfileMenuItem: CaseIterable {
    case about
    case versionUpdate
    case feedback
    case clearCache
    case privacyPolicy
    case userAgreement
    case childrenPrivacy
    case personalInfoList
    case thirdPartySharingList

    var title: String {
        switch self {
        case .about: return "关于我们"
        case .versionUpdate: return "版本更新"
        case .feedback: return "反馈"
        case .clearCache: return "清除缓存"
        case .privacyPolicy: return "隐私政策"
        case .userAgreement: return "用户协议"
        case .childrenPrivacy: return "儿童隐私保护声明"
        case .personalInfoList: return "个人信息收集清单"
        case .thirdPartySharingList: return "第三方信息共享清单"
        }
    }

    var iconName: String {
        switch self {
        case .about: return "info.circle.fill"
        case .versionUpdate: return "arrow.triangle.2.circlepath.circle.fill"
        case .feedback: return "bubble.left.and.bubble.right.fill"
        case .clearCache: return "trash.fill"
        case .privacyPolicy: return "lock.shield.fill"
        case .userAgreement: return "doc.text.fill"
        case .childrenPrivacy: return "person.2.fill"
        case .personalInfoList: return "list.bullet"
        case .thirdPartySharingList: return "person.3.fill"
        }
    }

    var tintColor: UIColor {
        switch self {
        case .about: return UIColor(red: 0.36, green: 0.72, blue: 1, alpha: 1)
        case .versionUpdate: return UIColor(red: 0.48, green: 0.78, blue: 1, alpha: 1)
        case .feedback: return UIColor(red: 0.42, green: 0.92, blue: 0.68, alpha: 1)
        case .clearCache: return UIColor(red: 1, green: 0.58, blue: 0.36, alpha: 1)
        case .privacyPolicy: return UIColor(red: 0.76, green: 0.64, blue: 1, alpha: 1)
        case .userAgreement: return UIColor(red: 1, green: 0.82, blue: 0.36, alpha: 1)
        case .childrenPrivacy: return UIColor(red: 1, green: 0.5, blue: 0.72, alpha: 1)
        case .personalInfoList: return UIColor(red: 0.52, green: 0.86, blue: 1, alpha: 1)
        case .thirdPartySharingList: return UIColor(red: 0.72, green: 1, blue: 0.56, alpha: 1)
        }
    }

    func makeDocument(cacheCleared: Bool = false,
                      cleanupResult: AppStorageCleanupResult? = nil) -> ProfileHTMLDocument {
        switch self {
        case .about:
            return ProfileHTMLDocument(
                title: title,
                summary: "了解 Pinbo 的产品定位、核心能力和当前版本。",
                sections: [
                    ProfileHTMLSection(
                        heading: "产品定位",
                        paragraphs: ["Pinbo 是一款面向手机端的视频录制、屏幕录制和作品管理工具，帮助用户快速完成拍摄、整理与本地草稿管理。"]
                    ),
                    ProfileHTMLSection(
                        heading: "主要功能",
                        bullets: [
                            "摄像头录制：支持前后摄同框拍摄。",
                            "屏幕录制：支持屏幕录制与前摄悬浮窗。",
                            "作品管理：支持在首页查看、编辑、删除本地作品草稿。"
                        ]
                    ),
                    ProfileHTMLSection(
                        heading: "版本信息",
                        paragraphs: ["当前版本：\(Bundle.main.pinboVersionText)。"]
                    )
                ]
            )
        case .versionUpdate:
            return ProfileHTMLDocument(
                title: title,
                summary: "查看当前安装版本和后续更新方式。",
                sections: [
                    ProfileHTMLSection(
                        heading: "当前版本",
                        paragraphs: ["当前版本：\(Bundle.main.pinboVersionText)。"]
                    ),
                    ProfileHTMLSection(
                        heading: "更新说明",
                        bullets: [
                            "如果通过 TestFlight 或企业分发安装，请在对应分发渠道获取最新版本。",
                            "如果后续上架 App Store，可以在这里接入 App Store 跳转或在线版本检测。",
                            "更新前建议先确认重要作品已经保存到相册或保留在首页草稿中。"
                        ]
                    )
                ]
            )
        case .feedback:
            return ProfileHTMLDocument(
                title: title,
                summary: "提交问题、建议或使用体验反馈，帮助我们持续优化产品。",
                sections: [
                    ProfileHTMLSection(
                        heading: "反馈范围",
                        bullets: [
                            "录制、屏幕录制、作品编辑或保存过程中遇到的问题。",
                            "交互体验、功能建议、性能表现或兼容性问题。",
                            "隐私、安全、未成年人保护等合规相关疑问。"
                        ]
                    ),
                    ProfileHTMLSection(
                        heading: "建议提供的信息",
                        bullets: [
                            "问题出现的步骤、截图或录屏说明。",
                            "设备型号、iOS 系统版本和 App 版本。",
                            "是否可以稳定复现，以及复现频率。"
                        ]
                    ),
                    ProfileHTMLSection(
                        heading: "隐私提示",
                        paragraphs: ["反馈时请避免提交身份证件、银行卡、通讯录、精确定位等与问题无关的敏感信息。"]
                    )
                ]
            )
        case .clearCache:
            let cleanedSizeText = cleanupResult?.formattedRemovedSize ?? "0 KB"
            let cleanedItemCount = cleanupResult?.removedItemCount ?? 0
            return ProfileHTMLDocument(
                title: title,
                summary: cacheCleared ? "缓存已清除完成，作品草稿不会被删除。" : "清除临时缓存，释放本地存储空间。",
                sections: [
                    ProfileHTMLSection(
                        heading: cacheCleared ? "已处理内容" : "清理内容",
                        bullets: [
                            cacheCleared ? "本次预估释放 \(cleanedSizeText)，清除 \(cleanedItemCount) 个本地项目。" : "将清除 App 缓存目录中的临时文件。",
                            "将清除系统 URL 缓存和网页说明页缓存。",
                            "将清除屏幕录制导入残留、临时录制文件和首页不可见的无效草稿目录。"
                        ]
                    ),
                    ProfileHTMLSection(
                        heading: "不会删除",
                        bullets: [
                            "不会删除首页中的作品草稿。",
                            "不会删除已保存到相册的视频。",
                            "不会重置相机、麦克风或相册授权状态。"
                        ]
                    ),
                    ProfileHTMLSection(
                        heading: "后续影响",
                        paragraphs: ["清除后首次打开部分页面或重新生成临时预览时，可能会短暂重新加载。iOS 设置中的“文稿与数据”刷新可能存在延迟，可退出设置后稍后再查看。"]
                    )
                ]
            )
        case .privacyPolicy:
            return ProfileHTMLDocument(
                title: title,
                summary: "说明 Pinbo 如何处理权限、作品文件、缓存和必要的本地信息。",
                sections: [
                    ProfileHTMLSection(
                        heading: "信息收集与使用",
                        paragraphs: ["Pinbo 仅在提供录制、编辑、保存和作品管理功能所必需的范围内处理信息。录制生成的视频、草稿元数据和临时文件默认保存在设备本地。"]
                    ),
                    ProfileHTMLSection(
                        heading: "权限说明",
                        bullets: [
                            "相机：用于摄像头录制和前摄悬浮窗。",
                            "麦克风：用于录制声音。",
                            "相册：用于将导出视频保存到系统相册。",
                            "屏幕录制：用于录制手机屏幕内容。"
                        ]
                    ),
                    ProfileHTMLSection(
                        heading: "存储与删除",
                        paragraphs: ["用户可以在首页删除本地作品草稿，也可以通过系统设置管理 App 权限。清理缓存不会删除作品草稿或相册中的视频。"]
                    ),
                    ProfileHTMLSection(
                        heading: "政策更新",
                        paragraphs: ["如产品功能、数据处理范围或第三方服务发生变化，我们会更新本页面并以适当方式提示用户。"]
                    )
                ]
            )
        case .userAgreement:
            return ProfileHTMLDocument(
                title: title,
                summary: "使用 Pinbo 前，请了解服务内容、用户责任和作品权利说明。",
                sections: [
                    ProfileHTMLSection(
                        heading: "服务内容",
                        paragraphs: ["Pinbo 提供手机端录制、屏幕录制、作品草稿管理和基础编辑能力。具体功能可能会随版本迭代调整。"]
                    ),
                    ProfileHTMLSection(
                        heading: "用户责任",
                        bullets: [
                            "请确保录制内容不侵犯他人肖像权、隐私权、著作权或其他合法权益。",
                            "请勿使用本服务制作、传播违法违规或侵害他人权益的内容。",
                            "请妥善管理设备、作品文件和系统授权。"
                        ]
                    ),
                    ProfileHTMLSection(
                        heading: "作品权利",
                        paragraphs: ["用户通过 Pinbo 录制或编辑的作品权利归属由用户及相关权利人依法确定。Pinbo 不会因提供工具服务而主张用户作品版权。"]
                    ),
                    ProfileHTMLSection(
                        heading: "免责声明",
                        paragraphs: ["因设备存储不足、系统限制、用户误删、第三方环境变化等原因导致的录制失败或数据丢失，请用户及时备份重要作品。"]
                    )
                ]
            )
        case .childrenPrivacy:
            return ProfileHTMLDocument(
                title: title,
                summary: "面向不满十四周岁儿童及其监护人的隐私保护说明。",
                sections: [
                    ProfileHTMLSection(
                        heading: "监护人同意",
                        paragraphs: ["若儿童使用 Pinbo，请在监护人知情并同意的前提下使用。监护人应指导儿童避免录制或分享包含个人敏感信息的内容。"]
                    ),
                    ProfileHTMLSection(
                        heading: "儿童信息处理原则",
                        bullets: [
                            "坚持最小必要原则，仅为实现录制、编辑、保存等功能处理必要信息。",
                            "默认将作品草稿保存在设备本地，不主动公开儿童个人信息。",
                            "不鼓励儿童在反馈中提交姓名、学校、住址、联系方式等敏感信息。"
                        ]
                    ),
                    ProfileHTMLSection(
                        heading: "监护人管理",
                        paragraphs: ["监护人可以通过首页删除本地草稿，通过系统设置关闭相机、麦克风、相册或屏幕录制相关权限。"]
                    )
                ]
            )
        case .personalInfoList:
            return ProfileHTMLDocument(
                title: title,
                summary: "列明当前功能可能涉及的个人信息类型、使用目的和触发场景。",
                sections: [
                    ProfileHTMLSection(
                        heading: "摄像头与麦克风信息",
                        bullets: [
                            "使用目的：完成摄像头录制、声音录制和前摄悬浮窗。",
                            "触发场景：用户主动点击录制并授权后。",
                            "处理方式：录制内容生成视频文件并保存在本地或由用户导出。"
                        ]
                    ),
                    ProfileHTMLSection(
                        heading: "屏幕录制内容",
                        bullets: [
                            "使用目的：录制用户主动选择的屏幕内容。",
                            "触发场景：用户主动发起屏幕录制并完成系统确认后。",
                            "处理方式：录制结果用于生成本地作品。"
                        ]
                    ),
                    ProfileHTMLSection(
                        heading: "相册访问",
                        bullets: [
                            "使用目的：将导出视频保存到系统相册。",
                            "触发场景：用户主动保存视频并授权后。",
                            "处理方式：仅在保存动作中调用系统相册能力。"
                        ]
                    ),
                    ProfileHTMLSection(
                        heading: "本地作品与缓存",
                        bullets: [
                            "使用目的：保存草稿、恢复编辑状态和提升页面加载效率。",
                            "存储位置：设备本地 Documents 与 Caches 目录。",
                            "用户控制：可删除作品草稿，也可在侧边栏清除缓存。"
                        ]
                    )
                ]
            )
        case .thirdPartySharingList:
            return ProfileHTMLDocument(
                title: title,
                summary: "说明当前版本中第三方信息共享、系统能力调用和后续更新规则。",
                sections: [
                    ProfileHTMLSection(
                        heading: "当前共享情况",
                        bullets: [
                            "当前版本未接入广告、统计、社交分享等第三方 SDK 用于个人信息共享。",
                            "不会主动向第三方出售、出租或公开披露用户作品内容。",
                            "如后续新增第三方服务，将在本清单中说明服务名称、共享目的、信息类型和处理方式。"
                        ]
                    ),
                    ProfileHTMLSection(
                        heading: "系统能力调用",
                        bullets: [
                            "相册保存由 iOS 系统 Photos 能力完成，仅在用户授权和主动保存时调用。",
                            "屏幕录制由 iOS 系统录屏能力完成，仅在用户主动确认后开启。",
                            "相机与麦克风由 iOS 系统权限管理，用户可随时在系统设置中关闭。"
                        ]
                    ),
                    ProfileHTMLSection(
                        heading: "用户选择",
                        paragraphs: ["如不同意相关系统权限调用，可以拒绝授权或在系统设置中关闭；关闭后对应功能可能无法正常使用。"]
                    )
                ]
            )
        }
    }
}

private final class ProfileMenuItemView: UIControl {
    private let iconContainer = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let chevronView = UIImageView(image: UIImage(systemName: "chevron.right"))

    init(item: ProfileMenuItem) {
        super.init(frame: .zero)
        setupUI(item: item)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.16,
                           delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.backgroundColor = UIColor.white.withAlphaComponent(self.isHighlighted ? 0.16 : 0.08)
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.985, y: 0.985) : .identity
            }
        }
    }

    private func setupUI(item: ProfileMenuItem) {
        backgroundColor = UIColor.white.withAlphaComponent(0.08)
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous

        iconContainer.backgroundColor = item.tintColor.withAlphaComponent(0.16)
        iconContainer.layer.cornerRadius = 15
        iconContainer.layer.cornerCurve = .continuous
        addSubview(iconContainer)
        iconContainer.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(12)
            make.centerY.equalToSuperview()
            make.size.equalTo(30)
        }

        iconView.image = UIImage(systemName: item.iconName)
        iconView.tintColor = item.tintColor
        iconView.contentMode = .scaleAspectFit
        iconContainer.addSubview(iconView)
        iconView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.size.equalTo(16)
        }

        titleLabel.text = item.title
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        addSubview(titleLabel)
        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(iconContainer.snp.trailing).offset(12)
            make.centerY.equalToSuperview()
        }

        chevronView.tintColor = UIColor.white.withAlphaComponent(0.32)
        chevronView.contentMode = .scaleAspectFit
        addSubview(chevronView)
        chevronView.snp.makeConstraints { make in
            make.leading.greaterThanOrEqualTo(titleLabel.snp.trailing).offset(8)
            make.trailing.equalToSuperview().inset(14)
            make.centerY.equalToSuperview()
            make.width.equalTo(8)
            make.height.equalTo(14)
        }
    }
}

private final class ProfileDocumentViewController: UIViewController {
    private let document: ProfileHTMLDocument
    private let webView: WKWebView

    init(document: ProfileHTMLDocument) {
        self.document = document
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        webView.loadHTMLString(document.html, baseURL: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    private func setupUI() {
        let topBar = UIView()
        topBar.backgroundColor = UIColor(white: 0.05, alpha: 1)
        view.addSubview(topBar)
        topBar.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.bottom.equalTo(view.safeAreaLayoutGuide.snp.top).offset(54)
        }

        let backButton = UIButton(type: .system)
        backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        backButton.setTitle("返回", for: .normal)
        backButton.tintColor = .white
        backButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        topBar.addSubview(backButton)
        backButton.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(10)
            make.bottom.equalToSuperview().inset(7)
            make.height.equalTo(40)
        }

        let titleLabel = UILabel()
        titleLabel.text = document.title
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 17, weight: .bold)
        titleLabel.textAlignment = .center
        topBar.addSubview(titleLabel)
        titleLabel.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.centerY.equalTo(backButton)
            make.leading.greaterThanOrEqualTo(backButton.snp.trailing).offset(8)
            make.trailing.lessThanOrEqualToSuperview().inset(16)
        }

        webView.backgroundColor = .black
        webView.isOpaque = false
        webView.scrollView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(webView)
        webView.snp.makeConstraints { make in
            make.top.equalTo(topBar.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }
    }

    @objc private func backTapped() {
        navigationController?.popViewController(animated: true)
    }
}

private struct ProfileHTMLDocument {
    let title: String
    let summary: String
    let sections: [ProfileHTMLSection]

    var html: String {
        let sectionHTML = sections.map { section in
            var sectionContent = "<section><h2>\(section.heading.escapedHTML)</h2>"
            sectionContent += section.paragraphs.map { "<p>\($0.escapedHTML)</p>" }.joined()
            if !section.bullets.isEmpty {
                sectionContent += "<ul>"
                sectionContent += section.bullets.map { "<li>\($0.escapedHTML)</li>" }.joined()
                sectionContent += "</ul>"
            }
            sectionContent += "</section>"
            return sectionContent
        }.joined()

        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <style>
        :root { color-scheme: dark; }
        * { box-sizing: border-box; }
        body {
            margin: 0;
            padding: 0;
            background: #050507;
            color: rgba(255, 255, 255, 0.88);
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Helvetica Neue", Arial, sans-serif;
            line-height: 1.72;
        }
        main {
            padding: 28px 20px calc(42px + env(safe-area-inset-bottom));
            max-width: 720px;
            margin: 0 auto;
        }
        .eyebrow {
            display: inline-flex;
            padding: 5px 10px;
            border-radius: 999px;
            background: rgba(255, 255, 255, 0.1);
            color: rgba(255, 255, 255, 0.58);
            font-size: 12px;
            font-weight: 700;
            letter-spacing: 0.04em;
        }
        h1 {
            margin: 16px 0 10px;
            color: #fff;
            font-size: 30px;
            line-height: 1.18;
            letter-spacing: -0.03em;
        }
        .summary {
            margin: 0;
            color: rgba(255, 255, 255, 0.62);
            font-size: 16px;
        }
        .meta {
            margin-top: 14px;
            color: rgba(255, 255, 255, 0.38);
            font-size: 12px;
        }
        section {
            margin-top: 18px;
            padding: 18px;
            border: 1px solid rgba(255, 255, 255, 0.1);
            border-radius: 22px;
            background: linear-gradient(180deg, rgba(255, 255, 255, 0.08), rgba(255, 255, 255, 0.045));
        }
        h2 {
            margin: 0 0 10px;
            color: #fff;
            font-size: 18px;
            line-height: 1.3;
        }
        p { margin: 0 0 10px; }
        p:last-child { margin-bottom: 0; }
        ul {
            margin: 0;
            padding-left: 20px;
        }
        li { margin: 6px 0; }
        footer {
            margin-top: 20px;
            color: rgba(255, 255, 255, 0.34);
            font-size: 12px;
        }
        </style>
        </head>
        <body>
        <main>
            <div class="eyebrow">PINBO 服务说明</div>
            <h1>\(title.escapedHTML)</h1>
            <p class="summary">\(summary.escapedHTML)</p>
            <div class="meta">更新时间：\(ProfileHTMLDocument.updateDateText)</div>
            \(sectionHTML)
            <footer>本页面用于说明 Pinbo App 内相关功能与规则。如后续功能或数据处理方式发生变化，请以 App 内更新后的说明为准。</footer>
        </main>
        </body>
        </html>
        """
    }

    private static var updateDateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

private struct ProfileHTMLSection {
    let heading: String
    let paragraphs: [String]
    let bullets: [String]

    init(heading: String, paragraphs: [String] = [], bullets: [String] = []) {
        self.heading = heading
        self.paragraphs = paragraphs
        self.bullets = bullets
    }
}

private extension Bundle {
    var pinboVersionText: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}

private extension String {
    var escapedHTML: String {
        var escapedText = self
        escapedText = escapedText.replacingOccurrences(of: "&", with: "&amp;")
        escapedText = escapedText.replacingOccurrences(of: "<", with: "&lt;")
        escapedText = escapedText.replacingOccurrences(of: ">", with: "&gt;")
        escapedText = escapedText.replacingOccurrences(of: "\"", with: "&quot;")
        escapedText = escapedText.replacingOccurrences(of: "'", with: "&#39;")
        return escapedText
    }
}
