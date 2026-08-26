import UIKit
import AVFoundation
import SnapKit

/// Demo 录制页：后摄全屏 + 前摄可拖拽画中画 + 实时字幕 + 录制。
final class RecordingViewController: UIViewController {

    private let source = DualCameraSource()
    private let speech = LiveSpeechRecognizer(language: .chinese)

    /// 前摄像头画中画预览容器。
    private var pipView: PiPPreviewView?
    /// 上下分屏模式中的前摄像头预览容器。
    private var frontSplitPreviewContainer: PreviewLayerView?

    private let subtitleLabel = UILabel()
    private let recordButton = UIButton(type: .system)
    private let recordingDurationLabel = UILabel()
    private let statusLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private var promptPanel: TeleprompterPanelView?

    /// 录制期间收集的画中画布局关键帧。
    private var pipTrack: [PiPKeyframe] = []
    /// 录制期间收集的上下分屏布局关键帧。
    private var splitScreenTrack: [SplitScreenKeyframe] = []
    /// 分屏拖动开始时的上半部分占比。
    private var splitPanStartTopRatio: CGFloat = 0.5
    /// 当前分屏上半部分高度约束。
    private var splitTopHeightConstraint: Constraint?
    private var subtitleTrack: [SubtitleSegment] = []
    private var recordStartTime: Date?
    private var recordingDurationTimer: Timer?
    /// 录制会话期间为 true，用于收集停止后才到达的最后一段字幕。
    private var subtitleSessionActive = false
    private var pendingFinish: (main: URL?, pip: URL?)?

    // 拍摄设置
    private var aspect = AspectSettings()
    private var videoSettings = DualCameraSource.normalizedVideoSettings(VideoCaptureSettings())
    private var mainPreviewContainer: PreviewLayerView?
    private let mainAspectMask = CAShapeLayer()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        observeAppLifecycle()
        requestPermissionsAndStart()
    }

    deinit {
        recordingDurationTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        // 从编辑页返回后恢复预览
        if source.state == .stopped || source.state == .configured {
            source.startRunning()
            stopRecordingDurationTimer()
            applyRecordButtonState(isRecording: false)
        }
    }

    // MARK: - UI

    private func setupUI() {
        // 字幕
        subtitleLabel.textColor = .white
        subtitleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        subtitleLabel.numberOfLines = 3
        subtitleLabel.textAlignment = .center
        subtitleLabel.shadowColor = .black
        subtitleLabel.shadowOffset = CGSize(width: 0, height: 1)
        subtitleLabel.layer.shadowRadius = 3
        view.addSubview(subtitleLabel)

        // 录制按钮
        recordButton.applyAppPrimaryButtonStyle(cornerRadius: 36, shadow: true)
        recordButton.adjustsImageWhenHighlighted = true
        recordButton.addTarget(self, action: #selector(toggleRecording), for: .touchUpInside)
        applyRecordButtonState(isRecording: false)
        view.addSubview(recordButton)

        // 录制时长
        recordingDurationLabel.isHidden = true
        recordingDurationLabel.textColor = .white
        recordingDurationLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        recordingDurationLabel.textAlignment = .center
        recordingDurationLabel.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        recordingDurationLabel.layer.cornerRadius = 10
        recordingDurationLabel.clipsToBounds = true
        view.addSubview(recordingDurationLabel)

        // 状态
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 3
        view.addSubview(statusLabel)

        // 关闭（返回首页）
        closeButton.setImage(UIImage(named: "nav_back"), for: .normal)
        closeButton.tintColor = .white
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        // 右侧功能按钮列：比例 / 提示词 / 参数
        let aspectBtn = makeSideButton("aspectratio", "比例", #selector(aspectTapped))
        let promptBtn = makeSideButton("text.alignleft", "提示词", #selector(promptTapped))
        let parameterBtn = makeSideButton("slider.horizontal.3", "参数", #selector(parametersTapped))
        let sideStack = UIStackView(arrangedSubviews: [aspectBtn, promptBtn, parameterBtn])
        sideStack.axis = .vertical
        sideStack.spacing = 20
        sideStack.alignment = .center
        view.addSubview(sideStack)

        subtitleLabel.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.bottom.equalTo(recordingDurationLabel.snp.top).offset(-16)
        }

        recordButton.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalTo(view.safeAreaLayoutGuide).inset(24)
            make.size.equalTo(72)
        }

        recordingDurationLabel.snp.makeConstraints { make in
            make.centerX.equalTo(recordButton)
            make.bottom.equalTo(recordButton.snp.top).offset(-10)
            make.height.equalTo(28)
            make.width.greaterThanOrEqualTo(56)
        }

        statusLabel.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalTo(closeButton.snp.bottom)
            make.trailing.equalToSuperview().inset(16)
            make.left.equalTo(closeButton.snp.right).offset(16)
        }

        closeButton.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(4)
            make.leading.equalToSuperview().offset(16)
            make.size.equalTo(40)
        }

        sideStack.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(60)
            make.trailing.equalToSuperview().inset(12)
        }
    }

    private func makeSideButton(_ icon: String, _ title: String, _ action: Selector) -> UIView {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: icon), for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        button.layer.cornerRadius = 22
        button.addTarget(self, action: action, for: .touchUpInside)
        button.snp.makeConstraints { make in
            make.size.equalTo(44)
        }

        let label = UILabel()
        label.text = title
        label.textColor = .white
        label.font = .systemFont(ofSize: 11)
        label.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [button, label])
        stack.axis = .vertical
        stack.spacing = 3
        stack.alignment = .center
        return stack
    }

    // MARK: - Permissions & setup

    private func requestPermissionsAndStart() {
        guard DualCameraSource.isSupported else {
            statusLabel.text = "此设备不支持前后双摄（需 A12 芯片 / iPhone XS 及以上）"
            recordButton.isEnabled = false
            return
        }

        requestCameraAndMic { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.statusLabel.text = "需要相机和麦克风权限"
                return
            }
            LiveSpeechRecognizer.requestAuthorization { speechGranted in
                self.setupSession(speechGranted: speechGranted)
            }
        }
    }

    private func requestCameraAndMic(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { camGranted in
            AVCaptureDevice.requestAccess(for: .audio) { micGranted in
                DispatchQueue.main.async { completion(camGranted && micGranted) }
            }
        }
    }

    private func setupSession(speechGranted: Bool) {
        source.delegate = self
        videoSettings = DualCameraSource.normalizedVideoSettings(videoSettings)
        do {
            try source.configure()
        } catch {
            statusLabel.text = "初始化失败：\(error.localizedDescription)"
            return
        }

        // 主画面预览（后摄，全屏）
        if let mainLayer = source.makeMainPreviewLayer() {
            let container = PreviewLayerView(previewLayer: mainLayer, videoGravity: mainPreviewGravity)
            let dismissKeyboardTap = UITapGestureRecognizer(target: self, action: #selector(dismissPromptKeyboard))
            dismissKeyboardTap.cancelsTouchesInView = false
            container.addGestureRecognizer(dismissKeyboardTap)
            addSplitGestures(to: container)
            view.insertSubview(container, at: 0)
            container.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
            mainPreviewContainer = container
            // 主比例遮罩（黑边）叠加在预览上，反映所选主比例的取景区
            mainAspectMask.fillColor = UIColor.black.cgColor
            mainAspectMask.fillRule = .evenOdd
            container.layer.addSublayer(mainAspectMask)
            DispatchQueue.main.async { self.applyMainAspectMask() }
        }

        updateCameraPresentation()

        // 字幕
        if speechGranted {
            speech.onText = { [weak self] text, _ in
                self?.subtitleLabel.text = text
            }
            // 用逐词时间戳做精准语意分段（录制会话期间的所有 final 都收集，包括停止后到达的最后一段）
            speech.onFinalTranscription = { [weak self] transcription, offset in
                guard let self, self.subtitleSessionActive else { return }
                let segs = SubtitleSegmenter.segments(from: transcription, timeOffset: offset)
                self.subtitleTrack.append(contentsOf: segs)
            }
        } else {
            statusLabel.text = "未授权语音识别，字幕不可用"
        }

        recordButton.isEnabled = false
        statusLabel.text = "相机启动中…"
        source.startRunning { [weak self] isRunning in
            guard let self else { return }
            self.recordButton.isEnabled = isRunning
            if isRunning {
                self.statusLabel.text = self.readyStatusText()
            }
        }
    }

    // MARK: - Recording

    @objc private func toggleRecording() {
        switch source.state {
        case .recording:
            source.stopRecording()
            speech.stop()
            promptPanel?.stopAutoScroll()
            stopRecordingDurationTimer()
            applyRecordButtonState(isRecording: false)
        case .configured, .stopped:
            beginRecording()
        case .failed, .idle:
            recoverCamera(startRecordingWhenReady: true)
        }
    }

    private func beginRecording() {
        recordStartTime = Date()
        pipTrack.removeAll()
        splitScreenTrack.removeAll()
        subtitleTrack.removeAll()
        subtitleSessionActive = true
        pendingFinish = nil
        startRecordingDurationTimer()
        recordPiPKeyframe()
        recordSplitScreenKeyframe()
        source.startRecording(includePiP: aspect.recordsSecondaryVideo)
        speech.start()
        promptPanel?.startAutoScroll()
        applyRecordButtonState(isRecording: true)
    }

    private func applyRecordButtonState(isRecording: Bool) {
        let symbolName = isRecording ? "pause.fill" : "play.fill"
        let configuration = UIImage.SymbolConfiguration(pointSize: 28, weight: .bold)
        recordButton.setImage(UIImage(systemName: symbolName, withConfiguration: configuration), for: .normal)
        recordButton.accessibilityLabel = isRecording ? "停止录制" : "开始录制"
    }

    private func startRecordingDurationTimer() {
        stopRecordingDurationTimer()
        updateRecordingDurationLabel()
        recordingDurationLabel.isHidden = false
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateRecordingDurationLabel()
        }
        recordingDurationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRecordingDurationTimer() {
        recordingDurationTimer?.invalidate()
        recordingDurationTimer = nil
        recordingDurationLabel.isHidden = true
    }

    private func updateRecordingDurationLabel() {
        let elapsed = recordStartTime.map { Date().timeIntervalSince($0) } ?? 0
        recordingDurationLabel.text = Self.formatRecordingDuration(elapsed)
    }

    private static func formatRecordingDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration))
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600

        if hours > 0 {
            return "\(hours)小时\(minutes)分钟\(seconds)秒"
        }
        if totalSeconds >= 60 {
            return "\(minutes)分钟\(seconds)秒"
        }
        return "\(seconds)秒"
    }

    private func recordPiPKeyframe() {
        guard aspect.isPiPEnabled else { return }
        guard let pip = pipView else { return }
        let layout = pip.normalizedLayout(in: view)
        let t = recordStartTime.map { Date().timeIntervalSince($0) } ?? 0
        pipTrack.append(PiPKeyframe(time: t,
                                    center: layout.center,
                                    size: layout.size,
                                    cornerRadius: layout.cornerRadius))
    }

    /// 记录当前上下分屏顺序和显示占比关键帧。
    private func recordSplitScreenKeyframe() {
        guard aspect.isSplitScreenEnabled else { return }
        let t = recordStartTime.map { Date().timeIntervalSince($0) } ?? 0
        splitScreenTrack.append(SplitScreenKeyframe(time: t,
                                                    order: aspect.splitOrder,
                                                    topRatio: aspect.splitTopRatio))
    }

    // MARK: - Settings sheets

    @objc private func closeTapped() {
        promptPanel?.stopAutoScroll()
        navigationController?.popToRootViewController(animated: true)
    }

    private func observeAppLifecycle() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appWillResignActive),
                                               name: UIApplication.willResignActiveNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification,
                                               object: nil)
    }

    @objc private func appWillResignActive() {
        guard isRecordingPageVisible else { return }
        guard source.state != .idle, source.state != .recording else { return }
        recordButton.isEnabled = false
        statusLabel.text = "相机已暂停，返回后自动恢复"
        source.stopRunning()
    }

    @objc private func appDidBecomeActive() {
        guard isRecordingPageVisible else { return }
        guard source.state != .idle, source.state != .recording else { return }
        recoverCamera(startRecordingWhenReady: false)
    }

    private var isRecordingPageVisible: Bool {
        isViewLoaded && view.window != nil && navigationController?.topViewController === self
    }

    private func recoverCamera(startRecordingWhenReady: Bool) {
        recordButton.isEnabled = false
        statusLabel.text = "相机恢复中…"
        source.recoverAfterInterruption { [weak self] isRunning in
            guard let self else { return }
            self.recordButton.isEnabled = isRunning
            guard isRunning else {
                self.statusLabel.text = "相机恢复失败，请退出后重试"
                self.applyRecordButtonState(isRecording: false)
                return
            }
            self.statusLabel.text = self.readyStatusText()
            self.applyRecordButtonState(isRecording: false)
            if startRecordingWhenReady {
                self.beginRecording()
            }
        }
    }

    @objc private func promptTapped() {
        showPromptPanel()
    }

    @objc private func dismissPromptKeyboard() {
        promptPanel?.dismissKeyboard()
    }

    /// 长按分屏画面时切换前后摄像头上下顺序。
    @objc private func splitPreviewLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard aspect.isSplitScreenEnabled, gesture.state == .began else { return }
        aspect.splitOrder.toggle()
        updateSplitPreviewLayout(animated: true)
        recordSplitScreenKeyframe()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// 单指上下滑动分屏画面时调整上半部分显示占比。
    @objc private func splitPreviewPanned(_ gesture: UIPanGestureRecognizer) {
        guard aspect.isSplitScreenEnabled, view.bounds.height > 0 else { return }
        switch gesture.state {
        case .began:
            splitPanStartTopRatio = aspect.splitTopRatio
        case .changed, .ended:
            let translationY = gesture.translation(in: view).y
            let nextRatio = splitPanStartTopRatio + translationY / view.bounds.height
            aspect.splitTopRatio = AspectSettings.clampedSplitTopRatio(nextRatio)
            updateSplitTopRatioLayout()
            recordSplitScreenKeyframe()
        default:
            break
        }
    }

    @objc private func aspectTapped() {
        let sheet = AspectSettingsViewController(settings: aspect)
        sheet.onChange = { [weak self] settings in
            self?.aspect = settings
            self?.updateCameraPresentation()
            self?.applyPiPStyle()
            self?.applyMainAspectMask()
            self?.recordPiPKeyframe()
            self?.recordSplitScreenKeyframe()
        }
        presentSheet(sheet)
    }

    @objc private func parametersTapped() {
        guard source.state != .recording else {
            statusLabel.text = "录制中不可调整参数"
            return
        }
        let sheet = CaptureParameterSettingsViewController(
            settings: videoSettings,
            availableBackResolutions: DualCameraSource.supportedVideoResolutions(for: .back),
            backFrameRatesProvider: { resolution in
                DualCameraSource.supportedFrameRates(for: .back, resolution: resolution)
            },
            availableFrontResolutions: DualCameraSource.supportedVideoResolutions(for: .front),
            frontFrameRatesProvider: { resolution in
                DualCameraSource.supportedFrameRates(for: .front, resolution: resolution)
            },
            showsFrontSettings: aspect.recordsSecondaryVideo,
            frontSectionTitle: aspect.isSplitScreenEnabled ? "前摄像头（分屏）" : "前摄像头（小窗）"
        )
        sheet.onChange = { [weak self] settings in
            self?.applyVideoSettings(settings)
        }
        presentSheet(sheet)
    }

    private func applyVideoSettings(_ settings: VideoCaptureSettings) {
        let normalizedSettings = DualCameraSource.normalizedVideoSettings(settings)
        videoSettings = normalizedSettings
        recordButton.isEnabled = false
        statusLabel.text = "正在切换到 \(parameterStatusText(for: normalizedSettings))…"
        source.updateVideoSettings(normalizedSettings) { [weak self] appliedSettings, didApply in
            guard let self else { return }
            self.videoSettings = appliedSettings
            self.recordButton.isEnabled = didApply && self.source.state != .idle
            self.statusLabel.text = didApply ? self.readyStatusText() : "参数切换失败，请选择较低规格"
        }
    }

    private func showPromptPanel() {
        let panel = promptPanel ?? makePromptPanel()
        panel.isHidden = false
        view.layoutIfNeeded()
        layoutPromptPanelIfNeeded()
        view.bringSubviewToFront(panel)
        if source.state == .recording {
            panel.startAutoScroll()
        }
    }

    private func makePromptPanel() -> TeleprompterPanelView {
        let panel = TeleprompterPanelView()
        panel.isHidden = true
        panel.onClose = { [weak self] in
            self?.hidePromptPanel()
        }
        view.addSubview(panel)
        promptPanel = panel
        return panel
    }

    private func hidePromptPanel() {
        promptPanel?.stopAutoScroll()
        promptPanel?.isHidden = true
    }

    private func layoutPromptPanelIfNeeded() {
        guard let panel = promptPanel, !panel.isHidden else { return }
        updatePromptPanelDragBoundary(panel)
        if panel.hasCustomPosition {
            panel.fitInsideSuperview()
        } else {
            panel.frame = defaultPromptPanelFrame()
        }
    }

    private func updatePromptPanelDragBoundary(_ panel: TeleprompterPanelView) {
        panel.maximumBottomY = recordButton.frame.minY - 12
    }

    private func defaultPromptPanelFrame() -> CGRect {
        let horizontalInset: CGFloat = 16
        let topSpacing: CGFloat = 12
        let bottomSpacing: CGFloat = 12
        let minimumHeight: CGFloat = 280
        let fallbackSubtitleHeight = subtitleLabel.font.lineHeight * CGFloat(max(subtitleLabel.numberOfLines, 1))
        let top = max(view.safeAreaInsets.top + 56, closeButton.frame.maxY + topSpacing)
        let subtitleTop = subtitleLabel.frame.height > 1
            ? subtitleLabel.frame.minY
            : recordButton.frame.minY - 24 - fallbackSubtitleHeight
        let recordButtonTop = recordButton.frame.minY - bottomSpacing
        let preferredBottom = min(view.bounds.height - view.safeAreaInsets.bottom - horizontalInset,
                                  recordButtonTop,
                                  subtitleTop - bottomSpacing)
        let availableBottom = min(view.bounds.height - view.safeAreaInsets.bottom - horizontalInset,
                                  recordButtonTop)
        let preferredHeight = max(minimumHeight, preferredBottom - top)
        let availableHeight = max(220, availableBottom - top)
        let panelHeight = min(preferredHeight, availableHeight)
        let panelWidth = max(0, view.bounds.width - horizontalInset * 2)
        return CGRect(x: horizontalInset, y: top, width: panelWidth, height: panelHeight)
    }

    /// 用黑边遮罩把主预览裁到所选主比例的取景区（居中）。
    private func applyMainAspectMask() {
        guard let container = mainPreviewContainer else { return }
        let bounds = container.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        mainAspectMask.frame = bounds
        guard !aspect.isSplitScreenEnabled, !aspect.main.isDefault else {
            mainAspectMask.path = nil
            return
        }

        let ratio = aspect.main.ratio // 宽/高
        // 以宽度为基准算取景区高度，若超过则以高度为基准
        var cropW = bounds.width
        var cropH = cropW / ratio
        if cropH > bounds.height {
            cropH = bounds.height
            cropW = cropH * ratio
        }
        let cropRect = CGRect(x: (bounds.width - cropW) / 2,
                              y: (bounds.height - cropH) / 2,
                              width: cropW, height: cropH)
        // evenOdd：整屏黑，挖掉取景区 → 取景区外显示黑边
        let path = UIBezierPath(rect: bounds)
        path.append(UIBezierPath(rect: cropRect))
        mainAspectMask.path = path.cgPath
    }

    private func presentSheet(_ vc: UIViewController) {
        vc.modalPresentationStyle = .overFullScreen
        vc.modalTransitionStyle = .crossDissolve
        present(vc, animated: true)
    }

    /// 应用小窗比例与圆角到预览。
    private func applyPiPStyle() {
        guard aspect.isPiPEnabled else { return }
        guard let pip = pipView else { return }
        let style = aspect.pip
        let width = pip.bounds.width
        let height = style.aspect.defaultSize(forWidth: width).height
        var frame = pip.frame
        frame.size.height = height
        frame.origin.y = min(frame.origin.y, view.bounds.height - frame.height)
        pip.frame = frame
        // 最大圆角 = min(宽,高)/2（正方形时为圆形）
        let maxRadius = min(frame.width, frame.height) / 2
        pip.layer.cornerRadius = maxRadius * style.cornerRatio
    }

    private func updateCameraPresentation() {
        mainPreviewContainer?.videoGravity = mainPreviewGravity
        if aspect.isSplitScreenEnabled {
            pipView?.removeFromSuperview()
            pipView = nil
            ensureSplitPreviewView()
            updateSplitPreviewLayout(animated: false)
        } else {
            frontSplitPreviewContainer?.removeFromSuperview()
            frontSplitPreviewContainer = nil
            splitTopHeightConstraint = nil
            updatePiPVisibility()
            updateMainPreviewLayoutForFullScreen()
        }
        if source.state == .configured {
            statusLabel.text = readyStatusText()
        }
    }

    private func updatePiPVisibility() {
        if aspect.isPiPEnabled && !aspect.isSplitScreenEnabled {
            ensurePiPView()
            pipView?.isHidden = false
        } else {
            pipView?.removeFromSuperview()
            pipView = nil
            pipTrack.removeAll()
        }
    }

    private func ensureSplitPreviewView() {
        guard frontSplitPreviewContainer == nil, let frontLayer = source.makePiPPreviewLayer() else { return }
        let container = PreviewLayerView(previewLayer: frontLayer, videoGravity: .resizeAspectFill)
        addSplitGestures(to: container)
        if let mainPreviewContainer {
            view.insertSubview(container, aboveSubview: mainPreviewContainer)
        } else {
            view.insertSubview(container, at: 0)
        }
        frontSplitPreviewContainer = container
    }

    private func updateMainPreviewLayoutForFullScreen() {
        guard let mainPreviewContainer else { return }
        mainPreviewContainer.videoGravity = mainPreviewGravity
        mainPreviewContainer.snp.remakeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    /// 按当前分屏顺序和上半屏占比刷新前后摄像头预览区域。
    private func updateSplitPreviewLayout(animated: Bool) {
        guard let mainPreviewContainer, let frontSplitPreviewContainer else { return }
        let topHeight = splitTopHeight()
        let animations = {
            self.splitTopHeightConstraint = nil
            if self.aspect.splitOrder == .frontTop {
                frontSplitPreviewContainer.snp.remakeConstraints { make in
                    make.top.leading.trailing.equalToSuperview()
                    self.splitTopHeightConstraint = make.height.equalTo(topHeight).constraint
                }
                mainPreviewContainer.snp.remakeConstraints { make in
                    make.leading.trailing.bottom.equalToSuperview()
                    make.top.equalTo(frontSplitPreviewContainer.snp.bottom)
                }
            } else {
                mainPreviewContainer.snp.remakeConstraints { make in
                    make.top.leading.trailing.equalToSuperview()
                    self.splitTopHeightConstraint = make.height.equalTo(topHeight).constraint
                }
                frontSplitPreviewContainer.snp.remakeConstraints { make in
                    make.leading.trailing.bottom.equalToSuperview()
                    make.top.equalTo(mainPreviewContainer.snp.bottom)
                }
            }
            self.view.layoutIfNeeded()
            self.applyMainAspectMask()
        }
        if animated {
            UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseInOut], animations: animations)
        } else {
            animations()
        }
    }

    /// 根据当前屏幕高度计算分屏上半部分高度。
    private func splitTopHeight() -> CGFloat {
        guard view.bounds.height > 0 else { return 0 }
        let ratio = AspectSettings.clampedSplitTopRatio(aspect.splitTopRatio)
        return view.bounds.height * ratio
    }

    /// 在屏幕尺寸变化后刷新分屏高度约束。
    private func updateSplitTopHeightConstraintIfNeeded() {
        guard aspect.isSplitScreenEnabled else { return }
        splitTopHeightConstraint?.update(offset: splitTopHeight())
    }

    /// 仅更新分屏占比对应的高度约束，不重建上下视图约束。
    private func updateSplitTopRatioLayout() {
        guard splitTopHeightConstraint != nil else {
            updateSplitPreviewLayout(animated: false)
            return
        }
        updateSplitTopHeightConstraintIfNeeded()
        view.layoutIfNeeded()
        applyMainAspectMask()
    }

    /// 给分屏预览区域添加长按切换和单指滑动调占比手势。
    private func addSplitGestures(to preview: UIView) {
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(splitPreviewLongPressed(_:)))
        longPress.minimumPressDuration = 0.45
        preview.addGestureRecognizer(longPress)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(splitPreviewPanned(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        preview.addGestureRecognizer(pan)
    }

    private func readyStatusText() -> String {
        let parameterText = parameterStatusText(for: videoSettings)
        if aspect.isSplitScreenEnabled {
            return "就绪：\(parameterText)，上下分屏，长按切换位置，单指上下滑动调整占比"
        }
        if aspect.isPiPEnabled {
            return "就绪：\(parameterText)，拖动/双指缩放小窗，点按开始录制"
        }
        return "就绪：\(parameterText)，点按开始录制"
    }

    private func parameterStatusText(for settings: VideoCaptureSettings) -> String {
        guard aspect.recordsSecondaryVideo else { return "后 \(settings.back.displayText)" }
        return "后 \(settings.back.displayText) / 前 \(settings.front.displayText)"
    }

    private func ensurePiPView() {
        guard pipView == nil, let pipLayer = source.makePiPPreviewLayer() else { return }
        let content = PreviewLayerView(previewLayer: pipLayer, videoGravity: .resizeAspectFill)
        let pip = PiPPreviewView(contentView: content)
        view.layoutIfNeeded()
        pip.frame = CGRect(x: closeButton.frame.minX,
                           y: closeButton.frame.maxY + 12,
                           width: 110,
                           height: aspect.pip.aspect.defaultSize(forWidth: 110).height)
        pip.onLayoutChanged = { [weak self] in self?.recordPiPKeyframe() }
        view.addSubview(pip)
        pipView = pip
        applyPiPStyle()
        if let promptPanel, !promptPanel.isHidden {
            view.bringSubviewToFront(promptPanel)
        }
    }

    private var mainPreviewGravity: AVLayerVideoGravity {
        .resizeAspectFill
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateSplitTopHeightConstraintIfNeeded()
        applyMainAspectMask()
        layoutPromptPanelIfNeeded()
    }
}

// MARK: - CaptureSourceDelegate

extension RecordingViewController: CaptureSourceDelegate {
    func captureSource(_ source: CaptureSourceProviding, didChange state: CaptureState) {
        switch state {
        case .recording: statusLabel.text = "● 录制中…"
        case .stopped: statusLabel.text = "录制完成"
        case .failed(let msg):
            statusLabel.text = "错误：\(msg)"
            speech.stop()
            promptPanel?.stopAutoScroll()
            stopRecordingDurationTimer()
            subtitleSessionActive = false
            pendingFinish = nil
            applyRecordButtonState(isRecording: false)
        default: break
        }
    }

    func captureSource(_ source: CaptureSourceProviding,
                       didFinishRecordingMain mainURL: URL?,
                       pip pipURL: URL?) {
        // 视频文件已就绪，但语音识别的最后一段 final 可能稍后才到达。
        // 给识别 0.8s 缓冲收集最后一段字幕，再跳转编辑页。
        pendingFinish = (mainURL, pipURL)
        statusLabel.text = "正在整理字幕…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.presentEditor()
        }
    }

    private func presentEditor() {
        guard let pending = pendingFinish else { return }
        pendingFinish = nil
        subtitleSessionActive = false

        let elapsedDuration = recordStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let duration = Self.mediaDuration(for: pending.main, fallback: elapsedDuration)
        let project = RecordingProject(
            mainVideoURL: pending.main,
            pipVideoURL: aspect.recordsSecondaryVideo ? pending.pip : nil,
            duration: duration,
            pipTrack: aspect.isPiPEnabled ? pipTrack : [],
            splitScreenTrack: aspect.isSplitScreenEnabled ? splitScreenTrack : [],
            subtitleTrack: subtitleTrack.sorted { $0.startTime < $1.startTime },
            aspect: aspect,
            sourceKind: .camera,
            captureViewportSize: view.bounds.size
        )
        self.source.stopRunning()
        let editor = EditorViewController(project: project)
        navigationController?.pushViewController(editor, animated: true)
    }

    private static func mediaDuration(for url: URL?, fallback: TimeInterval) -> TimeInterval {
        guard let url else { return fallback }
        let asset = AVURLAsset(url: url)
        let videoDuration = asset.tracks(withMediaType: .video)
            .map { $0.timeRange.end.seconds }
            .max() ?? 0
        let audioDuration = asset.tracks(withMediaType: .audio)
            .map { $0.timeRange.end.seconds }
            .max() ?? 0
        let candidates: [TimeInterval] = [asset.duration.seconds, videoDuration, audioDuration, fallback]
        return candidates.first { $0.isFinite && $0 > 0 } ?? 0
    }

    func captureSource(_ source: CaptureSourceProviding, didOutput audioBuffer: CMSampleBuffer) {
        speech.append(audioBuffer)
    }
}
