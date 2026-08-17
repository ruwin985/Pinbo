import UIKit
import AVFoundation
import SnapKit

/// 首页：上方草稿网格（一排三个，可上下滚动），底部"去录制"呼吸动画圆形按钮。
final class HomeViewController: UIViewController {

    private var drafts: [RecordingProject] = []
    private lazy var collectionView: UICollectionView = makeCollectionView()
    private let recordButton = UIButton(type: .custom)
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
            showToast("编辑状态下不能录制，请先取消编辑")
            return
        }

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
            DraftStore.shared.delete(project.id)
            self.drafts.removeAll { $0.id == project.id }
            self.collectionView.reloadData()
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
