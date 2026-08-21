import AppKit
import AVFoundation
import SnapKit

final class MacRecordingViewController: NSViewController {
    var onFinish: ((RecordingProject) -> Void)?
    var onCancel: (() -> Void)?

    private let target: ScreenCaptureTarget
    private lazy var source = ScreenCameraSource(target: target)
    private let speech = LiveSpeechRecognizer(language: .chinese)

    private let previewContainer = NSView()
    private let screenPreview = ScreenPreviewView()
    private let toolbar = NSVisualEffectView()
    private let closeButton = NSButton(title: "重选窗口", target: nil, action: nil)
    private let recordButton = NSButton(title: "开始录制", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let durationLabel = NSTextField(labelWithString: "00:00")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let cameraToggle = NSButton(checkboxWithTitle: "开启摄像头小窗", target: nil, action: nil)
    private let subtitleToggle = NSButton(checkboxWithTitle: "开启字幕", target: nil, action: nil)

    private var pipView: DraggablePiPView?
    private var aspect = AspectSettings()
    private var pipTrack: [PiPKeyframe] = []
    private var subtitleTrack: [SubtitleSegment] = []
    private var recordStartTime: Date?
    private var durationTimer: Timer?
    private var subtitleSessionActive = false
    private var isSubtitleEnabled = false
    private var isSpeechRecognitionAvailable = false
    private var isSpeechRunning = false
    private var isSpeechCallbacksConfigured = false
    private var pendingFinish: (main: URL?, pip: URL?)?

    init(target: ScreenCaptureTarget) {
        self.target = target
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
        recordPiPKeyframeIfNeeded()
    }

    deinit {
        durationTimer?.invalidate()
        source.stopRunning()
    }

    private func setupUI() {
        previewContainer.wantsLayer = true
        previewContainer.layer?.backgroundColor = NSColor.black.cgColor
        view.addSubview(previewContainer)

        previewContainer.addSubview(screenPreview)

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

        let toolbarStack = NSStackView(views: [closeButton, targetLabel, cameraToggle, subtitleToggle, durationLabel, spacer, statusLabel, recordButton])
        toolbarStack.orientation = .horizontal
        toolbarStack.alignment = .centerY
        toolbarStack.spacing = 14
        toolbar.addSubview(toolbarStack)

        subtitleLabel.font = .systemFont(ofSize: 23, weight: .semibold)
        subtitleLabel.textColor = .white
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.wantsLayer = true
        subtitleLabel.layer?.shadowColor = NSColor.black.cgColor
        subtitleLabel.layer?.shadowOpacity = 0.55
        subtitleLabel.layer?.shadowRadius = 8
        subtitleLabel.layer?.shadowOffset = CGSize(width: 0, height: -2)
        subtitleLabel.isHidden = true
        view.addSubview(subtitleLabel)

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

        subtitleLabel.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(80)
            make.bottom.equalTo(toolbar.snp.top).offset(-28)
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
        source.onAudioSampleBuffer = { [weak self] sampleBuffer in
            self?.speech.append(sampleBuffer)
        }
        source.onFinishRecording = { [weak self] mainURL, pipURL in
            self?.recordingFinished(mainURL: mainURL, pipURL: pipURL)
        }

        do {
            try source.configure()
        } catch {
            statusLabel.stringValue = "初始化失败：\(error.localizedDescription)"
            return
        }

        source.startRunning()
        recordButton.isEnabled = true
        statusLabel.stringValue = "已就绪：\(target.title)"
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
            startRecording()
        } else {
            stopRecording()
        }
    }

    private func startRecording() {
        pipTrack.removeAll()
        subtitleTrack.removeAll()
        recordStartTime = Date()
        subtitleSessionActive = false
        pendingFinish = nil
        durationLabel.stringValue = "00:00"
        startDurationTimer()
        recordPiPKeyframeIfNeeded()
        startSpeechIfNeeded()
        source.startRecording(includePiP: aspect.isPiPEnabled && pipView != nil)
        recordButton.title = "停止录制"
        statusLabel.stringValue = "正在录制…"
    }

    private func stopRecording() {
        stopDurationTimer()
        stopSpeechIfNeeded()
        recordButton.isEnabled = false
        recordButton.title = "正在整理…"
        statusLabel.stringValue = "正在保存录屏和摄像头小窗…"
        source.stopRecording()
    }

    private func recordingFinished(mainURL: URL?, pipURL: URL?) {
        pendingFinish = (mainURL, pipURL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
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
                                       aspect: aspect,
                                       sourceKind: .screen)
        statusLabel.stringValue = isSubtitleEnabled ? "正在合成字幕到视频文件…" : "正在合成视频文件…"
        exportAndSave(project)
    }

    private func exportAndSave(_ project: RecordingProject) {
        VideoCompositor().export(project: project) { [weak self] result in
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
                self.statusLabel.stringValue = "字幕合成失败，正在保存原始录制…"
                self.saveFinishedProject(project, cleanupURLs: [project.mainVideoURL, project.pipVideoURL], warning: error)
            }
        }
    }

    private func saveFinishedProject(_ project: RecordingProject,
                                     cleanupURLs: [URL?],
                                     warning: Error? = nil) {
        do {
            let saved = try DraftStore.shared.save(project)
            cleanupURLs.forEach { url in
                guard let url,
                      url.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL else { return }
                try? FileManager.default.removeItem(at: url)
            }
            recordStartTime = nil
            recordButton.isEnabled = true
            recordButton.title = "开始录制"
            if let warning {
                statusLabel.stringValue = "已保存原始录制，字幕合成失败：\(warning.localizedDescription)"
            } else {
                statusLabel.stringValue = "录制完成，已保存草稿"
            }
            onFinish?(saved)
        } catch {
            recordStartTime = nil
            recordButton.isEnabled = true
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

    @objc private func subtitleToggleChanged() {
        if subtitleToggle.state == .on {
            requestSubtitlePermissionsAndEnable()
        } else {
            disableSubtitles()
        }
    }

    private func requestCameraAndEnablePiP() {
        cameraToggle.isEnabled = false
        statusLabel.stringValue = "正在请求摄像头权限…"
        MacPermissionManager.requestCamera { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.cameraToggle.isEnabled = true
                self.cameraToggle.state = .off
                self.aspect.isPiPEnabled = false
                self.statusLabel.stringValue = "需要摄像头权限才能打开小窗"
                MacPermissionAlert.show(kind: .camera, in: self.view.window)
                return
            }
            self.source.enableCamera { [weak self] result in
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
                    self.statusLabel.stringValue = "无法开启摄像头：\(error.localizedDescription)"
                }
            }
        }
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
                        self.subtitleLabel.isHidden = false
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
        subtitleLabel.isHidden = true
        subtitleLabel.stringValue = ""
        stopSpeechIfNeeded()
        source.disableMicrophone()
    }

    private func configureSpeechCallbacksIfNeeded() {
        guard !isSpeechCallbacksConfigured else { return }
        isSpeechCallbacksConfigured = true
        speech.onText = { [weak self] text, isFinal in
            guard let self else { return }
            if self.isSubtitleEnabled {
                self.subtitleLabel.stringValue = text
            }
            if isFinal {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if self.subtitleLabel.stringValue == text {
                        self.subtitleLabel.stringValue = ""
                    }
                }
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
            statusLabel.stringValue = "已配置"
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
