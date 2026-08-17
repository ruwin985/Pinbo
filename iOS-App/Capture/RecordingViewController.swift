import UIKit
import AVFoundation
import SnapKit

/// Demo 录制页：后摄全屏 + 前摄可拖拽画中画 + 实时字幕 + 录制。
final class RecordingViewController: UIViewController {

    private let source = DualCameraSource()
    private let speech = LiveSpeechRecognizer(language: .chinese)

    private var pipView: PiPPreviewView?

    private let subtitleLabel = UILabel()
    private let recordButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    private var pipTrack: [PiPKeyframe] = []
    private var subtitleTrack: [SubtitleSegment] = []
    private var recordStartTime: Date?
    /// 录制会话期间为 true，用于收集停止后才到达的最后一段字幕。
    private var subtitleSessionActive = false
    private var pendingFinish: (main: URL?, pip: URL?)?

    // 拍摄设置
    private var aspect = AspectSettings()
    private var mainPreviewContainer: PreviewLayerView?
    private let mainAspectMask = CAShapeLayer()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        requestPermissionsAndStart()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        // 从编辑页返回后恢复预览
        if source.state == .stopped || source.state == .configured {
            source.startRunning()
            recordButton.setTitle("开始录制", for: .normal)
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
        recordButton.setTitle("开始录制", for: .normal)
        recordButton.setTitleColor(.white, for: .normal)
        recordButton.titleLabel?.font = .systemFont(ofSize: 18, weight: .bold)
        recordButton.backgroundColor = .systemRed
        recordButton.layer.cornerRadius = 28
        recordButton.addTarget(self, action: #selector(toggleRecording), for: .touchUpInside)
        view.addSubview(recordButton)

        // 状态
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textAlignment = .left
        statusLabel.numberOfLines = 3
        view.addSubview(statusLabel)

        // 关闭（返回首页）
        closeButton.setImage(UIImage(named: "nav_back"), for: .normal)
        closeButton.tintColor = .white
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        // 右侧功能按钮列：比例
        let aspectBtn = makeSideButton("aspectratio", "比例", #selector(aspectTapped))
        let sideStack = UIStackView(arrangedSubviews: [aspectBtn])
        sideStack.axis = .vertical
        sideStack.spacing = 20
        sideStack.alignment = .center
        view.addSubview(sideStack)

        subtitleLabel.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.bottom.equalTo(recordButton.snp.top).offset(-24)
        }

        recordButton.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalTo(view.safeAreaLayoutGuide).inset(24)
            make.width.equalTo(160)
            make.height.equalTo(56)
        }

        statusLabel.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.centerY.equalTo(closeButton.snp.centerY)
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
        do {
            try source.configure()
        } catch {
            statusLabel.text = "初始化失败：\(error.localizedDescription)"
            return
        }

        // 主画面预览（后摄，全屏）
        if let mainLayer = source.makeMainPreviewLayer() {
            let container = PreviewLayerView(previewLayer: mainLayer)
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

        // 画中画（前摄，默认位于左上角关闭按钮下方）
        if let pipLayer = source.makePiPPreviewLayer() {
            let content = PreviewLayerView(previewLayer: pipLayer)
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
        }

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

        source.startRunning()
        statusLabel.text = "就绪：拖动/双指缩放小窗，点按开始录制"
    }

    // MARK: - Recording

    @objc private func toggleRecording() {
        switch source.state {
        case .recording:
            source.stopRecording()
            speech.stop()
            recordButton.setTitle("开始录制", for: .normal)
        default:
            recordStartTime = Date()
            pipTrack.removeAll()
            subtitleTrack.removeAll()
            subtitleSessionActive = true
            pendingFinish = nil
            recordPiPKeyframe()
            source.startRecording()
            speech.start()
            recordButton.setTitle("停止录制", for: .normal)
        }
    }

    private func recordPiPKeyframe() {
        guard let pip = pipView else { return }
        let layout = pip.normalizedLayout(in: view)
        let t = recordStartTime.map { Date().timeIntervalSince($0) } ?? 0
        pipTrack.append(PiPKeyframe(time: t,
                                    center: layout.center,
                                    size: layout.size,
                                    cornerRadius: layout.cornerRadius))
    }

    // MARK: - Settings sheets

    @objc private func closeTapped() {
        navigationController?.popToRootViewController(animated: true)
    }

    @objc private func aspectTapped() {
        let sheet = AspectSettingsViewController(settings: aspect)
        sheet.onChange = { [weak self] settings in
            self?.aspect = settings
            self?.applyPiPStyle()
            self?.applyMainAspectMask()
            self?.recordPiPKeyframe()
        }
        presentSheet(sheet)
    }

    /// 用黑边遮罩把主预览裁到所选主比例的取景区（居中）。
    private func applyMainAspectMask() {
        guard let container = mainPreviewContainer else { return }
        let bounds = container.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        mainAspectMask.frame = bounds
        guard !aspect.main.isDefault else {
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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyMainAspectMask()
    }
}

// MARK: - CaptureSourceDelegate

extension RecordingViewController: CaptureSourceDelegate {
    func captureSource(_ source: CaptureSourceProviding, didChange state: CaptureState) {
        switch state {
        case .recording: statusLabel.text = "● 录制中…"
        case .stopped: statusLabel.text = "录制完成"
        case .failed(let msg): statusLabel.text = "错误：\(msg)"
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
            pipVideoURL: pending.pip,
            duration: duration,
            pipTrack: pipTrack,
            subtitleTrack: subtitleTrack.sorted { $0.startTime < $1.startTime },
            aspect: aspect
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
