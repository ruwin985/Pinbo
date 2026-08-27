import UIKit
import AVFoundation
import AVKit
import Photos
import ReplayKit
import SnapKit
import OSLog

/// 手机录制页统一诊断日志，用于真机 Console 排查前摄浮窗后台暂停问题。
private let screenRecordingLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.pinbo.app",
                                           category: "ScreenRecording")

/// 将布尔值转换为 Console 中可直接查看的公开文本。
private func logFlag(_ value: Bool) -> String {
    value ? "true" : "false"
}

/// 在录屏页退出后继续负责关闭系统 PiP，避免系统广播面板遮挡期间 stop 请求被延迟。
private final class ScreenRecordingPiPCleanupCoordinator: NSObject, AVPictureInPictureControllerDelegate {
    static let shared = ScreenRecordingPiPCleanupCoordinator()

    private var controller: AVPictureInPictureController?
    private var stopRetryWorkItem: DispatchWorkItem?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification,
                                               object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func takeOverAndStop(_ controller: AVPictureInPictureController) {
        stopRetryWorkItem?.cancel()
        self.controller = controller
        controller.delegate = self
        if #available(iOS 14.2, *) {
            controller.canStartPictureInPictureAutomaticallyFromInline = false
        }
        controller.stopPictureInPicture()
        scheduleStopRetry()
    }

    @objc private func appDidBecomeActive() {
        stopRetainedPictureInPicture()
    }

    private func stopRetainedPictureInPicture() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
            scheduleStopRetry()
        } else {
            releaseController()
        }
    }

    private func scheduleStopRetry() {
        stopRetryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.stopRetainedPictureInPicture()
        }
        stopRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func releaseController() {
        stopRetryWorkItem?.cancel()
        stopRetryWorkItem = nil
        controller?.delegate = nil
        controller = nil
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        releaseController()
    }
}

/// 手机端屏幕录制页：用户手动开启前摄悬浮窗，点击中间按钮开始/结束系统录屏。
final class ScreenRecordingViewController: UIViewController {
    private enum Constants {
        static let broadcastExtensionBundleIdentifier = "com.pinbo.app.ScreenBroadcastExtension"
        static let recordingImportDirectoryName = "ScreenRecordingImports"
        static let recordingFilePrefix = "Pinbo-ScreenRecording-"
        /// 等待系统停止确认弹窗和相册产物稳定的最大重试次数。
        static let screenRecordingImportRetryLimit = 20
        /// 保持前摄竖屏比例，避免系统浮窗按正方形比例渲染出黑边。
        static let pictureInPictureSourceSize = CGSize(width: 136, height: 190)
        /// 让 PiP 源视图留在可用视图树中，但视觉上不出现页面内占位。
        static let hiddenPictureInPictureSourceAlpha: CGFloat = 0.01
    }

    private let previewBackdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let recordButton = UIButton(type: .system)
    private let systemBroadcastPicker = RPSystemBroadcastPickerView(frame: .zero)
    private let cameraToggleButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .custom)
    private let statusLabel = UILabel()
    private let hintLabel = UILabel()
    private let durationLabel = UILabel()
    private let processingOverlay = UIView()
    private let processingIndicator = UIActivityIndicatorView(style: .large)
    private let processingLabel = UILabel()
    private let cameraContainer = UIView()
    private let pictureInPictureSourceView = UIView()
    /// 供系统 PiP 镜像的样本缓冲显示层。
    private let pictureInPictureSampleBufferDisplayLayer = AVSampleBufferDisplayLayer()

    private let frontCameraSession = FrontCameraSessionController()
    private var pictureInPictureController: AVPictureInPictureController?
    private var recordingStartDate: Date?
    private var durationTimer: Timer?
    private var isFrontCameraEnabled = false
    /// 记录前摄悬浮窗是否暂停，避免前后台切换时被自动恢复。
    private var isFrontCameraPaused = false
    /// 记录本页是否已经观察到系统录屏真正开始，避免点红色胶囊弹确认框时误判结束。
    private var hasObservedActiveScreenRecording = false
    /// 延迟确认系统录屏结束的任务，避免系统停止弹窗出现时立即误结束。
    private var pendingScreenRecordingEndWorkItem: DispatchWorkItem?
    private var isSystemRecordingActive = false
    private var hasRequestedPhotoPermission = false
    private var screenRecordingLookupStartDate: Date?
    private var savingAssetIdentifier: String?
    /// 已经处理过的系统录屏相册资源，防止重复通知重复保存同一条视频。
    private var processedScreenRecordingAssetIdentifiers: Set<String> = []
    /// 标记当前处于系统 PiP 还原按钮流程，避免误把它当作用户关闭浮窗。
    private var isHandlingPiPRestore = false
    /// 标记前摄当前恢复在页面内预览，避免前台自动再次拉起系统 PiP。
    private var isFrontCameraRestoredInline = false
    /// 标记下一次 PiP 停止是用户通过页面按钮主动触发的，不应再次关闭前摄状态。
    private var shouldIgnoreNextPictureInPictureStop = false
    private var isCheckingFinishedScreenRecording = false
    override func viewDidLoad() {
        super.viewDidLoad()
        screenRecordingLogger.info("录制页加载 captured=\(logFlag(UIScreen.main.isCaptured), privacy: .public) PiPSupported=\(logFlag(AVPictureInPictureController.isPictureInPictureSupported()), privacy: .public)")
        view.backgroundColor = AppTheme.primary
        navigationController?.setNavigationBarHidden(true, animated: false)
        setupUI()
        configureCameraPictureInPictureIfAvailable()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appWillResignActive),
                                               name: UIApplication.willResignActiveNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification,
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
        pictureInPictureSampleBufferDisplayLayer.frame = pictureInPictureSourceView.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        requestPhotoPermissionIfNeeded()
        prepareFrontCameraSessionIfAuthorized()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || isBeingDismissed {
            screenRecordingLogger.info("录制页退出，停止前摄和 PiP")
            stopDurationTimer()
            cancelPendingScreenRecordingEndConfirmation()
            closeFrontCameraPictureInPicture(reason: "录制页退出", shouldUpdateStatus: false)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        cancelPendingScreenRecordingEndConfirmation()
        stopDurationTimer()
    }

    override var prefersStatusBarHidden: Bool { false }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    /// 当前 App 生命周期状态文本，便于对齐切后台时机。
    private var applicationStateDescription: String {
        switch UIApplication.shared.applicationState {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknown"
        }
    }

    /// 输出前摄 PiP 控制器当前状态。
    private func logPictureInPictureState(_ event: String) {
        guard let controller = pictureInPictureController else {
            screenRecordingLogger.info("\(event, privacy: .public) PiPController=nil appState=\(self.applicationStateDescription, privacy: .public) frontEnabled=\(logFlag(self.isFrontCameraEnabled), privacy: .public)")
            return
        }
        screenRecordingLogger.info("\(event, privacy: .public) possible=\(logFlag(controller.isPictureInPicturePossible), privacy: .public) active=\(logFlag(controller.isPictureInPictureActive), privacy: .public) auto=\(logFlag(controller.canStartPictureInPictureAutomaticallyFromInline), privacy: .public) appState=\(self.applicationStateDescription, privacy: .public) frontEnabled=\(logFlag(self.isFrontCameraEnabled), privacy: .public)")
    }

    // MARK: - UI

    private func setupUI() {
        setupGradientBackground()

        closeButton.setImage(UIImage(named: "nav_back"), for: .normal)
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

        recordButton.applyAppPrimaryButtonStyle(cornerRadius: 46, shadow: true)
        recordButton.backgroundColor = .white
        recordButton.isUserInteractionEnabled = false
        view.addSubview(recordButton)

        systemBroadcastPicker.preferredExtension = Constants.broadcastExtensionBundleIdentifier
        systemBroadcastPicker.showsMicrophoneButton = true
        systemBroadcastPicker.backgroundColor = .clear
        systemBroadcastPicker.tintColor = AppTheme.primary
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
        setupProcessingOverlay()

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
            make.bottom.equalTo(recordButton.snp.top).offset(-16)
            make.centerX.equalToSuperview()
        }

        recordButton.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
//            make.centerY.equalToSuperview().offset(52)
            make.bottom.equalTo(view.safeAreaLayoutGuide).inset(46)
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

    private func setupProcessingOverlay() {
        processingOverlay.isHidden = true
        processingOverlay.alpha = 0
        processingOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        processingOverlay.isUserInteractionEnabled = true
        processingOverlay.accessibilityViewIsModal = true
        view.addSubview(processingOverlay)
        processingOverlay.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        processingIndicator.color = .white
        processingIndicator.hidesWhenStopped = false

        processingLabel.text = "录屏已结束\n正在处理并保存，请稍候…"
        processingLabel.textColor = .white
        processingLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        processingLabel.textAlignment = .center
        processingLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [processingIndicator, processingLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 18
        processingOverlay.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.trailing.lessThanOrEqualToSuperview().inset(32)
        }
    }

    private func showProcessingOverlay(message: String = "录屏已结束\n正在处理并保存，请稍候…") {
        processingLabel.text = message
        processingOverlay.isHidden = false
        view.bringSubviewToFront(processingOverlay)
        processingIndicator.startAnimating()
        UIView.animate(withDuration: 0.2,
                       delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.processingOverlay.alpha = 1
        }
    }

    private func hideProcessingOverlay() {
        processingIndicator.stopAnimating()
        processingOverlay.alpha = 0
        processingOverlay.isHidden = true
    }

    private func setupGradientBackground() {
        let gradient = CAGradientLayer()
        gradient.colors = AppTheme.gradientColors.map { $0.cgColor }
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

    /// 配置系统 PiP 使用的不可见源视图，避免页面内出现黑色占位。
    private func setupPictureInPictureSourceView() {
        pictureInPictureSourceView.backgroundColor = .clear
        pictureInPictureSourceView.alpha = Constants.hiddenPictureInPictureSourceAlpha
        pictureInPictureSourceView.isHidden = false
        pictureInPictureSourceView.clipsToBounds = true
        pictureInPictureSourceView.layer.cornerRadius = 0
        pictureInPictureSourceView.layer.borderWidth = 0
        pictureInPictureSourceView.isUserInteractionEnabled = false
        view.addSubview(pictureInPictureSourceView)
        pictureInPictureSourceView.snp.makeConstraints { make in
            make.width.equalTo(Constants.pictureInPictureSourceSize.width)
            make.height.equalTo(Constants.pictureInPictureSourceSize.height)
            make.trailing.equalToSuperview().inset(18)
            make.bottom.equalTo(view.safeAreaLayoutGuide).inset(96)
        }
        pictureInPictureSampleBufferDisplayLayer.videoGravity = .resizeAspectFill
        pictureInPictureSampleBufferDisplayLayer.backgroundColor = UIColor.clear.cgColor
        var sampleBufferTimebase: CMTimebase?
        if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                           sourceClock: CMClockGetHostTimeClock(),
                                           timebaseOut: &sampleBufferTimebase) == noErr,
           let sampleBufferTimebase {
            CMTimebaseSetRate(sampleBufferTimebase, rate: 1.0)
            pictureInPictureSampleBufferDisplayLayer.controlTimebase = sampleBufferTimebase
        }
        pictureInPictureSampleBufferDisplayLayer.frame = pictureInPictureSourceView.bounds
        pictureInPictureSourceView.layer.addSublayer(pictureInPictureSampleBufferDisplayLayer)
    }

    // MARK: - Recorder

    private func configureSystemBroadcastPickerAppearance() {
        systemBroadcastPicker.preferredExtension = Constants.broadcastExtensionBundleIdentifier
        systemBroadcastPicker.tintColor = AppTheme.primary
        for subview in systemBroadcastPicker.subviews {
            if let button = subview as? UIButton {
                button.frame = systemBroadcastPicker.bounds
                button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                button.backgroundColor = .clear
                button.tintColor = AppTheme.primary
                button.imageView?.tintColor = AppTheme.primary
                button.contentHorizontalAlignment = .center
                button.contentVerticalAlignment = .center
                button.isUserInteractionEnabled = true
                applyTemplateImage(to: button, for: .normal)
                applyTemplateImage(to: button, for: .highlighted)
                applyTemplateImage(to: button, for: .selected)
                applyTemplateImage(to: button, for: .disabled)
            }
        }
    }

    private func applyTemplateImage(to button: UIButton, for state: UIControl.State) {
        guard let image = button.image(for: state) ?? button.image(for: .normal) else { return }
        button.setImage(image.withRenderingMode(.alwaysTemplate), for: state)
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
        guard #available(iOS 15.0, *) else {
            screenRecordingLogger.error("当前系统低于 iOS 15，不支持视频通话 PiP")
            return
        }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            screenRecordingLogger.error("当前设备不支持 PiP")
            return
        }
        frontCameraSession.setSampleBufferDisplayLayer(pictureInPictureSampleBufferDisplayLayer)
        frontCameraSession.onFirstSampleBufferDisplayed = { [weak self] in
            guard let self, self.isFrontCameraEnabled, !self.isFrontCameraPaused else { return }
            self.startCameraPictureInPictureIfPossible()
        }

        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: pictureInPictureSampleBufferDisplayLayer,
                                                                playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        pictureInPictureController = controller
        logPictureInPictureState("PiP控制器配置完成")
    }

    private func startCameraPictureInPictureIfPossible() {
        guard isFrontCameraEnabled else {
            screenRecordingLogger.info("跳过启动 PiP：前摄未开启")
            return
        }
        guard #available(iOS 15.0, *) else {
            screenRecordingLogger.error("跳过启动 PiP：系统版本不支持")
            return
        }
        refreshFrontCameraPictureInPictureState()
        logPictureInPictureState("准备启动PiP")
        guard frontCameraSession.hasDisplayedSampleBuffer else {
            screenRecordingLogger.info("跳过启动 PiP：等待前摄首帧")
            return
        }
        guard let controller = pictureInPictureController,
              controller.isPictureInPicturePossible,
              !controller.isPictureInPictureActive else {
            screenRecordingLogger.info("跳过启动 PiP：条件未满足")
            return
        }
        screenRecordingLogger.info("调用 startPictureInPicture")
        controller.startPictureInPicture()
    }

    /// 切到后台或返回前台时，重新确认前摄会话和音频会话保持在线。
    private func refreshFrontCameraPictureInPictureState() {
        guard isFrontCameraEnabled else {
            screenRecordingLogger.info("跳过刷新前摄状态：前摄未开启")
            return
        }
        guard !isFrontCameraPaused else {
            screenRecordingLogger.info("跳过刷新前摄状态：当前已暂停")
            return
        }
        screenRecordingLogger.info("刷新前摄后台状态 appState=\(self.applicationStateDescription, privacy: .public)")
        activatePictureInPictureAudioSession()
        frontCameraSession.startRunning()
    }

    private func retryStartCameraPictureInPictureIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            screenRecordingLogger.info("延迟重试启动 PiP")
            self?.startCameraPictureInPictureIfPossible()
        }
    }

    /// 保持系统 PiP 源视图可用但不展示给用户。
    private func showInlineFrontCameraPreview(animated: Bool) {
        pictureInPictureSourceView.layer.removeAllAnimations()
        pictureInPictureSourceView.isHidden = false
        let updates = {
            self.pictureInPictureSourceView.alpha = Constants.hiddenPictureInPictureSourceAlpha
        }
        if animated {
            UIView.animate(withDuration: 0.22,
                           delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction],
                           animations: updates)
        } else {
            updates()
        }
    }

    /// 隐藏系统 PiP 源视图，关闭前摄时移除最后的不可见锚点。
    private func hideInlineFrontCameraPreview(animated: Bool) {
        let updates = {
            self.pictureInPictureSourceView.alpha = 0
        }
        let completion: (Bool) -> Void = { _ in
            self.pictureInPictureSourceView.isHidden = true
        }
        if animated {
            UIView.animate(withDuration: 0.18,
                           delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction],
                           animations: updates,
                           completion: completion)
        } else {
            updates()
            completion(true)
        }
    }

    /// 全屏/还原按钮停止 PiP 后，延迟重新拉起浮窗，避开系统退出动画的竞争。
    private func restartPictureInPictureAfterRestore() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self,
                  self.isFrontCameraEnabled,
                  !self.isFrontCameraPaused,
                  !self.isHandlingPiPRestore,
                  let controller = self.pictureInPictureController,
                  !controller.isPictureInPictureActive else { return }
            self.refreshFrontCameraPictureInPictureState()
            self.startCameraPictureInPictureIfPossible()
            self.retryStartCameraPictureInPictureIfNeeded()
        }
    }

    /// 在相机已授权时提前完成会话配置，减少首次点击后的等待时间。
    private func prepareFrontCameraSessionIfAuthorized() {
        guard PermissionManager.cameraGranted else { return }
        frontCameraSession.prepareIfNeeded()
    }

    /// 开始处理系统 PiP 右上角还原按钮触发的停止流程。
    private func beginPictureInPictureRestoreFlow() {
        isHandlingPiPRestore = true
        isFrontCameraRestoredInline = true
        refreshFrontCameraPictureInPictureState()
    }

    /// 结束或取消系统还原流程。
    private func finishPictureInPictureRestoreFlow() {
        isHandlingPiPRestore = false
    }

    private func enableFrontCamera() {
        guard !isFrontCameraEnabled else {
            screenRecordingLogger.info("跳过开启前摄：已经开启")
            return
        }
        screenRecordingLogger.info("用户开启前摄")
        guard PermissionManager.cameraGranted else {
            screenRecordingLogger.info("请求相机权限")
            PermissionManager.requestCamera { [weak self] granted in
                guard granted else {
                    screenRecordingLogger.error("相机权限被拒绝")
                    self?.showAlert("无法开启前摄", "请在系统设置中允许拍呗访问相机。")
                    return
                }
                self?.enableFrontCamera()
            }
            return
        }
        isFrontCameraEnabled = true
        isFrontCameraPaused = false
        isFrontCameraRestoredInline = false
        showInlineFrontCameraPreview(animated: true)
        setPictureInPictureAutoStartEnabled(true)
        activatePictureInPictureAudioSession()
        frontCameraSession.resetSampleBufferDisplayState()
        frontCameraSession.setSampleBufferDeliveryPaused(false)
        frontCameraSession.startRunning { [weak self] isStarted in
            guard let self, self.isFrontCameraEnabled else { return }
            screenRecordingLogger.info("前摄启动回调 isStarted=\(logFlag(isStarted), privacy: .public)")
            if isStarted {
                self.statusLabel.text = self.frontCameraStatusText()
                self.startCameraPictureInPictureIfPossible()
            } else {
                self.statusLabel.text = "无法启动前摄，请确认设备相机可用"
            }
        }
        updateCameraState(animated: true)
        retryStartCameraPictureInPictureIfNeeded()
        syncPictureInPicturePauseState()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 用户主动关闭前摄浮窗。
    private func disableFrontCamera() {
        guard isFrontCameraEnabled else {
            screenRecordingLogger.info("跳过关闭前摄：已经关闭")
            return
        }
        screenRecordingLogger.info("用户关闭前摄")
        closeFrontCameraPictureInPicture(reason: "用户关闭前摄", shouldUpdateStatus: true)
    }

    /// 统一关闭前摄 PiP 浮窗，供返回、录屏结束和手动关闭复用。
    private func closeFrontCameraPictureInPicture(reason: String, shouldUpdateStatus: Bool) {
        let controller = pictureInPictureController
        let isPictureInPictureActive = controller?.isPictureInPictureActive ?? false
        guard isFrontCameraEnabled || isPictureInPictureActive else {
            screenRecordingLogger.info("跳过关闭前摄浮窗：未开启 reason=\(reason, privacy: .public)")
            return
        }
        screenRecordingLogger.info("关闭前摄浮窗 reason=\(reason, privacy: .public) active=\(logFlag(isPictureInPictureActive), privacy: .public)")
        finishPictureInPictureRestoreFlow()
        stopFrontCameraSessionAndUpdateState(shouldUpdateStatus: shouldUpdateStatus)
        guard let controller else { return }
        if reason == "用户关闭前摄" {
            shouldIgnoreNextPictureInPictureStop = true
            controller.stopPictureInPicture()
        } else {
            ScreenRecordingPiPCleanupCoordinator.shared.takeOverAndStop(controller)
            pictureInPictureController = nil
        }
    }

    /// 统一关闭前摄、清理音频会话并刷新状态。
    private func stopFrontCameraSessionAndUpdateState(shouldUpdateStatus: Bool = true) {
        isFrontCameraEnabled = false
        isFrontCameraPaused = false
        isFrontCameraRestoredInline = false
        setPictureInPictureAutoStartEnabled(false)
        frontCameraSession.setSampleBufferDeliveryPaused(false)
        frontCameraSession.stopRunning()
        hideInlineFrontCameraPreview(animated: true)
        deactivatePictureInPictureAudioSession()
        updateCameraState(animated: true)
        if shouldUpdateStatus {
            statusLabel.text = frontCameraStatusText()
        }
        syncPictureInPicturePauseState()
    }

    private func activatePictureInPictureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord,
                                                            mode: .videoChat,
                                                            options: [.defaultToSpeaker, .allowBluetoothHFP])
            try AVAudioSession.sharedInstance().setActive(true)
            screenRecordingLogger.info("PiP 音频会话已激活")
        } catch {
            let sessionError = error as NSError
            screenRecordingLogger.error("PiP 音频会话激活失败 domain=\(sessionError.domain, privacy: .public) code=\(String(sessionError.code), privacy: .public) desc=\(sessionError.localizedDescription, privacy: .public)")
            statusLabel.text = "前摄已开启，浮窗音频会话启动失败"
        }
    }

    private func setPictureInPictureAutoStartEnabled(_ isEnabled: Bool) {
        guard #available(iOS 14.2, *) else { return }
        pictureInPictureController?.canStartPictureInPictureAutomaticallyFromInline = isEnabled
        screenRecordingLogger.info("设置 PiP 自动启动 auto=\(logFlag(isEnabled), privacy: .public)")
    }

    private func deactivatePictureInPictureAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        screenRecordingLogger.info("PiP 音频会话已停用")
    }

    /// 刷新录屏 UI 状态，系统停止确认弹窗期间继续保持录制态显示。
    private func updateRecordingState() {
        let isScreenCaptured = UIScreen.main.isCaptured
        let isWaitingForStopConfirmation = hasObservedActiveScreenRecording
            && !isScreenCaptured
            && pendingScreenRecordingEndWorkItem != nil
        isSystemRecordingActive = isScreenCaptured || isWaitingForStopConfirmation
        let isRecording = isSystemRecordingActive
        if isScreenCaptured {
            cancelPendingScreenRecordingEndConfirmation()
            hasObservedActiveScreenRecording = true
        }
        recordButton.backgroundColor = isRecording ? .lightGray : .white
        systemBroadcastPicker.tintColor = AppTheme.primary
        recordButton.accessibilityLabel = isRecording ? "结束录制" : "开始屏幕录制"
        systemBroadcastPicker.accessibilityLabel = isRecording ? "打开停止直播面板" : "打开系统直播屏幕面板"
        configureSystemBroadcastPickerAppearance()
        cameraToggleButton.isEnabled = true
        closeButton.alpha = isRecording ? 0.42 : 1
        UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.durationLabel.alpha = isRecording ? 1 : 0
            self.hintLabel.alpha = isRecording ? 0.62 : 1
            self.cameraToggleButton.alpha = isRecording ? 0.62 : 1
        }
        if !isRecording {
            guard !isCheckingFinishedScreenRecording else { return }
            durationLabel.text = "00:00"
            hintLabel.text = isFrontCameraEnabled ? "前摄悬浮窗已打开，浮窗里可暂停、快退和快进" : "点击中间按钮打开系统直播屏幕面板\n需要露脸时，先点上方按钮开启前摄悬浮窗"
            statusLabel.text = frontCameraStatusText()
        } else {
            if recordingStartDate == nil {
                recordingStartDate = Date()
                startDurationTimer()
            }
            hintLabel.text = "正在通过系统录屏，点击中间按钮打开停止直播面板"
            statusLabel.text = frontCameraStatusText()
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

    /// 返回当前前摄悬浮窗对应的状态文案。
    private func frontCameraStatusText() -> String {
        if isFrontCameraEnabled {
            if isFrontCameraRestoredInline {
                return isSystemRecordingActive ? "系统录屏中，前摄已恢复到页面内预览" : "前摄已恢复到页面内预览，切到桌面后继续浮窗"
            }
            if isFrontCameraPaused {
                return isSystemRecordingActive ? "系统录屏中，前摄悬浮窗已暂停" : "前摄悬浮窗已暂停"
            }
            return isSystemRecordingActive ? "系统录屏中，前摄悬浮窗已开启" : "前摄悬浮窗已开启"
        }
        return isSystemRecordingActive ? "系统录屏中，停止后自动保存到首页" : "准备就绪：点中间按钮后选择开始直播"
    }

    /// 同步 PiP 内容里的暂停按钮样式。
    private func syncPictureInPicturePauseState() {
        pictureInPictureController?.invalidatePlaybackState()
    }

    /// 暂停前摄悬浮窗的实时画面。
    private func pauseFrontCameraPictureInPicture() {
        guard isFrontCameraEnabled, !isFrontCameraPaused else { return }
        isFrontCameraPaused = true
        frontCameraSession.setSampleBufferDeliveryPaused(true)
        syncPictureInPicturePauseState()
        statusLabel.text = frontCameraStatusText()
    }

    /// 恢复前摄悬浮窗的实时画面。
    private func resumeFrontCameraPictureInPicture() {
        guard isFrontCameraEnabled, isFrontCameraPaused else { return }
        isFrontCameraPaused = false
        frontCameraSession.setSampleBufferDeliveryPaused(false)
        refreshFrontCameraPictureInPictureState()
        startCameraPictureInPictureIfPossible()
        syncPictureInPicturePauseState()
        statusLabel.text = frontCameraStatusText()
    }

    /// 切换前摄悬浮窗的暂停状态。
    private func toggleFrontCameraPause() {
        isFrontCameraPaused ? resumeFrontCameraPictureInPicture() : pauseFrontCameraPictureInPicture()
    }

    /// 向下调整前摄预览缩放，模拟系统 PiP 的快退方向按钮。
    private func decreaseFrontCameraZoom() {
        frontCameraSession.adjustZoom(by: -0.18)
    }

    /// 向上调整前摄预览缩放，模拟系统 PiP 的快进方向按钮。
    private func increaseFrontCameraZoom() {
        frontCameraSession.adjustZoom(by: 0.18)
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
        screenRecordingLogger.info("App 将进入非活跃 appState=\(self.applicationStateDescription, privacy: .public)")
        guard !isFrontCameraPaused else {
            screenRecordingLogger.info("跳过前摄非活跃恢复：当前已暂停")
            return
        }
        isFrontCameraRestoredInline = false
        refreshFrontCameraPictureInPictureState()
        startCameraPictureInPictureIfPossible()
        retryStartCameraPictureInPictureIfNeeded()
    }

    @objc private func appDidEnterBackground() {
        screenRecordingLogger.info("App 已进入后台 appState=\(self.applicationStateDescription, privacy: .public)")
        isFrontCameraRestoredInline = false
        refreshFrontCameraPictureInPictureState()
        retryStartCameraPictureInPictureIfNeeded()
    }

    /// App 回到前台时同步录屏状态，并在录屏已结束时关闭前摄 PiP。
    @objc private func appDidBecomeActive() {
        screenRecordingLogger.info("App 回到前台 appState=\(self.applicationStateDescription, privacy: .public)")
        let wasRecording = hasObservedActiveScreenRecording
        let isScreenCaptured = UIScreen.main.isCaptured
        let isWaitingForStopConfirmation = scheduleScreenRecordingEndConfirmationIfNeeded(wasRecording: wasRecording,
                                                                                          isScreenCaptured: isScreenCaptured,
                                                                                          reason: "录屏结束回前台")
        updateRecordingState()
        if !isWaitingForStopConfirmation {
            refreshFrontCameraPictureInPictureState()
        }
        if isFrontCameraEnabled, !isFrontCameraPaused, !isHandlingPiPRestore, !isFrontCameraRestoredInline, isScreenCaptured {
            startCameraPictureInPictureIfPossible()
            retryStartCameraPictureInPictureIfNeeded()
        }
    }

    /// 系统录屏状态变化时刷新 UI，结束录屏后同步关闭前摄 PiP。
    @objc private func screenCaptureDidChange() {
        DispatchQueue.main.async {
            let wasRecording = self.hasObservedActiveScreenRecording
            let isScreenCaptured = UIScreen.main.isCaptured
            if isScreenCaptured {
                if !wasRecording {
                    self.screenRecordingLookupStartDate = Date().addingTimeInterval(-3)
                    self.recordingStartDate = Date()
                    self.startDurationTimer()
                } else if self.recordingStartDate == nil || self.durationTimer == nil {
                    self.recordingStartDate = self.recordingStartDate ?? Date()
                    self.startDurationTimer()
                }
                self.hasObservedActiveScreenRecording = true
            } else {
                self.showProcessingOverlay(message: "录屏已结束\n正在处理并保存，请稍候…")
                self.scheduleScreenRecordingEndConfirmationIfNeeded(wasRecording: wasRecording,
                                                                    isScreenCaptured: isScreenCaptured,
                                                                    reason: "系统录屏结束")
            }
            self.updateRecordingState()
        }
    }

    /// 取消待确认的录屏结束任务，用户点系统弹窗“取消”后继续保持录制态。
    private func cancelPendingScreenRecordingEndConfirmation() {
        pendingScreenRecordingEndWorkItem?.cancel()
        pendingScreenRecordingEndWorkItem = nil
    }

    /// 发现疑似录屏结束后延迟确认，避开系统“停止直播？”弹窗的中间态。
    @discardableResult
    private func scheduleScreenRecordingEndConfirmationIfNeeded(wasRecording: Bool,
                                                                isScreenCaptured: Bool,
                                                                reason: String) -> Bool {
        guard wasRecording, !isScreenCaptured else { return false }
        cancelPendingScreenRecordingEndConfirmation()
        let workItem = DispatchWorkItem { [weak self] in
            self?.finishScreenRecordingIfStillStopped(reason: reason)
        }
        pendingScreenRecordingEndWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
        return true
    }

    /// 只有 App 已回到活跃态且系统录屏仍为未捕获时，才真正关闭浮窗和保存草稿。
    private func finishScreenRecordingIfStillStopped(reason: String) {
        pendingScreenRecordingEndWorkItem = nil
        guard hasObservedActiveScreenRecording else { return }
        guard !UIScreen.main.isCaptured else {
            updateRecordingState()
            refreshFrontCameraPictureInPictureState()
            return
        }
        finalizeScreenRecordingUI(reason: reason)
        showProcessingOverlay(message: "录屏已结束\n正在处理并保存，请稍候…")
        checkForFinishedScreenRecording(endReason: reason)
    }

    /// 取消误触发的结束处理，恢复为正在录屏状态。
    private func cancelScreenRecordingEndHandlingAfterResume() {
        isCheckingFinishedScreenRecording = false
        hideProcessingOverlay()
        hasObservedActiveScreenRecording = true
        updateRecordingState()
        refreshFrontCameraPictureInPictureState()
        statusLabel.text = frontCameraStatusText()
    }

    /// 已确认录屏真正结束后，立即停止页面录制状态并关闭前摄 PiP。
    private func finalizeScreenRecordingUI(reason: String) {
        hasObservedActiveScreenRecording = false
        recordingStartDate = nil
        stopDurationTimer()
        closeFrontCameraPictureInPicture(reason: reason, shouldUpdateStatus: false)
        updateRecordingState()
    }

    // MARK: - Actions

    /// 录屏中点击返回仅提示用户，保持当前页面和前摄 PiP；未录制时正常返回。
    @objc private func closeTapped() {
        if isSystemRecordingActive {
            showToast("正在录屏，请先通过系统录屏面板结束录制")
            return
        }
        closeFrontCameraPictureInPicture(reason: "返回按钮点击", shouldUpdateStatus: false)
        navigationController?.popViewController(animated: true)
    }

    private func checkForFinishedScreenRecording(retryCount: Int = 0, endReason: String = "系统录屏结束") {
        if retryCount == 0 {
            guard !isCheckingFinishedScreenRecording else { return }
            isCheckingFinishedScreenRecording = true
            statusLabel.text = "录屏已结束，正在保存到首页…"
        }
        let delay: TimeInterval = retryCount == 0 ? 1.2 : 0.9
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard !UIScreen.main.isCaptured else {
                self.cancelScreenRecordingEndHandlingAfterResume()
                return
            }
            self.showProcessingOverlay(message: retryCount == 0 ? "录屏已结束\n正在处理并保存，请稍候…" : "正在读取录屏文件\n请勿退出应用…")
            self.loadLatestScreenRecordingCandidate { candidate in
                guard !UIScreen.main.isCaptured else {
                    self.hideProcessingOverlay()
                    self.cancelScreenRecordingEndHandlingAfterResume()
                    return
                }
                if let candidate {
                    self.saveScreenRecordingDraft(candidate)
                } else if retryCount < Constants.screenRecordingImportRetryLimit {
                    self.checkForFinishedScreenRecording(retryCount: retryCount + 1, endReason: endReason)
                } else {
                    self.isCheckingFinishedScreenRecording = false
                    self.hideProcessingOverlay()
                    self.statusLabel.text = "未读取到录屏文件，请在相册中确认保存结果"
                }
            }
        }
    }

    private func saveScreenRecordingDraft(_ candidate: ScreenRecordingCandidate) {
        guard shouldImportScreenRecordingCandidate(candidate) else {
            discardScreenRecordingCandidate(candidate)
            isCheckingFinishedScreenRecording = false
            statusLabel.text = "录屏已保存，返回首页…"
            backToHome()
            return
        }
        guard FileManager.default.fileExists(atPath: candidate.videoURL.path) else {
            processedScreenRecordingAssetIdentifiers.remove(candidate.assetIdentifier)
            isCheckingFinishedScreenRecording = false
            statusLabel.text = "录屏文件读取失败，返回首页…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.backToHome()
            }
            return
        }
        savingAssetIdentifier = candidate.assetIdentifier
        statusLabel.text = "正在保存到首页…"
        do {
            let project = RecordingProject(createdAt: candidate.createdAt,
                                           mainVideoURL: candidate.videoURL,
                                           duration: candidate.duration,
                                           pipTrack: [],
                                           subtitleTrack: [],
                                           isDraft: true,
                                           aspect: AspectSettings(isPiPEnabled: false),
                                           sourceKind: .screen,
                                           sourceAssetIdentifier: candidate.assetIdentifier)
            _ = try DraftStore.shared.save(project)
            discardScreenRecordingCandidate(candidate)
            savingAssetIdentifier = nil
            isCheckingFinishedScreenRecording = false
            backToHome()
        } catch {
            processedScreenRecordingAssetIdentifiers.remove(candidate.assetIdentifier)
            savingAssetIdentifier = nil
            isCheckingFinishedScreenRecording = false
            hideProcessingOverlay()
            showAlert("保存草稿失败", error.localizedDescription)
        }
    }

    /// 判断当前录屏相册资源是否允许导入，并立即登记为处理中。
    private func shouldImportScreenRecordingCandidate(_ candidate: ScreenRecordingCandidate) -> Bool {
        guard savingAssetIdentifier != candidate.assetIdentifier else { return false }
        guard !processedScreenRecordingAssetIdentifiers.contains(candidate.assetIdentifier) else { return false }
        guard !DraftStore.shared.containsSourceAssetIdentifier(candidate.assetIdentifier) else { return false }
        processedScreenRecordingAssetIdentifiers.insert(candidate.assetIdentifier)
        return true
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
        var matchedAsset: PHAsset?
        fetchResult.enumerateObjects { asset, _, stop in
            guard let creationDate = asset.creationDate, creationDate >= lowerBound else { return }
            let hasMatchingFilename = PHAssetResource.assetResources(for: asset).contains {
                $0.originalFilename.hasPrefix(Constants.recordingFilePrefix)
            }
            if hasMatchingFilename {
                matchedAsset = asset
                stop.pointee = true
            }
        }
        return matchedAsset
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
        alert.view.tintColor = AppTheme.primary
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
        logPictureInPictureState("PiP可用状态变化")
        guard isFrontCameraEnabled, pictureInPictureController.isPictureInPicturePossible else { return }
        startCameraPictureInPictureIfPossible()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        logPictureInPictureState("PiP已启动")
        if isHandlingPiPRestore {
            finishPictureInPictureRestoreFlow()
        }
        syncPictureInPicturePauseState()
        statusLabel.text = frontCameraStatusText()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        let startError = error as NSError
        screenRecordingLogger.error("PiP启动失败 domain=\(startError.domain, privacy: .public) code=\(String(startError.code), privacy: .public) desc=\(startError.localizedDescription, privacy: .public)")
        DispatchQueue.main.async {
            if self.isFrontCameraEnabled {
                self.activatePictureInPictureAudioSession()
                self.frontCameraSession.startRunning()
                self.retryStartCameraPictureInPictureIfNeeded()
            } else {
                self.deactivatePictureInPictureAudioSession()
            }
            self.statusLabel.text = "前摄悬浮窗启动失败，可继续录屏"
        }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        logPictureInPictureState("PiP请求恢复界面")
        beginPictureInPictureRestoreFlow()
        showInlineFrontCameraPreview(animated: false)
        completionHandler(true)
        statusLabel.text = frontCameraStatusText()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        logPictureInPictureState("PiP已停止")
        guard !isHandlingPiPRestore else {
            isFrontCameraRestoredInline = false
            showInlineFrontCameraPreview(animated: false)
            refreshFrontCameraPictureInPictureState()
            statusLabel.text = frontCameraStatusText()
            finishPictureInPictureRestoreFlow()
            restartPictureInPictureAfterRestore()
            return
        }
        if shouldIgnoreNextPictureInPictureStop {
            shouldIgnoreNextPictureInPictureStop = false
            deactivatePictureInPictureAudioSession()
            return
        }
        guard isFrontCameraEnabled else {
            deactivatePictureInPictureAudioSession()
            return
        }
        stopFrontCameraSessionAndUpdateState()
    }
}

@available(iOS 15.0, *)
extension ScreenRecordingViewController: AVPictureInPictureSampleBufferPlaybackDelegate {
    /// 系统请求开始或暂停播放时，切换前摄会话状态。
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if playing {
                self.resumeFrontCameraPictureInPicture()
            } else {
                self.pauseFrontCameraPictureInPicture()
            }
            self.syncPictureInPicturePauseState()
        }
    }

    /// 返回当前样本缓冲流的可播放时间范围。
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        guard isFrontCameraEnabled else {
            return .invalid
        }
        return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    /// 告诉系统当前 UI 是否应该呈现为暂停态。
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        isFrontCameraPaused || !isFrontCameraEnabled
    }

    /// 系统浮窗尺寸变化时，保留日志，便于后续调参。
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        screenRecordingLogger.info("PiP 渲染尺寸变化 width=\(newRenderSize.width, privacy: .public) height=\(newRenderSize.height, privacy: .public)")
    }

    /// 系统请求快进或快退时，先把它映射成一个轻量缩放操作。
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion: @escaping () -> Void) {
        if skipInterval.seconds >= 0 {
            increaseFrontCameraZoom()
        } else {
            decreaseFrontCameraZoom()
        }
        completion()
    }

    /// 手机前摄不需要在后台继续播放音频。
    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        true
    }
}

private final class FrontCameraSessionController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// 承载前摄录制的会话对象。
    private let session = AVCaptureSession()
    /// 串行执行相机配置和启停，避免线程竞争。
    private let sessionQueue = DispatchQueue(label: "com.pinbo.screen-recording.front-camera")
    /// 缓存当前前摄设备，便于后续调整缩放。
    private var frontCameraDevice: AVCaptureDevice?
    /// 记录当前缩放倍数，供 PiP 的方向按钮使用。
    private var currentZoomFactor: CGFloat = 1
    /// 负责把相机帧转交给系统 PiP 的样本缓冲显示层。
    private weak var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer?
    /// 视频数据输出队列，避免阻塞相机采集线程。
    private let sampleBufferOutputQueue = DispatchQueue(label: "com.pinbo.screen-recording.front-camera.sample-buffer")
    /// 把相机帧输出给样本缓冲层的视频输出。
    private let videoDataOutput = AVCaptureVideoDataOutput()
    /// 保护样本显示状态，避免主线程同步等待相机会话队列。
    private let sampleBufferStateLock = NSLock()
    /// 记录样本缓冲层是否已经收到第一帧。
    private var hasDisplayedFirstSampleBuffer = false
    /// 标记是否临时冻结 PiP 画面输出。
    private var isSampleBufferDeliveryPaused = false
    /// 第一帧成功送入显示层后的回调。
    var onFirstSampleBufferDisplayed: (() -> Void)?
    private var isConfigured = false
    private var hasRegisteredSessionObservers = false

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }

    /// 指定系统 PiP 使用的样本缓冲显示层。
    func setSampleBufferDisplayLayer(_ displayLayer: AVSampleBufferDisplayLayer?) {
        sessionQueue.async {
            self.sampleBufferDisplayLayer = displayLayer
        }
    }

    /// 提前配置前摄输入和样本输出，不启动采集，减少首次打开等待。
    func prepareIfNeeded() {
        sessionQueue.async {
            guard !self.isConfigured else { return }
            self.registerSessionObserversIfNeeded()
            _ = self.configureIfNeeded()
        }
    }

    /// 当前是否已经有首帧可供系统 PiP 展示。
    var hasDisplayedSampleBuffer: Bool {
        sampleBufferStateLock.lock()
        defer { sampleBufferStateLock.unlock() }
        return hasDisplayedFirstSampleBuffer
    }

    /// 设置样本帧是否继续进入 PiP，用于暂停按钮冻结画面。
    func setSampleBufferDeliveryPaused(_ isPaused: Bool) {
        sampleBufferStateLock.lock()
        isSampleBufferDeliveryPaused = isPaused
        sampleBufferStateLock.unlock()
    }

    /// 重新打开前摄浮窗前清空旧帧，避免显示层复用黑屏或失败状态。
    func resetSampleBufferDisplayState() {
        setHasDisplayedFirstSampleBuffer(false)
        sessionQueue.async {
            let displayLayer = self.sampleBufferDisplayLayer
            DispatchQueue.main.async {
                displayLayer?.flushAndRemoveImage()
            }
        }
    }

    func startRunning(completion: ((Bool) -> Void)? = nil) {
        sessionQueue.async {
            screenRecordingLogger.info("前摄会话准备启动 configured=\(logFlag(self.isConfigured), privacy: .public) running=\(logFlag(self.session.isRunning), privacy: .public) \(self.multitaskingCameraStateDescription(), privacy: .public)")
            self.registerSessionObserversIfNeeded()
            guard self.configureIfNeeded() else {
                screenRecordingLogger.error("前摄会话配置失败，无法启动")
                DispatchQueue.main.async { completion?(false) }
                return
            }
            guard !self.session.isRunning else {
                screenRecordingLogger.info("前摄会话已在运行")
                DispatchQueue.main.async { completion?(true) }
                return
            }
            self.session.startRunning()
            screenRecordingLogger.info("前摄会话启动完成 running=\(logFlag(self.session.isRunning), privacy: .public) \(self.multitaskingCameraStateDescription(), privacy: .public)")
            DispatchQueue.main.async { completion?(true) }
        }
    }

    func stopRunning() {
        sessionQueue.async {
            guard self.session.isRunning else {
                screenRecordingLogger.info("跳过停止前摄会话：未运行")
                return
            }
            screenRecordingLogger.info("停止前摄会话")
            self.session.stopRunning()
        }
    }

    /// 注册相机会话中断通知，避免后台切换后预览卡住。
    private func registerSessionObserversIfNeeded() {
        guard !hasRegisteredSessionObservers else { return }
        hasRegisteredSessionObservers = true
        screenRecordingLogger.info("注册前摄会话中断监听")
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionRuntimeError(_:)),
                                               name: .AVCaptureSessionRuntimeError,
                                               object: session)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionWasInterrupted(_:)),
                                               name: .AVCaptureSessionWasInterrupted,
                                               object: session)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionInterruptionEnded(_:)),
                                               name: .AVCaptureSessionInterruptionEnded,
                                               object: session)
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        sessionQueue.async {
            let runtimeError = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            screenRecordingLogger.error("前摄会话运行错误 domain=\(runtimeError?.domain ?? "nil", privacy: .public) code=\(String(runtimeError?.code ?? 0), privacy: .public) desc=\(runtimeError?.localizedDescription ?? "nil", privacy: .public)")
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.session.startRunning()
            screenRecordingLogger.info("前摄会话运行错误后重启 running=\(logFlag(self.session.isRunning), privacy: .public)")
        }
    }

    @objc private func sessionWasInterrupted(_ notification: Notification) {
        let reasonValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
        let reasonDescription = Self.interruptionReasonDescription(reasonValue)
        screenRecordingLogger.warning("前摄会话被系统中断 reason=\(reasonDescription, privacy: .public) running=\(logFlag(self.session.isRunning), privacy: .public) \(self.multitaskingCameraStateDescription(), privacy: .public)")
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        screenRecordingLogger.info("前摄会话中断结束，准备恢复")
        startRunning()
    }

    private func configureIfNeeded() -> Bool {
        if isConfigured { return true }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            screenRecordingLogger.error("找不到可用前置摄像头输入")
            return false
        }
        session.beginConfiguration()
        session.sessionPreset = .medium
        session.addInput(input)
        frontCameraDevice = device
        currentZoomFactor = device.videoZoomFactor
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoDataOutput.setSampleBufferDelegate(self, queue: sampleBufferOutputQueue)
        guard session.canAddOutput(videoDataOutput) else {
            screenRecordingLogger.error("无法添加前摄视频数据输出")
            session.commitConfiguration()
            return false
        }
        session.addOutput(videoDataOutput)
        if let connection = videoDataOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }
        if #available(iOS 16.0, *), session.isMultitaskingCameraAccessSupported {
            session.isMultitaskingCameraAccessEnabled = true
            screenRecordingLogger.info("已开启多任务相机访问 \(self.multitaskingCameraStateDescription(), privacy: .public)")
        } else {
            screenRecordingLogger.warning("当前会话不支持多任务相机访问 \(self.multitaskingCameraStateDescription(), privacy: .public)")
        }
        session.commitConfiguration()
        isConfigured = true
        screenRecordingLogger.info("前摄会话配置完成 device=\(device.localizedName, privacy: .public) preset=medium \(self.multitaskingCameraStateDescription(), privacy: .public)")
        return true
    }

    /// 调整前摄画面缩放倍数。
    func adjustZoom(by delta: CGFloat) {
        sessionQueue.async {
            guard let device = self.frontCameraDevice else {
                screenRecordingLogger.info("跳过调整前摄缩放：设备尚未配置")
                return
            }
            let minimumZoom = max(1, device.minAvailableVideoZoomFactor)
            let maximumZoom = device.maxAvailableVideoZoomFactor
            let targetZoom = min(max(self.currentZoomFactor + delta, minimumZoom), maximumZoom)
            guard abs(targetZoom - self.currentZoomFactor) > .ulpOfOne else { return }
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = targetZoom
                device.unlockForConfiguration()
                self.currentZoomFactor = targetZoom
                let zoomText = String(format: "%.2f", targetZoom)
                screenRecordingLogger.info("前摄缩放调整完成 zoom=\(zoomText, privacy: .public)")
            } catch {
                screenRecordingLogger.error("前摄缩放调整失败 desc=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 将实时相机帧标记为立即显示，避免系统 PiP 按旧时间戳排队导致黑屏。
    private func markSampleBufferForImmediateDisplay(_ sampleBuffer: CMSampleBuffer) {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
              CFArrayGetCount(attachmentsArray) > 0,
              let attachmentsPointer = CFArrayGetValueAtIndex(attachmentsArray, 0) else { return }
        let attachments = unsafeBitCast(attachmentsPointer, to: CFMutableDictionary.self)
        CFDictionarySetValue(attachments,
                             Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }

    /// 在主线程把相机帧送入显示层，避免后台队列直接操作 CALayer 造成首帧后失败。
    private func enqueueSampleBufferForPictureInPicture(_ sampleBuffer: CMSampleBuffer,
                                                        displayLayer: AVSampleBufferDisplayLayer) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if displayLayer.status == .failed {
                let layerError = displayLayer.error as NSError?
                screenRecordingLogger.error("PiP显示层失败，准备刷新 domain=\(layerError?.domain ?? "nil", privacy: .public) code=\(String(layerError?.code ?? 0), privacy: .public) desc=\(layerError?.localizedDescription ?? "nil", privacy: .public)")
                displayLayer.flushAndRemoveImage()
            }
            guard displayLayer.isReadyForMoreMediaData else { return }
            displayLayer.enqueue(sampleBuffer)
            guard self.markFirstSampleBufferDisplayedIfNeeded() else { return }
            self.onFirstSampleBufferDisplayed?()
        }
    }

    /// 将相机采集到的每一帧送入样本缓冲显示层。
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !shouldDropSampleBuffer else { return }
        guard let displayLayer = sampleBufferDisplayLayer else { return }
        markSampleBufferForImmediateDisplay(sampleBuffer)
        enqueueSampleBufferForPictureInPicture(sampleBuffer, displayLayer: displayLayer)
    }

    /// 标记首帧是否已经进入显示层，并返回是否需要通知外部。
    private func markFirstSampleBufferDisplayedIfNeeded() -> Bool {
        sampleBufferStateLock.lock()
        defer { sampleBufferStateLock.unlock() }
        guard !hasDisplayedFirstSampleBuffer else { return false }
        hasDisplayedFirstSampleBuffer = true
        return true
    }

    /// 重置首帧状态，不依赖相机会话串行队列，避免关闭时阻塞 UI。
    private func setHasDisplayedFirstSampleBuffer(_ hasDisplayed: Bool) {
        sampleBufferStateLock.lock()
        hasDisplayedFirstSampleBuffer = hasDisplayed
        sampleBufferStateLock.unlock()
    }

    /// 当前是否应该丢弃实时样本帧。
    private var shouldDropSampleBuffer: Bool {
        sampleBufferStateLock.lock()
        defer { sampleBufferStateLock.unlock() }
        return isSampleBufferDeliveryPaused
    }

    /// 返回多任务相机能力状态文本，辅助判断 entitlement 是否生效。
    private func multitaskingCameraStateDescription() -> String {
        if #available(iOS 16.0, *) {
            return "multitaskingSupported=\(logFlag(session.isMultitaskingCameraAccessSupported)) multitaskingEnabled=\(logFlag(session.isMultitaskingCameraAccessEnabled))"
        }
        return "multitaskingSupported=unavailableBeforeIOS16 multitaskingEnabled=unavailableBeforeIOS16"
    }

    /// 将系统相机中断原因转换为可读日志。
    private static func interruptionReasonDescription(_ rawValue: Int?) -> String {
        guard let rawValue,
              let reason = AVCaptureSession.InterruptionReason(rawValue: rawValue) else {
            return "unknown"
        }
        switch reason {
        case .videoDeviceInUseByAnotherClient:
            return "videoDeviceInUseByAnotherClient"
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            return "videoDeviceNotAvailableWithMultipleForegroundApps"
        case .videoDeviceNotAvailableDueToSystemPressure:
            return "videoDeviceNotAvailableDueToSystemPressure"
        case .audioDeviceInUseByAnotherClient:
            return "audioDeviceInUseByAnotherClient"
        case .videoDeviceNotAvailableInBackground:
            return "videoDeviceNotAvailableInBackground"
        case .sensitiveContentMitigationActivated:
            return "sensitiveContentMitigationActivated"
        @unknown default:
            return "unknownRawValue=\(rawValue)"
        }
    }
}
