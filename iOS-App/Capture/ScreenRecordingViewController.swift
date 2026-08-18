import UIKit
import AVFoundation
import AVKit
import Photos
import ReplayKit
import SnapKit

/// 手机端屏幕录制页：用户手动开启前摄悬浮窗，点击中间按钮开始/结束系统录屏。
final class ScreenRecordingViewController: UIViewController {
    private enum Constants {
        static let broadcastExtensionBundleIdentifier = "com.pinbo.app.ScreenBroadcastExtension"
        static let recordingImportDirectoryName = "ScreenRecordingImports"
        static let recordingFilePrefix = "Pinbo-ScreenRecording-"
    }

    private let previewBackdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let recordButton = UIButton(type: .system)
    private let systemBroadcastPicker = RPSystemBroadcastPickerView(frame: .zero)
    private let cameraToggleButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let hintLabel = UILabel()
    private let durationLabel = UILabel()
    private let cameraContainer = UIView()
    private let pictureInPictureSourceView = UIView()

    private let frontCameraSession = FrontCameraSessionController()
    private var pictureInPictureController: AVPictureInPictureController?
    private var pictureInPictureContentViewController: AnyObject?
    private var pictureInPictureCameraViewController: AnyObject?
    private var recordingStartDate: Date?
    private var durationTimer: Timer?
    private var isFrontCameraEnabled = false
    private var isSystemRecordingActive = false
    private var hasRequestedPhotoPermission = false
    private var screenRecordingLookupStartDate: Date?
    private var savingAssetIdentifier: String?
    private var isHandlingPiPRestore = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 1, green: 0.37, blue: 0.31, alpha: 1)
        navigationController?.setNavigationBarHidden(true, animated: false)
        setupUI()
        configureCameraPictureInPictureIfAvailable()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appWillResignActive),
                                               name: UIApplication.willResignActiveNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(screenCaptureDidChange),
                                               name: UIScreen.capturedDidChangeNotification,
                                               object: UIScreen.main)
        updateRecordingState()
        updateCameraState(animated: false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        configureSystemBroadcastPickerAppearance()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        requestPhotoPermissionIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || isBeingDismissed {
            stopDurationTimer()
            isFrontCameraEnabled = false
            setPictureInPictureAutoStartEnabled(false)
            pictureInPictureController?.stopPictureInPicture()
            frontCameraSession.stopRunning()
            deactivatePictureInPictureAudioSession()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stopDurationTimer()
    }

    override var prefersStatusBarHidden: Bool { false }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: - UI

    private func setupUI() {
        setupGradientBackground()

        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        closeButton.layer.cornerRadius = 18
        closeButton.layer.cornerCurve = .continuous
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        let titleLabel = UILabel()
        titleLabel.text = "屏幕录制"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.textAlignment = .center
        view.addSubview(titleLabel)

        cameraToggleButton.setTitle("开启前置摄像头", for: .normal)
        cameraToggleButton.setTitleColor(.white, for: .normal)
        cameraToggleButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        cameraToggleButton.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        cameraToggleButton.layer.cornerRadius = 22
        cameraToggleButton.layer.cornerCurve = .continuous
        cameraToggleButton.layer.borderWidth = 0.7
        cameraToggleButton.layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor
        cameraToggleButton.setImage(UIImage(systemName: "video.badge.plus"), for: .normal)
        cameraToggleButton.tintColor = .white
        cameraToggleButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: -6, bottom: 0, right: 6)
        cameraToggleButton.addTarget(self, action: #selector(cameraToggleTapped), for: .touchUpInside)
        view.addSubview(cameraToggleButton)

        hintLabel.text = "点击中间按钮开始录制屏幕\n需要露脸时，先点上方按钮开启前摄悬浮窗"
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.82)
        hintLabel.font = .systemFont(ofSize: 14, weight: .medium)
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0
        view.addSubview(hintLabel)

        durationLabel.text = "00:00"
        durationLabel.textColor = .white
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        durationLabel.textAlignment = .center
        durationLabel.alpha = 0
        view.addSubview(durationLabel)

        recordButton.backgroundColor = .white
        recordButton.layer.cornerRadius = 46
        recordButton.layer.cornerCurve = .continuous
        recordButton.layer.shadowColor = UIColor.black.cgColor
        recordButton.layer.shadowOpacity = 0.18
        recordButton.layer.shadowRadius = 18
        recordButton.layer.shadowOffset = CGSize(width: 0, height: 8)
        recordButton.isUserInteractionEnabled = false
        view.addSubview(recordButton)

        systemBroadcastPicker.preferredExtension = Constants.broadcastExtensionBundleIdentifier
        systemBroadcastPicker.showsMicrophoneButton = true
        systemBroadcastPicker.backgroundColor = .clear
        systemBroadcastPicker.tintColor = UIColor(red: 1, green: 0.25, blue: 0.35, alpha: 1)
        systemBroadcastPicker.accessibilityLabel = "打开系统录屏"
        view.addSubview(systemBroadcastPicker)
        configureSystemBroadcastPickerAppearance()

        statusLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        view.addSubview(statusLabel)

        setupPreviewBackdrop()
        setupCameraContainer()
        setupPictureInPictureSourceView()

        closeButton.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(12)
            make.leading.equalToSuperview().offset(18)
            make.size.equalTo(36)
        }

        titleLabel.snp.makeConstraints { make in
            make.centerY.equalTo(closeButton)
            make.centerX.equalToSuperview()
        }

        cameraToggleButton.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(18)
            make.centerX.equalToSuperview()
            make.width.equalTo(190)
            make.height.equalTo(44)
        }

        hintLabel.snp.makeConstraints { make in
            make.top.equalTo(cameraToggleButton.snp.bottom).offset(38)
            make.leading.trailing.equalToSuperview().inset(32)
        }

        durationLabel.snp.makeConstraints { make in
            make.top.equalTo(hintLabel.snp.bottom).offset(16)
            make.centerX.equalToSuperview()
        }

        recordButton.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.centerY.equalToSuperview().offset(52)
            make.size.equalTo(92)
        }

        systemBroadcastPicker.snp.makeConstraints { make in
            make.edges.equalTo(recordButton)
        }

        statusLabel.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(32)
            make.bottom.equalTo(view.safeAreaLayoutGuide).inset(24)
        }

    }

    private func setupGradientBackground() {
        let gradient = CAGradientLayer()
        gradient.colors = [
            UIColor(red: 1, green: 0.31, blue: 0.36, alpha: 1).cgColor,
            UIColor(red: 1, green: 0.47, blue: 0.34, alpha: 1).cgColor,
            UIColor(red: 1, green: 0.63, blue: 0.43, alpha: 1).cgColor
        ]
        gradient.startPoint = CGPoint(x: 0.2, y: 0)
        gradient.endPoint = CGPoint(x: 0.8, y: 1)
        gradient.frame = UIScreen.main.bounds
        view.layer.insertSublayer(gradient, at: 0)
    }

    private func setupPreviewBackdrop() {
        previewBackdrop.layer.cornerRadius = 32
        previewBackdrop.layer.cornerCurve = .continuous
        previewBackdrop.clipsToBounds = true
        previewBackdrop.alpha = 0.48
        previewBackdrop.isUserInteractionEnabled = false
        view.insertSubview(previewBackdrop, at: 0)
        previewBackdrop.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(22)
            make.top.equalTo(view.safeAreaLayoutGuide).offset(152)
            make.bottom.equalTo(view.safeAreaLayoutGuide).inset(126)
        }
    }

    private func setupCameraContainer() {
        cameraContainer.isHidden = true
        cameraContainer.alpha = 0
        view.addSubview(cameraContainer)
        cameraContainer.snp.makeConstraints { make in
            make.width.height.equalTo(2)
            make.trailing.equalToSuperview().inset(2)
            make.bottom.equalTo(view.safeAreaLayoutGuide).inset(2)
        }
    }

    private func setupPictureInPictureSourceView() {
        pictureInPictureSourceView.backgroundColor = .clear
        pictureInPictureSourceView.alpha = 0.01
        pictureInPictureSourceView.isUserInteractionEnabled = false
        view.addSubview(pictureInPictureSourceView)
        pictureInPictureSourceView.snp.makeConstraints { make in
            make.width.height.equalTo(2)
            make.trailing.equalToSuperview().inset(2)
            make.bottom.equalTo(view.safeAreaLayoutGuide).inset(2)
        }
    }

    // MARK: - Recorder

    private func configureSystemBroadcastPickerAppearance() {
        systemBroadcastPicker.preferredExtension = Constants.broadcastExtensionBundleIdentifier
        for subview in systemBroadcastPicker.subviews {
            if let button = subview as? UIButton {
                button.frame = systemBroadcastPicker.bounds
                button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                button.backgroundColor = .clear
                button.tintColor = systemBroadcastPicker.tintColor
                button.contentHorizontalAlignment = .center
                button.contentVerticalAlignment = .center
                button.isUserInteractionEnabled = true
            }
        }
    }

    private func requestPhotoPermissionIfNeeded() {
        guard !hasRequestedPhotoPermission, !PermissionManager.photoGranted else { return }
        hasRequestedPhotoPermission = true
        PermissionManager.requestPhoto { [weak self] granted in
            guard !granted else { return }
            self?.statusLabel.text = "相册未授权，停止录制后可能无法保存草稿"
        }
    }

    private func configureCameraPictureInPictureIfAvailable() {
        guard #available(iOS 15.0, *) else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let contentViewController = AVPictureInPictureVideoCallViewController()
        contentViewController.preferredContentSize = CGSize(width: 136, height: 190)
        contentViewController.view.backgroundColor = .black
        contentViewController.view.isUserInteractionEnabled = true

        let cameraViewController = PiPCameraViewController(cameraSession: frontCameraSession)
        cameraViewController.onCloseTapped = { [weak self] in
            self?.closeFrontCameraFromPictureInPicture()
        }
        contentViewController.addChild(cameraViewController)
        contentViewController.view.addSubview(cameraViewController.view)
        cameraViewController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        cameraViewController.didMove(toParent: contentViewController)

        let source = AVPictureInPictureController.ContentSource(activeVideoCallSourceView: pictureInPictureSourceView,
                                                               contentViewController: contentViewController)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        if #available(iOS 14.0, *) {
            controller.requiresLinearPlayback = true
        }
        pictureInPictureController = controller
        pictureInPictureContentViewController = contentViewController
        pictureInPictureCameraViewController = cameraViewController
    }

    private func startCameraPictureInPictureIfPossible() {
        guard isFrontCameraEnabled else { return }
        guard #available(iOS 15.0, *) else { return }
        guard let controller = pictureInPictureController,
              controller.isPictureInPicturePossible,
              !controller.isPictureInPictureActive else { return }
        activatePictureInPictureAudioSession()
        frontCameraSession.startRunning()
        controller.startPictureInPicture()
    }

    private func retryStartCameraPictureInPictureIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.startCameraPictureInPictureIfPossible()
        }
    }

    private func enableFrontCamera() {
        guard !isFrontCameraEnabled else { return }
        guard PermissionManager.cameraGranted else {
            PermissionManager.requestCamera { [weak self] granted in
                guard granted else {
                    self?.showAlert("无法开启前摄", "请在系统设置中允许拍呗访问相机。")
                    return
                }
                self?.enableFrontCamera()
            }
            return
        }
        isFrontCameraEnabled = true
        setPictureInPictureAutoStartEnabled(true)
        activatePictureInPictureAudioSession()
        frontCameraSession.startRunning { [weak self] isStarted in
            guard let self, self.isFrontCameraEnabled else { return }
            if isStarted {
                self.statusLabel.text = self.isSystemRecordingActive ? "系统录屏中" : "前摄浮窗已开启，可切到桌面"
            } else {
                self.statusLabel.text = "无法启动前摄，请确认设备相机可用"
            }
        }
        updateCameraState(animated: true)
        startCameraPictureInPictureIfPossible()
        retryStartCameraPictureInPictureIfNeeded()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func disableFrontCamera() {
        guard isFrontCameraEnabled else { return }
        isFrontCameraEnabled = false
        pictureInPictureController?.stopPictureInPicture()
        setPictureInPictureAutoStartEnabled(false)
        frontCameraSession.stopRunning()
        deactivatePictureInPictureAudioSession()
        updateCameraState(animated: true)
    }

    private func stopFrontCameraAfterPictureInPictureClosed() {
        isFrontCameraEnabled = false
        setPictureInPictureAutoStartEnabled(false)
        frontCameraSession.stopRunning()
        deactivatePictureInPictureAudioSession()
        updateCameraState(animated: true)
        statusLabel.text = isSystemRecordingActive ? "系统录屏中，前摄已关闭" : "前摄已关闭"
    }

    private func activatePictureInPictureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord,
                                                            mode: .videoChat,
                                                            options: [.defaultToSpeaker, .allowBluetoothHFP])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            statusLabel.text = "前摄已开启，浮窗音频会话启动失败"
        }
    }

    private func setPictureInPictureAutoStartEnabled(_ isEnabled: Bool) {
        guard #available(iOS 14.2, *) else { return }
        pictureInPictureController?.canStartPictureInPictureAutomaticallyFromInline = isEnabled
    }

    private func deactivatePictureInPictureAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func updateRecordingState() {
        isSystemRecordingActive = UIScreen.main.isCaptured
        let isRecording = isSystemRecordingActive
        recordButton.backgroundColor = isRecording ? UIColor(red: 1, green: 0.25, blue: 0.35, alpha: 1) : .white
        systemBroadcastPicker.tintColor = isRecording ? .white : UIColor(red: 1, green: 0.25, blue: 0.35, alpha: 1)
        recordButton.accessibilityLabel = isRecording ? "结束录制" : "开始屏幕录制"
        systemBroadcastPicker.accessibilityLabel = isRecording ? "打开停止直播面板" : "打开系统直播屏幕面板"
        configureSystemBroadcastPickerAppearance()
        cameraToggleButton.isEnabled = !isRecording || isFrontCameraEnabled
        closeButton.alpha = isRecording ? 0.42 : 1
        UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.durationLabel.alpha = isRecording ? 1 : 0
            self.hintLabel.alpha = isRecording ? 0.62 : 1
            self.cameraToggleButton.alpha = isRecording ? 0.62 : 1
        }
        if !isRecording {
            durationLabel.text = "00:00"
            hintLabel.text = "点击中间按钮打开系统直播屏幕面板\n需要露脸时，先点上方按钮开启前摄悬浮窗"
            statusLabel.text = "准备就绪：点中间按钮后选择开始直播"
        } else if recordingStartDate == nil {
            recordingStartDate = Date()
            startDurationTimer()
            hintLabel.text = "正在通过系统录屏，点击中间按钮打开停止直播面板"
            statusLabel.text = "系统录屏中，停止后可保存为草稿"
        }
    }

    private func updateCameraState(animated: Bool) {
        cameraToggleButton.setTitle(isFrontCameraEnabled ? "关闭前置摄像头" : "开启前置摄像头", for: .normal)
        cameraToggleButton.setImage(UIImage(systemName: isFrontCameraEnabled ? "video.slash.fill" : "video.badge.plus"), for: .normal)
        let updates = {
            self.cameraContainer.alpha = 0
            self.cameraContainer.transform = CGAffineTransform(scaleX: 0.86, y: 0.86)
        }
        let completion: (Bool) -> Void = { _ in
            self.cameraContainer.isHidden = true
        }
        cameraContainer.isHidden = true
        if animated {
            UIView.animate(withDuration: 0.34,
                           delay: 0,
                           usingSpringWithDamping: 0.82,
                           initialSpringVelocity: 0.7,
                           options: [.beginFromCurrentState, .allowUserInteraction],
                           animations: updates,
                           completion: completion)
        } else {
            updates()
            completion(true)
        }
    }

    private func startDurationTimer() {
        stopDurationTimer()
        refreshDurationLabel()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshDurationLabel()
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    private func refreshDurationLabel() {
        let elapsed = Date().timeIntervalSince(recordingStartDate ?? Date())
        let seconds = max(0, Int(elapsed.rounded(.down)))
        durationLabel.text = String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    @objc private func cameraToggleTapped() {
        isFrontCameraEnabled ? disableFrontCamera() : enableFrontCamera()
    }

    @objc private func hideCameraTapped() {
        disableFrontCamera()
    }

    private func closeFrontCameraFromPictureInPicture() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.disableFrontCamera()
            self.statusLabel.text = self.isSystemRecordingActive ? "系统录屏中，前摄已关闭" : "前摄已关闭"
        }
    }

    @objc private func appWillResignActive() {
        startCameraPictureInPictureIfPossible()
    }

    @objc private func appDidBecomeActive() {
        let wasRecording = isSystemRecordingActive
        updateRecordingState()
        if isFrontCameraEnabled {
            startCameraPictureInPictureIfPossible()
            retryStartCameraPictureInPictureIfNeeded()
        }
        if wasRecording, !UIScreen.main.isCaptured {
            checkForFinishedScreenRecording()
        }
    }

    @objc private func screenCaptureDidChange() {
        DispatchQueue.main.async {
            let wasRecording = self.isSystemRecordingActive
            if UIScreen.main.isCaptured {
                if !wasRecording {
                    self.screenRecordingLookupStartDate = Date().addingTimeInterval(-3)
                }
                self.recordingStartDate = Date()
                self.startDurationTimer()
            } else {
                self.recordingStartDate = nil
                self.stopDurationTimer()
            }
            self.updateRecordingState()
            if wasRecording, !UIScreen.main.isCaptured {
                self.checkForFinishedScreenRecording()
            }
        }
    }

    // MARK: - Actions

    @objc private func closeTapped() {
        if isSystemRecordingActive {
            showAlert("正在录屏", "请先通过系统录屏面板结束录制后再返回首页。")
        } else {
            navigationController?.popViewController(animated: true)
        }
    }

    private func checkForFinishedScreenRecording(retryCount: Int = 0) {
        let delay: TimeInterval = retryCount == 0 ? 1.2 : 0.9
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.statusLabel.text = retryCount == 0 ? "录屏已结束，正在保存到首页…" : "正在读取录屏文件…"
            self.loadLatestScreenRecordingCandidate { candidate in
                if let candidate {
                    self.saveScreenRecordingDraft(candidate)
                } else if retryCount < 8 {
                    self.checkForFinishedScreenRecording(retryCount: retryCount + 1)
                } else {
                    self.statusLabel.text = "录屏已结束，但暂未从相册读取到视频"
                }
            }
        }
    }

    private func saveScreenRecordingDraft(_ candidate: ScreenRecordingCandidate) {
        guard savingAssetIdentifier != candidate.assetIdentifier else {
            discardScreenRecordingCandidate(candidate)
            return
        }
        guard FileManager.default.fileExists(atPath: candidate.videoURL.path) else { return }
        savingAssetIdentifier = candidate.assetIdentifier
        statusLabel.text = "正在保存到首页…"
        do {
            let project = RecordingProject(createdAt: candidate.createdAt,
                                           mainVideoURL: candidate.videoURL,
                                           duration: candidate.duration,
                                           pipTrack: [],
                                           subtitleTrack: [],
                                           isDraft: true,
                                           aspect: AspectSettings(isPiPEnabled: false))
            _ = try DraftStore.shared.save(project)
            discardScreenRecordingCandidate(candidate)
            savingAssetIdentifier = nil
            backToHome()
        } catch {
            savingAssetIdentifier = nil
            showAlert("保存草稿失败", error.localizedDescription)
        }
    }

    private func discardScreenRecordingCandidate(_ candidate: ScreenRecordingCandidate) {
        try? FileManager.default.removeItem(at: candidate.videoURL)
    }

    private func backToHome() {
        if let navigationController {
            navigationController.popToRootViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    private func loadLatestScreenRecordingCandidate(completion: @escaping (ScreenRecordingCandidate?) -> Void) {
        requestPhotoReadPermission { [weak self] granted in
            guard let self, granted else {
                completion(nil)
                return
            }
            guard let asset = self.latestScreenRecordingAsset() else {
                completion(nil)
                return
            }
            self.exportAssetForDraft(asset, completion: completion)
        }
    }

    private func requestPhotoReadPermission(_ completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            completion(true)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                DispatchQueue.main.async {
                    completion(newStatus == .authorized || newStatus == .limited)
                }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    private func latestScreenRecordingAsset() -> PHAsset? {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.fetchLimit = 8
        fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        let fetchResult = PHAsset.fetchAssets(with: fetchOptions)
        let lowerBound = screenRecordingLookupStartDate ?? Date().addingTimeInterval(-120)
        var fallbackAsset: PHAsset?
        fetchResult.enumerateObjects { asset, _, stop in
            guard let creationDate = asset.creationDate, creationDate >= lowerBound else { return }
            if fallbackAsset == nil {
                fallbackAsset = asset
            }
            let hasMatchingFilename = PHAssetResource.assetResources(for: asset).contains {
                $0.originalFilename.hasPrefix(Constants.recordingFilePrefix)
            }
            if hasMatchingFilename {
                fallbackAsset = asset
                stop.pointee = true
            }
        }
        return fallbackAsset
    }

    private func exportAssetForDraft(_ asset: PHAsset, completion: @escaping (ScreenRecordingCandidate?) -> Void) {
        let resources = PHAssetResource.assetResources(for: asset).filter { $0.type == .video || $0.type == .fullSizeVideo }
        guard let resource = resources.first else {
            completion(nil)
            return
        }
        let outputURL = makeScreenRecordingImportURL(fileName: resource.originalFilename)
        try? FileManager.default.removeItem(at: outputURL)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        PHAssetResourceManager.default().writeData(for: resource, toFile: outputURL, options: options) { [weak self] error in
            DispatchQueue.main.async {
                guard error == nil else {
                    try? FileManager.default.removeItem(at: outputURL)
                    completion(nil)
                    return
                }
                let duration = Self.mediaDuration(for: outputURL, fallback: asset.duration)
                let candidate = ScreenRecordingCandidate(assetIdentifier: asset.localIdentifier,
                                                         videoURL: outputURL,
                                                         duration: duration,
                                                         createdAt: asset.creationDate ?? Date())
                self?.screenRecordingLookupStartDate = nil
                completion(candidate)
            }
        }
    }

    private func makeScreenRecordingImportURL(fileName: String) -> URL {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let importsDirectory = documentsURL.appendingPathComponent(Constants.recordingImportDirectoryName, isDirectory: true)
        try? fileManager.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
        let fileExtension = URL(fileURLWithPath: fileName).pathExtension
        let safeExtension = fileExtension.isEmpty ? "mov" : fileExtension
        return importsDirectory.appendingPathComponent("screen-recording-\(UUID().uuidString).\(safeExtension)")
    }

    private static func mediaDuration(for url: URL, fallback: TimeInterval) -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let candidates: [TimeInterval] = [asset.duration.seconds, fallback]
        return candidates.first { $0.isFinite && $0 > 0 } ?? 0
    }


    private func showAlert(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }
}

private struct ScreenRecordingCandidate {
    let assetIdentifier: String
    let videoURL: URL
    let duration: TimeInterval
    let createdAt: Date
}

@available(iOS 15.0, *)
extension ScreenRecordingViewController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerIsPictureInPicturePossibleDidChange(_ pictureInPictureController: AVPictureInPictureController) {
        guard isFrontCameraEnabled, pictureInPictureController.isPictureInPicturePossible else { return }
        startCameraPictureInPictureIfPossible()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        statusLabel.text = isSystemRecordingActive ? "系统录屏中" : "前摄浮窗已开启，可切到桌面"
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        DispatchQueue.main.async {
            self.deactivatePictureInPictureAudioSession()
            self.statusLabel.text = "前摄悬浮窗启动失败，可继续录屏"
        }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        isHandlingPiPRestore = true
        completionHandler(false)
        guard isFrontCameraEnabled else {
            isHandlingPiPRestore = false
            return
        }
        activatePictureInPictureAudioSession()
        frontCameraSession.startRunning()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            self.isHandlingPiPRestore = false
            self.startCameraPictureInPictureIfPossible()
            self.retryStartCameraPictureInPictureIfNeeded()
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard !isHandlingPiPRestore else { return }
        if isFrontCameraEnabled {
            stopFrontCameraAfterPictureInPictureClosed()
        } else {
            deactivatePictureInPictureAudioSession()
        }
    }
}

@available(iOS 15.0, *)
private final class PiPCameraViewController: UIViewController {
    private let cameraSession: FrontCameraSessionController
    private let closeButton = UIButton(type: .system)
    private var previewLayer: AVCaptureVideoPreviewLayer?
    var onCloseTapped: (() -> Void)?

    init(cameraSession: FrontCameraSessionController) {
        self.cameraSession = cameraSession
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.layer.cornerRadius = 18
        view.layer.cornerCurve = .continuous
        view.layer.masksToBounds = true
        attachPreviewLayer()
        setupCloseButton()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func attachPreviewLayer() {
        let layer = cameraSession.makePreviewLayer()
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
    }

    private func setupCloseButton() {
        let image = UIImage(systemName: "xmark",
                            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .light))
        closeButton.setImage(image, for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = .clear
        closeButton.contentHorizontalAlignment = .center
        closeButton.contentVerticalAlignment = .center
        closeButton.layer.shadowColor = UIColor.black.cgColor
        closeButton.layer.shadowOpacity = 0.22
        closeButton.layer.shadowRadius = 4
        closeButton.layer.shadowOffset = CGSize(width: 0, height: 1)
        closeButton.accessibilityLabel = "关闭前置摄像头"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)
        closeButton.snp.makeConstraints { make in
            make.top.leading.equalToSuperview().inset(12)
            make.size.equalTo(20)
        }
    }

    @objc private func closeTapped() {
        onCloseTapped?()
    }
}

private final class FrontCameraSessionController {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.pinbo.screen-recording.front-camera")
    private var isConfigured = false

    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }

    func startRunning(completion: ((Bool) -> Void)? = nil) {
        sessionQueue.async {
            guard self.configureIfNeeded() else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            guard !self.session.isRunning else {
                DispatchQueue.main.async { completion?(true) }
                return
            }
            self.session.startRunning()
            DispatchQueue.main.async { completion?(true) }
        }
    }

    func stopRunning() {
        sessionQueue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func configureIfNeeded() -> Bool {
        if isConfigured { return true }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.beginConfiguration()
        session.sessionPreset = .medium
        session.addInput(input)
        if #available(iOS 16.0, *), session.isMultitaskingCameraAccessSupported {
            session.isMultitaskingCameraAccessEnabled = true
        }
        session.commitConfiguration()
        isConfigured = true
        return true
    }
}
