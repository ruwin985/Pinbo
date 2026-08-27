import AppKit
import AVFoundation
import SnapKit

final class MacRecordingViewController: NSViewController {
    var onFinish: ((RecordingProject) -> Void)?
    var onCancel: (() -> Void)?

    private let target: ScreenCaptureTarget
    /// 当前录制目标可提供的分辨率选项。
    private let availableResolutions: [MacRecordingResolution]
    private lazy var source = ScreenCameraSource(target: target)
    private let speech = LiveSpeechRecognizer(language: .chinese)

    private let previewContainer = NSView()
    private let screenPreview = ScreenPreviewView()
    private let toolbar = NSVisualEffectView()
    private let closeButton = NSButton(title: "重选窗口", target: nil, action: nil)
    private let recordButton = NSButton(title: "开始录制", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let durationLabel = NSTextField(labelWithString: "00:00")
    /// 开启字幕后显示在预览底部的可拖动字幕区域。
    private let subtitleRegion = DraggableSubtitleView()
    /// 合成期间覆盖预览区域的加载遮罩。
    private let processingOverlay = NSVisualEffectView()
    /// 合成期间持续旋转的加载指示器。
    private let processingIndicator = NSProgressIndicator()
    /// 合成加载遮罩的主提示文字。
    private let processingTitleLabel = NSTextField(labelWithString: "正在合成视频…")
    /// 合成加载遮罩的补充说明文字。
    private let processingDetailLabel = NSTextField(labelWithString: "字幕与画面正在写入视频，请稍候")
    /// 打开录制参数浮窗的入口按钮。
    private let parameterButton = NSButton(title: "参数", target: nil, action: nil)
    private let cameraToggle = NSButton(checkboxWithTitle: "开启摄像头小窗", target: nil, action: nil)
    private let subtitleToggle = NSButton(checkboxWithTitle: "开启字幕", target: nil, action: nil)

    private var pipView: DraggablePiPView?
    /// 当前展示中的录制参数浮窗。
    private var parameterPopover: NSPopover?
    /// 当前展示中的录制参数控制器。
    private weak var parameterController: MacRecordingParameterViewController?
    /// 当前录制页使用的分辨率和帧速率。
    private var recordingSettings: MacRecordingSettings
    /// 当前屏幕采集流实际输出的格式状态。
    private var latestCaptureStatus: MacScreenCaptureStatus?
    /// 用于忽略较早一次参数应用回调的序号。
    private var settingsUpdateSerial = 0
    /// 当前是否正在重新配置录制采集流。
    private var isApplyingRecordingSettings = false
    /// 当前是否正在请求或切换默认输入设备。
    private var isPreparingRecordingAudio = false
    private var aspect = AspectSettings()
    private var pipTrack: [PiPKeyframe] = []
    private var subtitleTrack: [SubtitleSegment] = []
    /// 当前字幕区域的归一化布局，拖动后同步用于最终视频合成。
    private var subtitleLayout = SubtitleLayout(center: CGPoint(x: 0.5, y: 0.82), maxWidth: 0.72, fontScale: 1)
    private var recordStartTime: Date?
    private var durationTimer: Timer?
    private var subtitleSessionActive = false
    private var isSubtitleEnabled = false
    private var isSpeechRecognitionAvailable = false
    private var isSpeechRunning = false
    private var isSpeechCallbacksConfigured = false
    /// 语音识别最近一次返回的累计文本。
    private var latestRecognitionText = ""
    /// 已经显示并清空过的累计文本，用于避免旧句子反复出现。
    private var consumedRecognitionText = ""
    /// 当前句字幕自动消失任务。
    private var subtitleClearWorkItem: DispatchWorkItem?
    private var pendingFinish: (main: URL?, pip: URL?)?
    /// 双路声音混合后需要清理的原始临时文件。
    private var pendingRecordingCleanupURLs: [URL] = []
    /// 双路声音混合失败时保留的提示信息。
    private var pendingAudioMixWarning: Error?

    init(target: ScreenCaptureTarget) {
        self.target = target
        let sourceSize = target.pixelSize
        let resolutions = MacRecordingResolution.options(for: sourceSize)
        self.availableResolutions = resolutions
        self.recordingSettings = MacRecordingSettingsStore.shared.load(
            availableResolutions: resolutions,
            defaultSettings: MacRecordingSettings.defaultSettings(for: sourceSize))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        configureScreenRecording()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutDefaultPiPIfNeeded()
        layoutSubtitleRegion()
        recordPiPKeyframeIfNeeded()
    }

    deinit {
        durationTimer?.invalidate()
        subtitleClearWorkItem?.cancel()
        source.stopRunning()
    }

    private func setupUI() {
        previewContainer.wantsLayer = true
        previewContainer.layer?.backgroundColor = NSColor.black.cgColor
        view.addSubview(previewContainer)

        previewContainer.addSubview(screenPreview)
        subtitleRegion.isHidden = true
        subtitleRegion.onLayoutChanged = { [weak self] layout in
            self?.subtitleLayout = layout
        }
        previewContainer.addSubview(subtitleRegion)

        toolbar.material = .hudWindow
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 18
        toolbar.layer?.cornerCurve = .continuous
        toolbar.layer?.borderWidth = 1
        toolbar.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        toolbar.layer?.shadowColor = NSColor.black.withAlphaComponent(0.22).cgColor
        toolbar.layer?.shadowOpacity = 1
        toolbar.layer?.shadowRadius = 18
        toolbar.layer?.shadowOffset = CGSize(width: 0, height: 5)
        view.addSubview(toolbar)

        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.bezelStyle = .rounded
        closeButton.controlSize = .regular

        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        recordButton.bezelStyle = .rounded
        recordButton.controlSize = .regular
        recordButton.bezelColor = .controlAccentColor
        recordButton.keyEquivalent = " "
        recordButton.isEnabled = false

        parameterButton.target = self
        parameterButton.action = #selector(parameterTapped)
        parameterButton.bezelStyle = .rounded
        parameterButton.controlSize = .small
        parameterButton.toolTip = "设置录制分辨率和帧速率"

        cameraToggle.target = self
        cameraToggle.action = #selector(cameraToggleChanged)
        cameraToggle.state = .off
        cameraToggle.contentTintColor = .white
        cameraToggle.controlSize = .small

        subtitleToggle.target = self
        subtitleToggle.action = #selector(subtitleToggleChanged)
        subtitleToggle.state = .off
        subtitleToggle.contentTintColor = .white
        subtitleToggle.controlSize = .small

        durationLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        durationLabel.textColor = .labelColor

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle

        let targetLabel = NSTextField(labelWithString: target.title)
        targetLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        targetLabel.textColor = .labelColor
        targetLabel.lineBreakMode = .byTruncatingTail

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let toolbarStack = NSStackView(views: [closeButton, targetLabel, parameterButton, cameraToggle, subtitleToggle, durationLabel, spacer, statusLabel, recordButton])
        toolbarStack.orientation = .horizontal
        toolbarStack.alignment = .centerY
        toolbarStack.spacing = 14
        toolbar.addSubview(toolbarStack)

        processingOverlay.material = .hudWindow
        processingOverlay.blendingMode = .withinWindow
        processingOverlay.state = .active
        processingOverlay.wantsLayer = true
        processingOverlay.layer?.zPosition = 100
        processingOverlay.isHidden = true
        view.addSubview(processingOverlay)

        processingIndicator.style = .spinning
        processingIndicator.controlSize = .large
        processingIndicator.isIndeterminate = true
        processingIndicator.isDisplayedWhenStopped = false

        processingTitleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        processingTitleLabel.textColor = .labelColor
        processingTitleLabel.alignment = .center

        processingDetailLabel.font = .systemFont(ofSize: 13, weight: .regular)
        processingDetailLabel.textColor = .secondaryLabelColor
        processingDetailLabel.alignment = .center

        let processingStack = NSStackView(views: [processingIndicator, processingTitleLabel, processingDetailLabel])
        processingStack.orientation = .vertical
        processingStack.alignment = .centerX
        processingStack.spacing = 12
        processingOverlay.addSubview(processingStack)

        previewContainer.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        screenPreview.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        toolbar.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(22)
            make.bottom.equalTo(view.safeAreaLayoutGuide.snp.bottom).offset(-22)
            make.height.equalTo(56)
        }

        toolbarStack.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.centerY.equalToSuperview()
        }

        processingOverlay.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        processingStack.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.greaterThanOrEqualToSuperview().inset(40)
            make.trailing.lessThanOrEqualToSuperview().inset(40)
        }
    }

    private func configureScreenRecording() {
        statusLabel.stringValue = "正在初始化录屏预览…"
        aspect.isPiPEnabled = false
        source.onStateChange = { [weak self] state in
            self?.updateState(state)
        }
        source.onScreenSampleBuffer = { [weak self] sampleBuffer in
            self?.screenPreview.display(sampleBuffer: sampleBuffer)
        }
        source.onScreenCaptureStatusChange = { [weak self] status in
            guard let self else { return }
            self.latestCaptureStatus = status
            guard self.recordStartTime == nil, !self.isApplyingRecordingSettings else { return }
            self.statusLabel.stringValue = status.displayText
        }
        source.onMicrophoneSampleBuffer = { [weak self] sampleBuffer in
            self?.speech.append(sampleBuffer)
        }
        source.onFinishRecording = { [weak self] mainURL, pipURL in
            self?.recordingFinished(mainURL: mainURL, pipURL: pipURL)
        }

        do {
            try source.configure(settings: recordingSettings)
        } catch {
            statusLabel.stringValue = "初始化失败：\(error.localizedDescription)"
            return
        }

        source.startRunning()
        recordButton.isEnabled = true
        statusLabel.stringValue = "已就绪：\(target.title) · \(recordingSettings.displayText)，等待首帧…"
    }

    private func ensurePiPView(previewLayer: AVCaptureVideoPreviewLayer) {
        guard pipView == nil, aspect.isPiPEnabled else { return }
        let contentView = AVCapturePreviewView(previewLayer: previewLayer)
        let pip = DraggablePiPView(contentView: contentView)
        pip.translatesAutoresizingMaskIntoConstraints = true
        pip.frame = CGRect(x: 0, y: 0, width: 220, height: 150)
        pip.onLayoutChanged = { [weak self] in self?.recordPiPKeyframeIfNeeded() }
        previewContainer.addSubview(pip)
        pipView = pip
        layoutDefaultPiPIfNeeded()
    }

    private func removePiPView() {
        pipView?.removeFromSuperview()
        pipView = nil
        pipTrack.removeAll()
    }

    private func layoutDefaultPiPIfNeeded() {
        guard let pipView else { return }
        guard previewContainer.bounds.width > 0, previewContainer.bounds.height > 0 else { return }
        if pipView.frame.origin == .zero {
            pipView.frame = CGRect(x: previewContainer.bounds.width - 220 - 28,
                                   y: previewContainer.bounds.height - 150 - 88,
                                   width: 220,
                                   height: 150)
        }
    }

    /// 根据当前归一化数据把字幕区域放置在预览画面中。
    private func layoutSubtitleRegion() {
        subtitleRegion.apply(layout: subtitleLayout, in: previewContainer)
    }

    private func recordPiPKeyframeIfNeeded() {
        guard aspect.isPiPEnabled, let pipView else { return }
        guard pipView.superview === previewContainer, previewContainer.bounds.width > 0 else { return }
        let layout = pipView.normalizedLayout(in: previewContainer)
        let time = recordStartTime.map { Date().timeIntervalSince($0) } ?? 0
        pipTrack.append(PiPKeyframe(time: time,
                                    center: layout.center,
                                    size: layout.size,
                                    cornerRadius: layout.cornerRadius))
    }

    @objc private func toggleRecording() {
        if recordStartTime == nil {
            prepareRecordingAudioAndStart()
        } else {
            stopRecording()
        }
    }

    /// 请求默认输入设备权限并刷新外接输入设备，然后开始录制。
    private func prepareRecordingAudioAndStart() {
        guard !isApplyingRecordingSettings, !isPreparingRecordingAudio else { return }
        isPreparingRecordingAudio = true
        recordButton.isEnabled = false
        parameterButton.isEnabled = false
        statusLabel.stringValue = "正在准备电脑声音和输入设备…"

        MacPermissionManager.requestMicrophone { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.finishPreparingRecordingAudio(
                    statusText: "正在录制（仅电脑声音，麦克风未授权）")
                return
            }
            self.source.enableMicrophone { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    let deviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "默认输入设备"
                    self.finishPreparingRecordingAudio(
                        statusText: "正在录制（电脑声音 + \(deviceName)）")
                case .failure(let error):
                    self.finishPreparingRecordingAudio(
                        statusText: "正在录制（仅电脑声音，输入设备不可用：\(error.localizedDescription)）")
                }
            }
        }
    }

    /// 结束声音准备状态，并确保停止按钮可以立即使用。
    private func finishPreparingRecordingAudio(statusText: String) {
        isPreparingRecordingAudio = false
        recordButton.isEnabled = true
        startRecording(statusText: statusText)
    }

    /// 清空上一段录制状态，并按已经准备好的音频来源开始写入。
    private func startRecording(statusText: String) {
        guard !isApplyingRecordingSettings, recordStartTime == nil else { return }
        pipTrack.removeAll()
        subtitleTrack.removeAll()
        pendingRecordingCleanupURLs.removeAll()
        pendingAudioMixWarning = nil
        recordStartTime = Date()
        subtitleSessionActive = false
        pendingFinish = nil
        resetLiveSubtitleState(showPlaceholder: isSubtitleEnabled)
        durationLabel.stringValue = "00:00"
        startDurationTimer()
        recordPiPKeyframeIfNeeded()
        startSpeechIfNeeded()
        source.startRecording(includePiP: aspect.isPiPEnabled && pipView != nil)
        parameterButton.isEnabled = false
        recordButton.isEnabled = true
        recordButton.title = "停止录制"
        statusLabel.stringValue = statusText
    }

    private func stopRecording() {
        stopDurationTimer()
        stopSpeechIfNeeded()
        recordButton.isEnabled = false
        parameterButton.isEnabled = false
        recordButton.title = "正在整理…"
        statusLabel.stringValue = "正在保存录屏和摄像头小窗…"
        source.stopRecording()
    }

    private func recordingFinished(mainURL: URL?, pipURL: URL?) {
        guard let mainURL else {
            completeRecordingFinished(mainURL: nil, pipURL: pipURL)
            return
        }
        statusLabel.stringValue = "正在同步电脑声音和输入设备声音…"
        ScreenRecordingAudioMixer.mixIfNeeded(inputURL: mainURL) { [weak self] result in
            guard let self else {
                if case .success(let outputURL) = result,
                   outputURL.standardizedFileURL != mainURL.standardizedFileURL {
                    try? FileManager.default.removeItem(at: outputURL)
                }
                return
            }
            switch result {
            case .success(let outputURL):
                if outputURL.standardizedFileURL != mainURL.standardizedFileURL {
                    self.pendingRecordingCleanupURLs.append(mainURL)
                }
                self.completeRecordingFinished(mainURL: outputURL, pipURL: pipURL)
            case .failure(let error):
                self.pendingAudioMixWarning = error
                self.completeRecordingFinished(mainURL: mainURL, pipURL: pipURL)
            }
        }
    }

    /// 保存最终主文件地址，并等待语音识别回调完成后进入草稿处理。
    private func completeRecordingFinished(mainURL: URL?, pipURL: URL?) {
        pendingFinish = (mainURL, pipURL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.presentFinishedProject()
        }
    }

    private func presentFinishedProject() {
        guard let pendingFinish else { return }
        self.pendingFinish = nil
        subtitleSessionActive = false
        let elapsedDuration = recordStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let duration = Self.mediaDuration(for: pendingFinish.main, fallback: elapsedDuration)
        let project = RecordingProject(mainVideoURL: pendingFinish.main,
                                       pipVideoURL: aspect.isPiPEnabled ? pendingFinish.pip : nil,
                                       duration: duration,
                                       pipTrack: aspect.isPiPEnabled ? pipTrack : [],
                                       subtitleTrack: isSubtitleEnabled ? subtitleTrack.sorted { $0.startTime < $1.startTime } : [],
                                       subtitleLayout: subtitleLayout,
                                       emphasizesSubtitleKeywords: true,
                                       aspect: aspect,
                                       sourceKind: .screen)
        exportAndSave(project)
    }

    private func exportAndSave(_ project: RecordingProject) {
        guard requiresComposition(for: project) else {
            // 没有画中画、字幕或画幅变换时直接保存原始采集文件，避免无意义的二次缩放。
            saveFinishedProject(project,
                               cleanupURLs: [project.pipVideoURL],
                               audioWarning: pendingAudioMixWarning,
                               statusText: pendingAudioMixWarning == nil
                                ? latestCaptureStatus.map { "录制完成，已保存原始视频 · \($0.displayText)" } ?? "录制完成，已保存原始视频"
                                : nil)
            return
        }

        showProcessingLoading(title: "正在合成视频…",
                              detail: isSubtitleEnabled ? "正在写入字幕和画面，请稍候" : "正在处理录制画面，请稍候")
        statusLabel.stringValue = isSubtitleEnabled ? "正在合成字幕到视频文件…" : "正在合成视频文件…"
        let compositor = VideoCompositor()
        compositor.exportLongEdge = CGFloat(recordingSettings.maximumLongEdge)
        compositor.exportFrameRate = recordingSettings.frameRate.rawValue
        compositor.export(project: project) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let exportedURL):
                var renderedProject = project
                renderedProject.mainVideoURL = exportedURL
                renderedProject.pipVideoURL = nil
                renderedProject.pipTrack = []
                renderedProject.subtitleTrack = []
                renderedProject.aspect = AspectSettings(main: project.aspect.main,
                                                        isPiPEnabled: false,
                                                        pip: project.aspect.pip)
                renderedProject.duration = Self.mediaDuration(for: exportedURL, fallback: project.duration)
                self.saveFinishedProject(renderedProject, cleanupURLs: [project.mainVideoURL, project.pipVideoURL, exportedURL])
            case .failure(let error):
                self.updateProcessingLoading(title: "合成失败，正在保存原始录制…",
                                             detail: "原始视频不会丢失")
                self.statusLabel.stringValue = "字幕合成失败，正在保存原始录制…"
                self.saveFinishedProject(project, cleanupURLs: [project.mainVideoURL, project.pipVideoURL], warning: error)
            }
        }
    }

    /// 判断当前项目是否需要经过视频合成流程。
    private func requiresComposition(for project: RecordingProject) -> Bool {
        project.aspect.recordsSecondaryVideo
            || !project.subtitleTrack.isEmpty
            || !project.aspect.main.isDefault
    }

    private func saveFinishedProject(_ project: RecordingProject,
                                     cleanupURLs: [URL?],
                                     warning: Error? = nil,
                                     audioWarning: Error? = nil,
                                     statusText: String? = nil) {
        do {
            let saved = try DraftStore.shared.save(project)
            let allCleanupURLs = cleanupURLs + pendingRecordingCleanupURLs.map(Optional.some)
            allCleanupURLs.forEach { url in
                guard let url,
                      url.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL else { return }
                try? FileManager.default.removeItem(at: url)
            }
            pendingRecordingCleanupURLs.removeAll()
            pendingAudioMixWarning = nil
            recordStartTime = nil
            recordButton.isEnabled = true
            parameterButton.isEnabled = true
            recordButton.title = "开始录制"
            if let statusText {
                statusLabel.stringValue = statusText
            } else if let warning {
                statusLabel.stringValue = "已保存原始录制，字幕合成失败：\(warning.localizedDescription)"
            } else if let audioWarning {
                statusLabel.stringValue = "录制已保存，但声音同步失败：\(audioWarning.localizedDescription)"
            } else {
                statusLabel.stringValue = "录制完成，已保存草稿"
            }
            hideProcessingLoading()
            onFinish?(saved)
        } catch {
            hideProcessingLoading()
            recordStartTime = nil
            recordButton.isEnabled = true
            parameterButton.isEnabled = true
            recordButton.title = "开始录制"
            statusLabel.stringValue = "录制完成但保存草稿失败：\(error.localizedDescription)"
        }
    }

    @objc private func cameraToggleChanged() {
        if cameraToggle.state == .on {
            requestCameraAndEnablePiP()
        } else {
            aspect.isPiPEnabled = false
            removePiPView()
            source.disableCamera()
        }
    }

    /// 打开录制参数浮窗。
    @objc private func parameterTapped() {
        guard recordStartTime == nil, !isApplyingRecordingSettings else { return }
        if let parameterPopover, parameterPopover.isShown {
            parameterPopover.performClose(nil)
            return
        }

        let parameterController = MacRecordingParameterViewController(settings: recordingSettings,
                                                                       availableResolutions: availableResolutions)
        self.parameterController = parameterController
        parameterController.onChange = { [weak self] settings in
            parameterController.isInteractionEnabled = false
            self?.recordingSettingsChanged(settings)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = parameterController
        popover.contentSize = CGSize(width: 310, height: 192)
        parameterPopover = popover
        popover.show(relativeTo: parameterButton.bounds,
                     of: parameterButton,
                     preferredEdge: .maxY)
    }

    /// 保存参数并重新配置下一次录制使用的采集流。
    private func recordingSettingsChanged(_ settings: MacRecordingSettings) {
        recordingSettings = settings
        settingsUpdateSerial += 1
        let currentSerial = settingsUpdateSerial
        isApplyingRecordingSettings = true
        parameterButton.isEnabled = false
        recordButton.isEnabled = false
        statusLabel.stringValue = "正在应用录制参数…"

        source.updateSettings(settings) { [weak self] result in
            guard let self, currentSerial == self.settingsUpdateSerial else { return }
            self.isApplyingRecordingSettings = false
            self.parameterButton.isEnabled = self.recordStartTime == nil
            self.parameterController?.isInteractionEnabled = true
            switch result {
            case .success:
                MacRecordingSettingsStore.shared.save(settings)
                self.recordButton.isEnabled = true
                self.statusLabel.stringValue = "参数已更新：\(settings.displayText)"
            case .failure(let error):
                self.recordButton.isEnabled = true
                self.statusLabel.stringValue = "参数应用失败：\(error.localizedDescription)"
            }
        }
    }

    @objc private func subtitleToggleChanged() {
        if subtitleToggle.state == .on {
            requestSubtitlePermissionsAndEnable()
        } else {
            disableSubtitles()
        }
    }

    /// 请求摄像头权限，并在授权成功后直接开启摄像头小窗。
    private func requestCameraAndEnablePiP() {
        cameraToggle.isEnabled = false
        statusLabel.stringValue = "正在请求摄像头权限…"
        MacPermissionManager.requestCameraAuthorization { [weak self] result in
            guard let self else { return }
            switch result {
            case .authorized:
                self.enableCameraPiP()
            case .denied:
                self.handleUnavailableCameraPermission(statusText: "摄像头权限未开启，已打开系统授权页面")
            case .restricted:
                self.handleUnavailableCameraPermission(statusText: "当前设备限制了摄像头访问，已打开系统授权页面")
            }
        }
    }

    /// 在权限已授权时配置采集会话并显示摄像头小窗。
    private func enableCameraPiP() {
        statusLabel.stringValue = "正在开启摄像头…"
        source.enableCamera { [weak self] result in
            guard let self else { return }
            self.cameraToggle.isEnabled = true
            switch result {
            case .success(let previewLayer):
                self.aspect.isPiPEnabled = true
                self.ensurePiPView(previewLayer: previewLayer)
                self.recordPiPKeyframeIfNeeded()
                self.statusLabel.stringValue = "摄像头小窗已开启"
            case .failure(let error):
                self.cameraToggle.state = .off
                self.aspect.isPiPEnabled = false
                if MacPermissionManager.isCameraAuthorized {
                    self.statusLabel.stringValue = "无法开启摄像头：\(error.localizedDescription)"
                } else {
                    self.handleUnavailableCameraPermission(statusText: "摄像头权限未开启，已打开系统授权页面")
                }
            }
        }
    }

    /// 恢复摄像头开关状态，并直接打开摄像头权限设置页面。
    private func handleUnavailableCameraPermission(statusText: String) {
        cameraToggle.isEnabled = true
        cameraToggle.state = .off
        aspect.isPiPEnabled = false
        removePiPView()
        source.disableCamera()
        statusLabel.stringValue = statusText
        MacPermissionAlert.openSettings(kind: .camera)
    }

    private func requestSubtitlePermissionsAndEnable() {
        subtitleToggle.isEnabled = false
        statusLabel.stringValue = "正在请求麦克风权限…"
        MacPermissionManager.requestMicrophone { [weak self] micGranted in
            guard let self else { return }
            guard micGranted else {
                self.subtitleToggle.isEnabled = true
                self.subtitleToggle.state = .off
                self.disableSubtitles()
                self.statusLabel.stringValue = "需要麦克风权限才能生成字幕"
                MacPermissionAlert.show(kind: .microphone, in: self.view.window)
                return
            }
            self.statusLabel.stringValue = "正在请求语音识别权限…"
            MacPermissionManager.requestSpeech { [weak self] speechGranted in
                guard let self else { return }
                guard speechGranted else {
                    self.subtitleToggle.isEnabled = true
                    self.subtitleToggle.state = .off
                    self.disableSubtitles()
                    self.statusLabel.stringValue = "需要语音识别权限才能生成字幕"
                    MacPermissionAlert.show(kind: .speech, in: self.view.window)
                    return
                }
                self.source.enableMicrophone { [weak self] result in
                    guard let self else { return }
                    self.subtitleToggle.isEnabled = true
                    switch result {
                    case .success:
                        self.configureSpeechCallbacksIfNeeded()
                        self.isSpeechRecognitionAvailable = true
                        self.isSubtitleEnabled = true
                        self.subtitleRegion.isHidden = false
                        self.subtitleRegion.showPlaceholder()
                        self.layoutSubtitleRegion()
                        self.startSpeechIfNeeded()
                        self.statusLabel.stringValue = "字幕已开启"
                    case .failure(let error):
                        self.subtitleToggle.state = .off
                        self.disableSubtitles()
                        self.statusLabel.stringValue = "无法开启字幕：\(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func disableSubtitles() {
        isSubtitleEnabled = false
        subtitleSessionActive = false
        subtitleRegion.isHidden = true
        resetLiveSubtitleState(showPlaceholder: false)
        stopSpeechIfNeeded()
    }

    private func configureSpeechCallbacksIfNeeded() {
        guard !isSpeechCallbacksConfigured else { return }
        isSpeechCallbacksConfigured = true
        speech.onText = { [weak self] text, isFinal in
            guard let self else { return }
            if self.isSubtitleEnabled {
                self.updateLiveSubtitle(text, isFinal: isFinal)
            }
        }
        speech.onFinalTranscription = { [weak self] transcription, offset in
            guard let self, self.subtitleSessionActive else { return }
            let segments = SubtitleSegmenter.segments(from: transcription, timeOffset: offset)
            self.subtitleTrack.append(contentsOf: segments)
        }
    }

    private func startSpeechIfNeeded() {
        guard recordStartTime != nil, isSubtitleEnabled, isSpeechRecognitionAvailable, !isSpeechRunning else { return }
        let offset = recordStartTime.map { Date().timeIntervalSince($0) } ?? 0
        subtitleSessionActive = true
        speech.start(timeOffset: offset)
        isSpeechRunning = true
    }

    private func stopSpeechIfNeeded() {
        guard isSpeechRunning else { return }
        speech.stop()
        isSpeechRunning = false
    }

    /// 从累计识别结果中提取当前句，并在用户停顿后自动清空。
    private func updateLiveSubtitle(_ text: String, isFinal: Bool) {
        latestRecognitionText = text
        let incrementalText: String
        if !consumedRecognitionText.isEmpty, text.hasPrefix(consumedRecognitionText) {
            incrementalText = String(text.dropFirst(consumedRecognitionText.count))
        } else {
            incrementalText = text
        }
        let sentence = SubtitleSegmenter.currentDisplaySentence(from: incrementalText)
        guard !sentence.isEmpty else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSMutableAttributedString(string: sentence, attributes: [
            .font: NSFont.systemFont(ofSize: 23, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ])
        SubtitleEmphasisDetector.ranges(in: sentence).forEach { range in
            attributed.addAttributes([
                .font: NSFont.systemFont(ofSize: 28, weight: .bold),
                .foregroundColor: NSColor.systemYellow,
                .baselineOffset: -1.5
            ], range: range)
        }
        subtitleRegion.showSubtitle(attributed)
        scheduleLiveSubtitleClear(after: isFinal ? 0.65 : 1.1)
    }

    /// 在指定停顿时间后清空当前句，同时把已显示累计文本标记为已消费。
    private func scheduleLiveSubtitleClear(after delay: TimeInterval) {
        subtitleClearWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isSubtitleEnabled else { return }
            self.consumedRecognitionText = self.latestRecognitionText
            self.subtitleRegion.showPlaceholder()
        }
        subtitleClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// 重置实时字幕累计状态，并按需显示字幕区域占位提示。
    private func resetLiveSubtitleState(showPlaceholder: Bool) {
        subtitleClearWorkItem?.cancel()
        subtitleClearWorkItem = nil
        latestRecognitionText = ""
        consumedRecognitionText = ""
        if showPlaceholder {
            subtitleRegion.showPlaceholder()
        }
    }

    /// 显示合成加载遮罩并阻止用户重复操作录制页面。
    private func showProcessingLoading(title: String, detail: String) {
        processingTitleLabel.stringValue = title
        processingDetailLabel.stringValue = detail
        processingOverlay.isHidden = false
        processingIndicator.startAnimation(nil)
    }

    /// 更新合成加载遮罩中的状态说明。
    private func updateProcessingLoading(title: String, detail: String) {
        processingTitleLabel.stringValue = title
        processingDetailLabel.stringValue = detail
    }

    /// 隐藏合成加载遮罩并停止加载动画。
    private func hideProcessingLoading() {
        processingIndicator.stopAnimation(nil)
        processingOverlay.isHidden = true
    }

    @objc private func closeTapped() {
        if recordStartTime != nil {
            stopRecording()
        } else {
            source.stopRunning()
            onCancel?()
        }
    }

    private func updateState(_ state: CaptureState) {
        switch state {
        case .idle:
            statusLabel.stringValue = "等待初始化"
        case .configured:
            statusLabel.stringValue = latestCaptureStatus?.displayText ?? "已配置：\(recordingSettings.displayText)，等待首帧…"
        case .recording:
            statusLabel.stringValue = "正在录制…"
        case .stopped:
            statusLabel.stringValue = "录制已停止"
        case .failed(let message):
            statusLabel.stringValue = "错误：\(message)"
        }
    }

    private func startDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordStartTime else { return }
            self.durationLabel.stringValue = Self.formatDuration(Date().timeIntervalSince(start))
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
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
        let candidates = [asset.duration.seconds, videoDuration, audioDuration, fallback]
        return candidates.first { $0.isFinite && $0 > 0 } ?? 0
    }
}
