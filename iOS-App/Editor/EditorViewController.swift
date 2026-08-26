import UIKit
import AVFoundation
import SnapKit

/// 视频编辑页（剪辑 App 风格）：
/// - 顶部：取消 / 保存
/// - 中部：视频预览 + 实时字幕叠加
/// - 播放控制行：时间 / 居中播放 / 全屏
/// - 时间轴：轨道从屏幕中线开始，播放头固定中线，支持左右拖拽裁剪
final class EditorViewController: UIViewController {

    private var project: RecordingProject
    private let compositor = VideoCompositor()

    // 预览
    private let previewContainer = UIView()
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var previewRenderSize: CGSize?
    private var timeObserver: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private let subtitleOverlay = UILabel()
    private let screenCaptureOverlay = UIView()

    // 顶部
    private let topBar = UIStackView()
    private let cancelButton = UIButton(type: .custom)
    private let saveButton = UIButton(type: .system)
    private let subtitleHintLabel = UILabel()

    // 播放控制
    private let controlRow = UIView()
    private let timeLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private let fullscreenButton = UIButton(type: .system)

    // 轨道
    private let timeline = TimelineView()

    private let activity = UIActivityIndicatorView(style: .large)
    private var trimStart: TimeInterval = 0
    private var trimEnd: TimeInterval
    private var mediaDuration: TimeInterval
    private var isFullscreen = false
    private var shouldPlayWhenReady = false
    private var areSubtitlesVisible = true
    private var currentSubtitleSegmentID: UUID?
    private var subtitlePanStartCenter: CGPoint = .zero
    private var subtitlePinchStartScale: CGFloat = 1
    private var subtitlePinchStartWidth: CGFloat = 0.86
    /// 标记保存导出进行中，用于暂停预览和缩略图缓存回填以降低内存峰值。
    private var isExportingForSave = false

    init(project: RecordingProject) {
        var normalizedProject = project
        normalizedProject.subtitleTrack = SubtitleSegmenter.normalized(project.subtitleTrack)
        self.project = normalizedProject
        let initialDuration = max(project.duration, 0)
        self.trimEnd = initialDuration
        self.mediaDuration = initialDuration
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        navigationController?.setNavigationBarHidden(true, animated: false)
        setupUI()
        setupPlayer()
        observeScreenCaptureChanges()
        generateThumbnails()
    }

    deinit {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateScreenCaptureOverlayVisibility()
    }

    override var prefersStatusBarHidden: Bool { isFullscreen }
    override var prefersHomeIndicatorAutoHidden: Bool { isFullscreen }

    // MARK: - UI

    private func setupUI() {
        // 顶部栏
//        cancelButton.setTitle("取消", for: .normal)
//        cancelButton.setTitleColor(.white, for: .normal)
//        cancelButton.titleLabel?.font = .systemFont(ofSize: 17)
        cancelButton.setImage(UIImage(named: "nav_back"), for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        saveButton.setTitle("保存", for: .normal)
        saveButton.setTitleColor(AppTheme.primary, for: .normal)
        saveButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)

        topBar.addArrangedSubview(cancelButton)
        topBar.addArrangedSubview(UIView())
        topBar.addArrangedSubview(saveButton)
        topBar.axis = .horizontal
        topBar.alignment = .center

        subtitleHintLabel.text = "字幕：点按改文字，拖动改位置，双指缩放大小"
        subtitleHintLabel.textColor = UIColor.white.withAlphaComponent(0.68)
        subtitleHintLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleHintLabel.textAlignment = .center

        // 预览
        previewContainer.backgroundColor = .black
        previewContainer.clipsToBounds = true

        subtitleOverlay.textColor = .white
        subtitleOverlay.numberOfLines = 3
        subtitleOverlay.textAlignment = .center
        subtitleOverlay.lineBreakMode = .byTruncatingTail
        subtitleOverlay.shadowColor = .black
        subtitleOverlay.shadowOffset = CGSize(width: 0, height: 1)
        subtitleOverlay.adjustsFontSizeToFitWidth = false
        subtitleOverlay.isUserInteractionEnabled = true
        subtitleOverlay.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleSubtitleTap(_:))))
        subtitleOverlay.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleSubtitlePan(_:))))
        subtitleOverlay.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handleSubtitlePinch(_:))))

        // 播放控制行
        timeLabel.text = "00:00 / 00:00"
        timeLabel.textColor = UIColor(white: 0.8, alpha: 1)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)

        playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        playButton.tintColor = .white
        playButton.addTarget(self, action: #selector(togglePlay), for: .touchUpInside)

        fullscreenButton.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right"), for: .normal)
        fullscreenButton.tintColor = .white
        fullscreenButton.addTarget(self, action: #selector(fullscreenTapped), for: .touchUpInside)

        [timeLabel, playButton, fullscreenButton].forEach {
            controlRow.addSubview($0)
        }
        controlRow.layer.cornerRadius = 18
        controlRow.clipsToBounds = true

        // 时间轴
        timeline.duration = project.duration
        timeline.subtitleSegments = project.subtitleTrack
        timeline.areSubtitlesVisible = areSubtitlesVisible
        timeline.trimStart = trimStart
        timeline.trimEnd = trimEnd
        timeline.onSeek = { [weak self] t in self?.seek(to: t) }
        timeline.onTrimChanged = { [weak self] start, end in
            self?.trimStart = start
            self?.trimEnd = end
            self?.refreshTimeLabel(currentTime: start)
        }
        timeline.onSubtitleTapped = { [weak self] id in
            self?.editSubtitle(id: id)
        }
        timeline.onSubtitleVisibilityToggled = { [weak self] isVisible in
            self?.setSubtitlesVisible(isVisible)
        }

        activity.color = .white
        activity.hidesWhenStopped = true

        setupScreenCaptureOverlay()

        [topBar, subtitleHintLabel, previewContainer, controlRow, timeline, activity].forEach { view.addSubview($0) }
        previewContainer.addSubview(subtitleOverlay)
        view.addSubview(screenCaptureOverlay)

        topBar.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(4)
            make.leading.trailing.equalToSuperview().inset(16)
            make.height.equalTo(40)
        }

        subtitleHintLabel.snp.makeConstraints { make in
            make.top.equalTo(topBar.snp.bottom).offset(2)
            make.leading.trailing.equalToSuperview().inset(16)
            make.height.equalTo(16)
        }

        previewContainer.snp.makeConstraints { make in
            make.top.equalTo(subtitleHintLabel.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview()
            make.bottom.equalTo(controlRow.snp.top).offset(-8)
        }

        controlRow.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.height.equalTo(36)
            make.bottom.equalTo(timeline.snp.top).offset(-6)
        }

        timeLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.centerY.equalToSuperview()
            make.trailing.lessThanOrEqualTo(playButton.snp.leading).offset(-12)
        }

        playButton.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.centerY.equalToSuperview()
            make.size.equalTo(CGSize(width: 44, height: 36))
        }

        fullscreenButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview()
            make.centerY.equalToSuperview()
            make.size.equalTo(CGSize(width: 44, height: 36))
        }

        timeline.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(168)
            make.bottom.equalTo(view.safeAreaLayoutGuide).inset(16)
        }

        activity.snp.makeConstraints { make in
            make.center.equalTo(previewContainer)
        }

        screenCaptureOverlay.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    private func setupScreenCaptureOverlay() {
        screenCaptureOverlay.isHidden = true
        screenCaptureOverlay.backgroundColor = .black
        screenCaptureOverlay.isUserInteractionEnabled = true
        screenCaptureOverlay.accessibilityViewIsModal = true
        screenCaptureOverlay.layer.zPosition = 1_000

        let iconView = UIImageView(image: UIImage(systemName: "video.slash.fill"))
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit

        let titleLabel = UILabel()
        titleLabel.text = "当前页面禁止录屏"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textAlignment = .center

        let messageLabel = UILabel()
        messageLabel.text = "请停止系统录屏后继续播放"
        messageLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        messageLabel.font = .systemFont(ofSize: 15, weight: .regular)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [iconView, titleLabel, messageLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        screenCaptureOverlay.addSubview(stack)

        iconView.snp.makeConstraints { make in
            make.size.equalTo(52)
        }
        stack.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.trailing.equalToSuperview().inset(32)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPlayerLayer()
        layoutSubtitleOverlay()
    }

    // MARK: - Player

    private func setupPlayer() {
        guard project.mainVideoURL != nil else { return }
        // 预览用合成后的画面（含画中画，跟随关键帧移动）；字幕不烧进预览，改用 UI 叠加层，便于即时编辑。
        let item: AVPlayerItem
        do {
            let built = try compositor.build(project: project, includeSubtitles: false)
            previewRenderSize = built.videoComposition.renderSize
            applyMediaDuration(built.composition.duration.seconds)
            item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
        } catch {
            showAlert("预览失败", (error as? VideoCompositor.CompositorError)?.errorDescription ?? error.localizedDescription)
            return
        }
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.frame = previewVideoRect()
        previewContainer.layer.insertSublayer(layer, at: 0)
        self.player = player
        self.playerLayer = layer
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                self?.handleItemStatusChanged(item.status, error: item.error)
            }
        }

        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let t = time.seconds
            if self.trimEnd > self.trimStart, t >= self.trimEnd, player.timeControlStatus == .playing {
                self.pausePlayback()
                self.seek(to: self.trimEnd)
                return
            }
            self.refreshTimeLabel(currentTime: t)
            self.timeline.updatePlayhead(currentTime: t)
            self.updateSubtitleOverlay(at: t)
        }
        seek(to: trimStart)
    }

    /// 卸载编辑预览播放器，释放解码缓存，给导出保存留出内存空间。
    private func unloadPlayerForExport() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        player?.pause()
        playerLayer?.player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        player = nil
        shouldPlayWhenReady = false
        playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        updateSubtitleOverlay(at: trimStart)
    }

    /// 根据当前时间显示对应字幕分段（实时叠加，与轨道一致）。
    private func updateSubtitleOverlay(at t: TimeInterval) {
        guard areSubtitlesVisible else {
            currentSubtitleSegmentID = nil
            subtitleOverlay.text = ""
            subtitleOverlay.isHidden = true
            return
        }
        let seg = project.subtitleTrack.first { t >= $0.startTime && t <= $0.endTime }
        currentSubtitleSegmentID = seg?.id
        subtitleOverlay.text = seg?.text ?? ""
        subtitleOverlay.isHidden = seg == nil || (seg?.text.isEmpty ?? true)
        layoutSubtitleOverlay()
    }

    private func setSubtitlesVisible(_ isVisible: Bool) {
        guard areSubtitlesVisible != isVisible else { return }
        areSubtitlesVisible = isVisible
        timeline.areSubtitlesVisible = isVisible
        updateSubtitleOverlay(at: player?.currentTime().seconds ?? trimStart)
    }

    private func layoutSubtitleOverlay() {
        guard previewContainer.bounds.width > 0, previewContainer.bounds.height > 0 else { return }
        let videoRect = previewVideoRect()
        let inset = subtitleInset(in: videoRect)
        let layout = normalizedSubtitleLayout(project.subtitleLayout)
        let maxWidth = max(80, layout.maxWidth * videoRect.width)
        subtitleOverlay.font = subtitleFont(in: videoRect, scale: layout.fontScale)
        let maxSize = CGSize(width: min(maxWidth, videoRect.width - inset * 2),
                             height: CGFloat.greatestFiniteMagnitude)
        let fitting = subtitleOverlay.sizeThatFits(maxSize)
        let lineHeight = subtitleOverlay.font.lineHeight
        let width = maxSize.width
        let height = min(ceil(lineHeight * 3), max(ceil(lineHeight), ceil(fitting.height)))
        let center = CGPoint(x: videoRect.minX + layout.center.x * videoRect.width,
                             y: videoRect.minY + layout.center.y * videoRect.height)
        subtitleOverlay.frame = constrainedSubtitleFrame(center: center,
                                                         size: CGSize(width: width, height: height),
                                                         in: videoRect)
    }

    private func normalizedSubtitleLayout(_ layout: SubtitleLayout) -> SubtitleLayout {
        SubtitleLayout(center: CGPoint(x: min(max(layout.center.x, 0), 1),
                                       y: min(max(layout.center.y, 0), 1)),
                       maxWidth: min(max(layout.maxWidth, 0.45), 0.94),
                       fontScale: min(max(layout.fontScale, 0.65), 2.2))
    }

    private func subtitleFont(in bounds: CGRect, scale: CGFloat) -> UIFont {
        let baseSize = max(16, min(bounds.width, bounds.height) * 0.06)
        return .systemFont(ofSize: baseSize * scale, weight: .bold)
    }

    private func previewVideoRect() -> CGRect {
        guard previewContainer.bounds.width > 0, previewContainer.bounds.height > 0 else { return previewContainer.bounds }
        let canvas = previewRenderSize ?? project.aspect.main.canvasSize()
        guard canvas.width > 0, canvas.height > 0 else { return previewContainer.bounds }
        let scale = min(previewContainer.bounds.width / canvas.width,
                        previewContainer.bounds.height / canvas.height)
        let size = CGSize(width: canvas.width * scale, height: canvas.height * scale)
        return CGRect(x: (previewContainer.bounds.width - size.width) / 2,
                      y: (previewContainer.bounds.height - size.height) / 2,
                      width: size.width,
                      height: size.height)
    }

    private func layoutPlayerLayer() {
        playerLayer?.frame = previewVideoRect()
    }

    private func subtitleInset(in bounds: CGRect) -> CGFloat {
        max(16, bounds.width * 0.04)
    }

    private func constrainedSubtitleFrame(center: CGPoint, size: CGSize, in bounds: CGRect) -> CGRect {
        let inset = subtitleInset(in: bounds)
        let width = min(size.width, bounds.width - inset * 2)
        let height = min(size.height, bounds.height - inset * 2)
        var origin = CGPoint(x: center.x - width / 2, y: center.y - height / 2)
        origin.x = min(max(origin.x, bounds.minX + inset), bounds.maxX - inset - width)
        origin.y = min(max(origin.y, bounds.minY + inset), bounds.maxY - inset - height)
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    private func updateSubtitleLayout(from frame: CGRect) {
        let videoRect = previewVideoRect()
        guard videoRect.width > 0, videoRect.height > 0 else { return }
        project.subtitleLayout.center = CGPoint(x: (frame.midX - videoRect.minX) / videoRect.width,
                                                y: (frame.midY - videoRect.minY) / videoRect.height)
        project.subtitleLayout.maxWidth = frame.width / videoRect.width
    }

    private func generateThumbnails() {
        guard let mainURL = project.mainVideoURL else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let asset = AVURLAsset(url: mainURL)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 120, height: 120)
            let dur = Self.mediaDuration(for: asset, fallback: self.mediaDuration)
            guard dur > 0 else { return }
            let count = max(Int(dur / 0.8), 1)
            var images: [UIImage] = []
            for i in 0..<count {
                let t = CMTime(seconds: Double(i) * dur / Double(count), preferredTimescale: 600)
                if let cg = try? gen.copyCGImage(at: t, actualTime: nil) {
                    images.append(UIImage(cgImage: cg))
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isExportingForSave else { return }
                self.timeline.videoThumbnails = images
            }
        }
    }

    /// 清理时间轴缩略图，避免保存导出时与视频合成同时占用内存。
    private func unloadTimelineThumbnailsForExport() {
        timeline.videoThumbnails = []
    }

    // MARK: - Playback

    @objc private func togglePlay() {
        if isPlaybackRequested {
            pausePlayback()
        } else {
            playFromCurrentOrTrimStart()
        }
    }

    private var isPlaybackRequested: Bool {
        guard let player else { return false }
        return shouldPlayWhenReady
            || player.rate > 0
            || player.timeControlStatus == .playing
            || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    private func pausePlayback() {
        shouldPlayWhenReady = false
        player?.pause()
        playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        updateScreenCaptureOverlayVisibility()
    }

    private func playFromCurrentOrTrimStart() {
        guard let player else { return }
        guard !isScreenCaptured else {
            updateScreenCaptureOverlayVisibility(forceShow: true)
            return
        }
        guard trimEnd > trimStart else {
            refreshTimeLabel(currentTime: trimStart)
            return
        }
        let current = player.currentTime().seconds
        let shouldSeek = !current.isFinite || current < trimStart || current >= trimEnd
        let startPlayback = { [weak self] in
            guard let self else { return }
            self.startPlaybackIfReady()
        }
        if shouldSeek {
            player.seek(to: CMTime(seconds: trimStart, preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero) { _ in
                DispatchQueue.main.async(execute: startPlayback)
            }
        } else {
            startPlayback()
        }
    }

    @discardableResult
    private func startPlaybackIfReady() -> Bool {
        guard let player else { return false }
        switch player.currentItem?.status {
        case .readyToPlay:
            guard !isScreenCaptured else {
                shouldPlayWhenReady = false
                player.pause()
                playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
                updateScreenCaptureOverlayVisibility(forceShow: true)
                return false
            }
            shouldPlayWhenReady = false
            player.playImmediately(atRate: 1)
            playButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
            updateScreenCaptureOverlayVisibility()
            return true
        case .failed:
            shouldPlayWhenReady = false
            playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
            updateScreenCaptureOverlayVisibility()
            showAlert("播放失败", player.currentItem?.error?.localizedDescription ?? "视频无法播放")
            return false
        default:
            shouldPlayWhenReady = true
            player.play()
            playButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
            updateScreenCaptureOverlayVisibility()
            player.currentItem?.asset.loadValuesAsynchronously(forKeys: ["playable", "duration"]) { [weak self] in
                DispatchQueue.main.async { _ = self?.startPlaybackIfReady() }
            }
            return true
        }
    }

    private func handleItemStatusChanged(_ status: AVPlayerItem.Status, error: Error?) {
        switch status {
        case .readyToPlay:
            applyMediaDuration(player?.currentItem?.duration.seconds ?? mediaDuration)
            if shouldPlayWhenReady { _ = startPlaybackIfReady() }
        case .failed:
            shouldPlayWhenReady = false
            playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
            updateScreenCaptureOverlayVisibility()
            showAlert("播放失败", error?.localizedDescription ?? "视频无法播放")
        default:
            break
        }
    }

    private func seek(to t: TimeInterval) {
        let target = min(max(t, trimStart), trimEnd)
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        refreshTimeLabel(currentTime: target)
        updateSubtitleOverlay(at: target)
    }

    @objc private func handleSubtitleTap(_ gesture: UITapGestureRecognizer) {
        guard areSubtitlesVisible, gesture.state == .ended, let currentSubtitleSegmentID else { return }
        editSubtitle(id: currentSubtitleSegmentID)
    }

    @objc private func handleSubtitlePan(_ gesture: UIPanGestureRecognizer) {
        guard areSubtitlesVisible, !subtitleOverlay.isHidden else { return }
        switch gesture.state {
        case .began:
            subtitlePanStartCenter = subtitleOverlay.center
        case .changed, .ended:
            let translation = gesture.translation(in: previewContainer)
            let center = CGPoint(x: subtitlePanStartCenter.x + translation.x,
                                 y: subtitlePanStartCenter.y + translation.y)
            let frame = constrainedSubtitleFrame(center: center,
                                                 size: subtitleOverlay.bounds.size,
                                                 in: previewVideoRect())
            subtitleOverlay.frame = frame
            updateSubtitleLayout(from: frame)
            if gesture.state == .ended { saveDraftIfNeeded() }
        default:
            break
        }
    }

    @objc private func handleSubtitlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard areSubtitlesVisible, !subtitleOverlay.isHidden else { return }
        switch gesture.state {
        case .began:
            subtitlePinchStartScale = project.subtitleLayout.fontScale
            subtitlePinchStartWidth = project.subtitleLayout.maxWidth
        case .changed, .ended:
            project.subtitleLayout.fontScale = min(max(subtitlePinchStartScale * gesture.scale, 0.65), 2.2)
            project.subtitleLayout.maxWidth = min(max(subtitlePinchStartWidth * gesture.scale, 0.45), 0.94)
            layoutSubtitleOverlay()
            updateSubtitleLayout(from: subtitleOverlay.frame)
            if gesture.state == .ended { saveDraftIfNeeded() }
        default:
            break
        }
    }

    private func editSubtitle(id: UUID) {
        guard areSubtitlesVisible else { return }
        guard let index = project.subtitleTrack.firstIndex(where: { $0.id == id }) else { return }
        pausePlayback()

        let segment = project.subtitleTrack[index]
        seek(to: segment.startTime)

        presentAppTextInput(title: "修改字幕", message: "编辑这一句字幕内容", text: segment.text) { [weak self] input in
            guard let self else { return }
            let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  let latestIndex = self.project.subtitleTrack.firstIndex(where: { $0.id == id }) else { return }
            self.project.subtitleTrack[latestIndex].text = text
            self.timeline.subtitleSegments = self.project.subtitleTrack
            self.updateSubtitleOverlay(at: self.player?.currentTime().seconds ?? segment.startTime)
            self.saveDraftIfNeeded()
        }
    }

    private func saveDraftIfNeeded() {
        guard project.isDraft else { return }
        do {
            project = try DraftStore.shared.save(project)
        } catch {
            showAlert("保存草稿失败", error.localizedDescription)
        }
    }

    @objc private func fullscreenTapped() {
        let enteringFullscreen = !isFullscreen
        setFullscreen(enteringFullscreen, animated: true)
        if enteringFullscreen { playFromCurrentOrTrimStart() }
    }

    private func setFullscreen(_ fullscreen: Bool, animated: Bool) {
        guard isFullscreen != fullscreen else { return }
        isFullscreen = fullscreen

        if fullscreen {
            view.bringSubviewToFront(previewContainer)
            view.bringSubviewToFront(controlRow)
            previewContainer.layer.zPosition = 10
            controlRow.layer.zPosition = 11
        } else {
            topBar.isHidden = false
            subtitleHintLabel.isHidden = false
            controlRow.isHidden = false
            timeline.isHidden = false
        }

        previewContainer.snp.remakeConstraints { make in
            if fullscreen {
                make.top.equalToSuperview()
                make.leading.trailing.equalToSuperview()
                make.bottom.equalTo(controlRow.snp.top)
            } else {
                make.top.equalTo(subtitleHintLabel.snp.bottom).offset(8)
                make.leading.trailing.equalToSuperview()
                make.bottom.equalTo(controlRow.snp.top).offset(-8)
            }
        }

        controlRow.snp.remakeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            if fullscreen {
                make.height.equalTo(48)
                make.bottom.equalTo(view.safeAreaLayoutGuide).inset(12)
            } else {
                make.height.equalTo(36)
                make.bottom.equalTo(timeline.snp.top).offset(-6)
            }
        }
        fullscreenButton.setImage(UIImage(systemName: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"), for: .normal)

        let changes = {
            self.topBar.alpha = fullscreen ? 0 : 1
            self.subtitleHintLabel.alpha = fullscreen ? 0 : 1
            self.controlRow.alpha = 1
            self.controlRow.backgroundColor = fullscreen ? UIColor.black.withAlphaComponent(0.55) : .clear
            self.timeline.alpha = fullscreen ? 0 : 1
            self.view.layoutIfNeeded()
            self.layoutPlayerLayer()
            self.updateScreenCaptureOverlayVisibility()
        }

        let completion: (Bool) -> Void = { _ in
            self.topBar.isHidden = fullscreen
            self.subtitleHintLabel.isHidden = fullscreen
            self.controlRow.isHidden = false
            self.timeline.isHidden = fullscreen
            self.previewContainer.layer.zPosition = fullscreen ? 10 : 0
            self.controlRow.layer.zPosition = fullscreen ? 11 : 0
            if !fullscreen {
                self.view.bringSubviewToFront(self.controlRow)
                self.view.bringSubviewToFront(self.timeline)
                self.view.bringSubviewToFront(self.activity)
            }
            self.layoutPlayerLayer()
        }

        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()

        if animated {
            UIView.animate(withDuration: 0.25,
                           delay: 0,
                           options: [.curveEaseInOut, .beginFromCurrentState],
                           animations: changes,
                           completion: completion)
        } else {
            changes()
            completion(true)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateScreenCaptureOverlayVisibility()
    }

    private func observeScreenCaptureChanges() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(screenCaptureStateChanged),
                                               name: UIScreen.capturedDidChangeNotification,
                                               object: nil)
    }

    @objc private func screenCaptureStateChanged() {
        if isScreenCaptured, isPlaybackRequested {
            pausePlayback()
            updateScreenCaptureOverlayVisibility(forceShow: true)
            return
        }
        updateScreenCaptureOverlayVisibility()
    }

    private func updateScreenCaptureOverlayVisibility(forceShow: Bool = false) {
        let shouldShow = isScreenCaptured && (forceShow || isPlaybackRequested)
        screenCaptureOverlay.isHidden = !shouldShow
        if shouldShow {
            view.bringSubviewToFront(screenCaptureOverlay)
        }
    }

    private var isScreenCaptured: Bool {
        if #available(iOS 17.0, *) {
            return traitCollection.sceneCaptureState == .active
        }
        return UIScreen.main.isCaptured
    }

    // MARK: - Save

    @objc private func saveTapped() {
        presentAppConfirmation(title: "保存视频？",
                               message: "确认后将导出当前编辑结果并保存到系统相册。",
                               confirmTitle: "保存") { [weak self] in
            self?.exportAndSave()
        }
    }

    private func exportAndSave() {
        pausePlayback()
        isExportingForSave = true
        unloadPlayerForExport()
        unloadTimelineThumbnailsForExport()
        activity.startAnimating()
        saveButton.isEnabled = false

        compositor.export(project: project,
                          includeSubtitles: areSubtitlesVisible,
                          trimStart: trimStart,
                          trimEnd: trimEnd) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let url):
                PhotoLibrarySaver.save(videoURL: url) { saveResult in
                    self.activity.stopAnimating()
                    self.saveButton.isEnabled = true
                    switch saveResult {
                    case .success:
                        self.showAlert("已保存", "视频已保存到相册 ✅") { self.goBack() }
                    case .failure(let err):
                        self.restoreEditorAfterFailedExport(title: "保存失败", message: err.localizedDescription)
                    }
                }
            case .failure(let err):
                self.restoreEditorAfterFailedExport(title: "导出失败", message: err.localizedDescription)
            }
        }
    }

    /// 保存导出失败后恢复编辑预览、时间轴缩略图和按钮状态。
    private func restoreEditorAfterFailedExport(title: String, message: String) {
        isExportingForSave = false
        activity.stopAnimating()
        saveButton.isEnabled = true
        setupPlayer()
        generateThumbnails()
        showAlert(title, message)
    }

    @objc private func cancelTapped() {
        pausePlayback()

        // 若已经是草稿（从首页打开），直接返回首页，不再提示。
        if project.isDraft {
            backToHome()
            return
        }

        presentAppDialog(title: "是否保存到草稿？",
                         message: "保存后可在首页继续编辑；不保存将丢弃本次录制。",
                         actions: [
                            AppDialogAction(title: "取消", style: .cancel),
                            AppDialogAction(title: "不保存", style: .destructive) { [weak self] _ in
                                guard let self else { return }
                                AppStorageCleaner.removeTransientRecordingFiles(from: self.project)
                                self.backToHome()
                            },
                            AppDialogAction(title: "保存草稿") { [weak self] _ in
                                guard let self else { return }
                                do {
                                    let originalProject = self.project
                                    let savedProject = try DraftStore.shared.save(self.project)
                                    AppStorageCleaner.removeTransientRecordingFiles(from: originalProject, keeping: savedProject)
                                    self.project = savedProject
                                    self.backToHome()
                                } catch {
                                    self.showAlert("保存草稿失败", error.localizedDescription)
                                }
                            },
                         ])
    }

    /// 返回首页（弹回根视图）。
    private func backToHome() {
        if let nav = navigationController {
            nav.popToRootViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    private func goBack() { backToHome() }

    // MARK: - Helpers

    private func format(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "00:00" }
        let s = Int(t.rounded())
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func refreshTimeLabel(currentTime: TimeInterval) {
        let current = min(max(currentTime, trimStart), trimEnd)
        timeLabel.text = "\(format(current - trimStart)) / \(format(trimEnd - trimStart))"
    }

    private func applyMediaDuration(_ duration: TimeInterval) {
        guard duration.isFinite, duration > 0 else { return }
        mediaDuration = duration
        trimStart = min(max(trimStart, 0), duration)
        if trimEnd <= trimStart || trimEnd > duration {
            trimEnd = duration
        }
        if trimEnd <= trimStart {
            trimStart = 0
            trimEnd = duration
        }
        timeline.duration = duration
        timeline.trimStart = trimStart
        timeline.trimEnd = trimEnd
        refreshTimeLabel(currentTime: trimStart)
    }

    private static func mediaDuration(for asset: AVAsset, fallback: TimeInterval) -> TimeInterval {
        let videoDuration = asset.tracks(withMediaType: .video)
            .map { $0.timeRange.end.seconds }
            .max() ?? 0
        let audioDuration = asset.tracks(withMediaType: .audio)
            .map { $0.timeRange.end.seconds }
            .max() ?? 0
        let candidates: [TimeInterval] = [asset.duration.seconds, videoDuration, audioDuration, fallback]
        return candidates.first { $0.isFinite && $0 > 0 } ?? 0
    }

    private func showAlert(_ title: String, _ message: String, onOK: (() -> Void)? = nil) {
        presentAppMessage(title: title, message: message, onOK: onOK)
    }
}
