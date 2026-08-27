import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// macOS 屏幕采集流当前实际输出的格式状态。
struct MacScreenCaptureStatus: Equatable {
    /// 屏幕采集流实际输出的视频宽度。
    let actualWidth: Int
    /// 屏幕采集流实际输出的视频高度。
    let actualHeight: Int
    /// 当前参数允许的最大输出宽度。
    let requestedWidth: Int
    /// 当前参数允许的最大输出高度。
    let requestedHeight: Int
    /// 用户选择的录制参数。
    let settings: MacRecordingSettings
    /// 当前是否录制整个显示器，而不是独立应用窗口。
    let isDisplayCapture: Bool
    /// 根据样本时间戳计算出的实际帧率。
    let measuredFrameRate: Double?

    /// 当前源画面是否低于用户选择的目标尺寸。
    var sourceIsBelowRequestedSize: Bool {
        max(actualWidth, actualHeight) < max(requestedWidth, requestedHeight)
    }

    /// 返回适合显示在录制页状态栏中的格式信息。
    var displayText: String {
        var text = "实际采样：\(actualWidth)×\(actualHeight) · 目标：\(settings.resolution.displayName) / \(settings.frameRate.displayName)"
        if let measuredFrameRate {
            text += " · 实际约\(Int(measuredFrameRate.rounded()))fps"
        }
        if sourceIsBelowRequestedSize {
            let sourceName = isDisplayCapture ? "屏幕源像素不足" : "窗口源像素不足"
            text += "（\(sourceName)，按实际像素录制）"
        }
        return text
    }
}

final class ScreenCameraSource: NSObject {
    enum SourceError: Error, LocalizedError {
        case unsupported
        case missingTarget
        case noCamera
        case noMicrophone
        case cannotConfigureCamera
        case cannotConfigureMicrophone
        case cannotAddScreenOutput(String)
        case cannotAddSystemAudioOutput(String)
        case cannotUpdateSettings(String)

        var errorDescription: String? {
            switch self {
            case .unsupported: return "macOS 12.3 及以上才支持 ScreenCaptureKit 录屏"
            case .missingTarget: return "请先选择要录制的桌面或应用窗口"
            case .noCamera: return "无法获取电脑摄像头"
            case .noMicrophone: return "无法获取麦克风"
            case .cannotConfigureCamera: return "无法配置摄像头"
            case .cannotConfigureMicrophone: return "无法配置麦克风"
            case .cannotAddScreenOutput(let message): return message
            case .cannotAddSystemAudioOutput(let message): return message
            case .cannotUpdateSettings(let message): return message
            }
        }
    }

    var onStateChange: ((CaptureState) -> Void)?
    var onScreenSampleBuffer: ((CMSampleBuffer) -> Void)?
    /// 屏幕采集流首次拿到样本或实测帧率更新时回调格式状态。
    var onScreenCaptureStatusChange: ((MacScreenCaptureStatus) -> Void)?
    /// 默认输入设备输出麦克风样本时回调，专门供语音识别使用。
    var onMicrophoneSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onFinishRecording: ((_ mainURL: URL?, _ pipURL: URL?) -> Void)?

    private(set) var state: CaptureState = .idle {
        didSet { DispatchQueue.main.async { self.onStateChange?(self.state) } }
    }

    private let target: ScreenCaptureTarget
    private let screenQueue = DispatchQueue(label: "com.pinbo.mac.screen-stream")
    /// 电脑声音样本使用的独立处理队列。
    private let systemAudioQueue = DispatchQueue(label: "com.pinbo.mac.system-audio")
    private let cameraQueue = DispatchQueue(label: "com.pinbo.mac.camera-session")
    private let cameraDataQueue = DispatchQueue(label: "com.pinbo.mac.camera-data")
    private let microphoneQueue = DispatchQueue(label: "com.pinbo.mac.microphone-data")
    /// 当前录制输出使用的分辨率和帧速率。
    private var recordingSettings = MacRecordingSettings.default
    /// 当前样本窗口的起始时间。
    private var screenSampleWindowStart: CMTime?
    /// 当前样本窗口已经收到的帧数。
    private var screenSampleCount = 0
    /// 最近一次向页面报告的实际像素尺寸。
    private var lastReportedScreenSize = CGSize.zero
    /// 最近一次向页面报告的实测帧率。
    private var lastReportedFrameRate: Double?

    private var screenStream: SCStream?
    private var screenConfiguration: SCStreamConfiguration?
    private var screenWriter: SampleBufferMovieWriter?
    private var cameraWriter: SampleBufferMovieWriter?

    private let cameraSession = AVCaptureSession()
    private let cameraVideoOutput = AVCaptureVideoDataOutput()
    private let microphoneOutput = AVCaptureAudioDataOutput()
    private var cameraInput: AVCaptureDeviceInput?
    private var microphoneInput: AVCaptureDeviceInput?
    private var cameraPreviewLayer: AVCaptureVideoPreviewLayer?
    private var isCameraConfigured = false
    private var isMicrophoneConfigured = false

    private var mainOutputURL: URL?
    private var pipOutputURL: URL?
    private var isRecording = false
    private var pendingFinishCount = 0
    private var shouldRecordPiP = true

    init(target: ScreenCaptureTarget) {
        self.target = target
        super.init()
    }

    /// 使用指定参数创建屏幕采集流。
    func configure(settings: MacRecordingSettings = .default) throws {
        guard #available(macOS 12.3, *) else { throw SourceError.unsupported }
        recordingSettings = settings
        try configureScreenStream()
        state = .configured
    }

    /// 在非录制状态下重新应用录制参数，并恢复屏幕预览流。
    func updateSettings(_ settings: MacRecordingSettings,
                        completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isRecording else {
            completion(.failure(SourceError.cannotUpdateSettings("录制过程中不能修改录制参数")))
            return
        }

        recordingSettings = settings
        let group = DispatchGroup()
        let lock = NSLock()
        var firstError: Error?

        /// 记录并保留并发配置过程中的第一个错误。
        func record(error: Error?) {
            guard let error else { return }
            lock.lock()
            if firstError == nil {
                firstError = error
            }
            lock.unlock()
        }

        group.enter()
        screenQueue.async {
            self.reconfigureScreenStream { error in
                record(error: error)
                group.leave()
            }
        }

        group.enter()
        cameraQueue.async {
            defer { group.leave() }
            guard self.isCameraConfigured else { return }
            do {
                try self.configureCameraFormat(for: settings)
            } catch {
                record(error: error)
            }
        }

        group.notify(queue: .main) {
            if let firstError {
                completion(.failure(firstError))
            } else {
                completion(.success(()))
            }
        }
    }

    func enableCamera(completion: @escaping (Result<AVCaptureVideoPreviewLayer, Error>) -> Void) {
        cameraQueue.async {
            do {
                try self.configureCameraIfNeeded()
                self.startCaptureSessionIfNeeded()
                guard let previewLayer = self.cameraPreviewLayer else { throw SourceError.cannotConfigureCamera }
                DispatchQueue.main.async { completion(.success(previewLayer)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func disableCamera() {
        cameraQueue.async {
            self.cameraSession.beginConfiguration()
            self.removeCameraConfigurationFromSession()
            self.cameraSession.commitConfiguration()
            self.stopCaptureSessionIfIdle()
        }
    }

    func enableMicrophone(completion: @escaping (Result<Void, Error>) -> Void) {
        cameraQueue.async {
            do {
                try self.configureMicrophoneIfNeeded()
                self.startCaptureSessionIfNeeded()
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func disableMicrophone() {
        cameraQueue.async {
            self.cameraSession.beginConfiguration()
            self.removeMicrophoneConfigurationFromSession()
            self.cameraSession.commitConfiguration()
            self.stopCaptureSessionIfIdle()
        }
    }

    func startRunning() {
        guard let stream = screenStream else { return }
        stream.startCapture { [weak self] error in
            if let error {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    func stopRunning() {
        cameraQueue.async {
            if self.cameraSession.isRunning {
                self.cameraSession.stopRunning()
            }
        }
        screenStream?.stopCapture(completionHandler: nil)
    }

    func startRecording(includePiP: Bool) {
        guard !isRecording else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let dir = FileManager.default.temporaryDirectory
        let mainURL = dir.appendingPathComponent("pinbo_screen_\(stamp).mov")
        let pipURL = dir.appendingPathComponent("pinbo_camera_\(stamp).mov")
        mainOutputURL = mainURL
        pipOutputURL = includePiP ? pipURL : nil
        var audioSources: Set<SampleBufferMovieWriter.AudioSource> = [.system]
        if isMicrophoneConfigured {
            audioSources.insert(.microphone)
        }
        screenWriter = SampleBufferMovieWriter(outputURL: mainURL,
                                               audioSources: audioSources,
                                               frameRate: recordingSettings.frameRate)
        cameraWriter = includePiP
            ? SampleBufferMovieWriter(outputURL: pipURL, frameRate: recordingSettings.frameRate)
            : nil
        shouldRecordPiP = includePiP
        pendingFinishCount = includePiP ? 2 : 1
        isRecording = true
        state = .recording
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        let mainWriter = screenWriter
        let pipWriter = cameraWriter
        screenWriter = nil
        cameraWriter = nil

        mainWriter?.finish { [weak self] _ in
            self?.finishOneRecordingOutput()
        }
        if shouldRecordPiP {
            pipWriter?.finish { [weak self] _ in
                self?.finishOneRecordingOutput()
            }
        }
    }

    private func finishOneRecordingOutput() {
        pendingFinishCount -= 1
        if pendingFinishCount <= 0 {
            state = .stopped
            onFinishRecording?(mainOutputURL, shouldRecordPiP ? pipOutputURL : nil)
        }
    }

    private func configureScreenStream() throws {
        let filter = target.makeFilter(excluding: currentProcessWindows())
        let config = SCStreamConfiguration()
        let sourceSize = target.pixelSize
        let outputSize = recordingSettings.outputDimensions(sourceWidth: Int(sourceSize.width.rounded()),
                                                             sourceHeight: Int(sourceSize.height.rounded()))
        config.width = outputSize.width
        config.height = outputSize.height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = recordingSettings.frameRate.frameDuration
        config.queueDepth = 5
        config.showsCursor = true
        // 低分辨率窗口不能通过放大变成真正的 1080p 或 4K，避免预览和成品先天变糊。
        config.scalesToFit = false
        if #available(macOS 13.0, *) {
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
        }
        if #available(macOS 14.0, *) {
            config.preservesAspectRatio = true
            config.captureResolution = .best
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        } catch {
            throw SourceError.cannotAddScreenOutput(error.localizedDescription)
        }
        if #available(macOS 13.0, *) {
            do {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemAudioQueue)
            } catch {
                throw SourceError.cannotAddSystemAudioOutput("无法采集电脑声音：\(error.localizedDescription)")
            }
        }
        screenStream = stream
        screenConfiguration = config
        resetScreenCaptureStatus()
    }

    /// 配置摄像头输入、视频输出和预览图层，失败时完整回滚本次配置。
    private func configureCameraIfNeeded() throws {
        guard !isCameraConfigured else { return }
        cameraSession.beginConfiguration()
        do {
            removeCameraConfigurationFromSession()
            if cameraSession.canSetSessionPreset(.high) {
                cameraSession.sessionPreset = .high
            }

            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                ?? AVCaptureDevice.default(for: .video) else {
                throw SourceError.noCamera
            }
            let cameraInput = try AVCaptureDeviceInput(device: camera)
            guard cameraSession.canAddInput(cameraInput) else { throw SourceError.cannotConfigureCamera }
            cameraSession.addInput(cameraInput)
            self.cameraInput = cameraInput
            try configureCameraFormat(for: recordingSettings, device: camera)

            cameraVideoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            cameraVideoOutput.alwaysDiscardsLateVideoFrames = true
            cameraVideoOutput.setSampleBufferDelegate(self, queue: cameraDataQueue)
            guard cameraSession.canAddOutput(cameraVideoOutput) else { throw SourceError.cannotConfigureCamera }
            cameraSession.addOutput(cameraVideoOutput)
            if let connection = cameraVideoOutput.connection(with: .video), connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }

            let preview = AVCaptureVideoPreviewLayer(session: cameraSession)
            preview.videoGravity = .resizeAspectFill
            if let connection = preview.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
            cameraPreviewLayer = preview
            isCameraConfigured = true
            cameraSession.commitConfiguration()
        } catch {
            removeCameraConfigurationFromSession()
            cameraSession.commitConfiguration()
            throw error
        }
    }

    /// 选择最接近目标清晰度的摄像头格式，并将帧率降级到该格式实际支持的范围。
    private func configureCameraFormat(for settings: MacRecordingSettings,
                                       device: AVCaptureDevice? = nil) throws {
        guard let camera = device ?? cameraInput?.device else { return }
        let targetLongEdge = settings.maximumLongEdge
        let targetFrameRate = Double(settings.frameRate.rawValue)
        let candidates = camera.formats.compactMap { format -> (format: AVCaptureDevice.Format,
                                                                 longEdge: Int,
                                                                 pixelCount: Int,
                                                                 frameRate: Double,
                                                                 resolutionDistance: Int,
                                                                 frameRateDistance: Double)? in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let longEdge = max(Int(dimensions.width), Int(dimensions.height))
            let pixelCount = Int(dimensions.width) * Int(dimensions.height)
            guard longEdge > 0,
                  pixelCount > 0,
                  let frameRate = nearestSupportedFrameRate(for: format,
                                                            targetFrameRate: targetFrameRate) else { return nil }
            return (format: format,
                    longEdge: longEdge,
                    pixelCount: pixelCount,
                    frameRate: frameRate,
                    resolutionDistance: abs(longEdge - targetLongEdge),
                    frameRateDistance: abs(frameRate - targetFrameRate))
        }
        let preferredCandidates = candidates.filter { $0.longEdge >= targetLongEdge }
        let candidatesToUse = preferredCandidates.isEmpty ? candidates : preferredCandidates
        let selected = candidatesToUse.min { lhs, rhs in
            if lhs.resolutionDistance != rhs.resolutionDistance {
                return lhs.resolutionDistance < rhs.resolutionDistance
            }
            if lhs.pixelCount != rhs.pixelCount {
                return abs(lhs.pixelCount - settings.resolution.width * settings.resolution.height)
                    < abs(rhs.pixelCount - settings.resolution.width * settings.resolution.height)
            }
            if lhs.frameRateDistance != rhs.frameRateDistance {
                return lhs.frameRateDistance < rhs.frameRateDistance
            }
            return lhs.frameRate > rhs.frameRate
        }

        guard let selected else {
            throw SourceError.cannotConfigureCamera
        }
        try camera.lockForConfiguration()
        defer { camera.unlockForConfiguration() }
        camera.activeFormat = selected.format
        let frameDuration = CMTime(seconds: 1 / selected.frameRate,
                                   preferredTimescale: 60_000)
        camera.activeVideoMinFrameDuration = frameDuration
        camera.activeVideoMaxFrameDuration = frameDuration
    }

    /// 计算指定摄像头格式最接近目标值且实际可用的帧率。
    private func nearestSupportedFrameRate(for format: AVCaptureDevice.Format,
                                           targetFrameRate: Double) -> Double? {
        format.videoSupportedFrameRateRanges
            .compactMap { range -> Double? in
                guard range.minFrameRate.isFinite,
                      range.maxFrameRate.isFinite,
                      range.maxFrameRate > 0 else { return nil }
                let minimumFrameRate = max(0.1, range.minFrameRate)
                return min(max(targetFrameRate, minimumFrameRate), range.maxFrameRate)
            }
            .min { lhs, rhs in
                let lhsDistance = abs(lhs - targetFrameRate)
                let rhsDistance = abs(rhs - targetFrameRate)
                if lhsDistance != rhsDistance {
                    return lhsDistance < rhsDistance
                }
                let lhsDoesNotExceedTarget = lhs <= targetFrameRate
                let rhsDoesNotExceedTarget = rhs <= targetFrameRate
                if lhsDoesNotExceedTarget != rhsDoesNotExceedTarget {
                    return lhsDoesNotExceedTarget
                }
                return lhs > rhs
            }
    }

    /// 从采集会话移除摄像头相关输入输出，并清空配置状态。
    private func removeCameraConfigurationFromSession() {
        cameraVideoOutput.setSampleBufferDelegate(nil, queue: nil)
        if cameraSession.outputs.contains(where: { $0 === cameraVideoOutput }) {
            cameraSession.removeOutput(cameraVideoOutput)
        }
        if let cameraInput,
           cameraSession.inputs.contains(where: { $0 === cameraInput }) {
            cameraSession.removeInput(cameraInput)
        }
        cameraInput = nil
        cameraPreviewLayer = nil
        isCameraConfigured = false
    }

    /// 停止旧屏幕流、按新参数创建屏幕流并恢复预览。
    private func reconfigureScreenStream(completion: @escaping (Error?) -> Void) {
        let oldStream = screenStream
        screenStream = nil
        screenConfiguration = nil

        let createAndStart: () -> Void = { [weak self] in
            guard let self else { return }
            do {
                try self.configureScreenStream()
                guard let stream = self.screenStream else {
                    throw SourceError.cannotUpdateSettings("无法创建新的录屏预览流")
                }
                stream.startCapture { [weak self] error in
                    if let error {
                        self?.state = .failed(error.localizedDescription)
                    }
                    completion(error)
                }
            } catch {
                self.state = .failed(error.localizedDescription)
                completion(error)
            }
        }

        guard let oldStream else {
            createAndStart()
            return
        }
        oldStream.stopCapture { [weak self] _ in
            self?.screenQueue.async {
                createAndStart()
            }
        }
    }

    /// 跟随 macOS 当前默认输入设备配置麦克风，外接设备变化后会自动切换。
    private func configureMicrophoneIfNeeded() throws {
        guard let microphone = AVCaptureDevice.default(for: .audio) else { throw SourceError.noMicrophone }
        if isMicrophoneConfigured,
           microphoneInput?.device.uniqueID == microphone.uniqueID {
            return
        }
        cameraSession.beginConfiguration()
        do {
            removeMicrophoneConfigurationFromSession()
            let microphoneInput = try AVCaptureDeviceInput(device: microphone)
            guard cameraSession.canAddInput(microphoneInput) else { throw SourceError.cannotConfigureMicrophone }
            cameraSession.addInput(microphoneInput)
            self.microphoneInput = microphoneInput

            guard cameraSession.canAddOutput(microphoneOutput) else { throw SourceError.cannotConfigureMicrophone }
            cameraSession.addOutput(microphoneOutput)
            microphoneOutput.setSampleBufferDelegate(self, queue: microphoneQueue)
            isMicrophoneConfigured = true
            cameraSession.commitConfiguration()
        } catch {
            removeMicrophoneConfigurationFromSession()
            cameraSession.commitConfiguration()
            throw error
        }
    }

    /// 从采集会话移除默认输入设备相关配置，并保留摄像头配置不变。
    private func removeMicrophoneConfigurationFromSession() {
        microphoneOutput.setSampleBufferDelegate(nil, queue: nil)
        if cameraSession.outputs.contains(where: { $0 === microphoneOutput }) {
            cameraSession.removeOutput(microphoneOutput)
        }
        if let microphoneInput,
           cameraSession.inputs.contains(where: { $0 === microphoneInput }) {
            cameraSession.removeInput(microphoneInput)
        }
        microphoneInput = nil
        isMicrophoneConfigured = false
    }

    private func startCaptureSessionIfNeeded() {
        guard isCameraConfigured || isMicrophoneConfigured else { return }
        if !cameraSession.isRunning {
            cameraSession.startRunning()
        }
    }

    private func stopCaptureSessionIfIdle() {
        guard !isCameraConfigured, !isMicrophoneConfigured, cameraSession.isRunning else { return }
        cameraSession.stopRunning()
    }

    private func isCompleteScreenFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw) else {
            return true
        }
        return status == .complete || status == .started
    }

    /// 清空屏幕采集格式统计，等待新采集流的首帧重新确认实际尺寸。
    private func resetScreenCaptureStatus() {
        screenSampleWindowStart = nil
        screenSampleCount = 0
        lastReportedScreenSize = .zero
        lastReportedFrameRate = nil
    }

    /// 根据真实样本缓冲区报告采集尺寸和实测帧率。
    private func updateScreenCaptureStatus(with sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let actualSize = CGSize(width: max(1, Int(dimensions.width)),
                                height: max(1, Int(dimensions.height)))
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard timestamp.isValid else { return }

        if actualSize != lastReportedScreenSize {
            lastReportedScreenSize = actualSize
            publishScreenCaptureStatus(actualSize: actualSize,
                                       measuredFrameRate: lastReportedFrameRate)
        }

        if screenSampleWindowStart == nil {
            screenSampleWindowStart = timestamp
            screenSampleCount = 1
            return
        }

        screenSampleCount += 1
        let elapsed = timestamp.seconds - (screenSampleWindowStart?.seconds ?? timestamp.seconds)
        guard elapsed >= 1 else { return }

        let measuredFrameRate = Double(max(0, screenSampleCount - 1)) / elapsed
        screenSampleWindowStart = timestamp
        screenSampleCount = 1
        guard lastReportedFrameRate == nil
                || abs((lastReportedFrameRate ?? 0) - measuredFrameRate) >= 1 else { return }
        lastReportedFrameRate = measuredFrameRate
        publishScreenCaptureStatus(actualSize: actualSize,
                                   measuredFrameRate: measuredFrameRate)
    }

    /// 将采集状态切换回主线程，供录制页更新状态栏。
    private func publishScreenCaptureStatus(actualSize: CGSize,
                                            measuredFrameRate: Double?) {
        let status = MacScreenCaptureStatus(actualWidth: Int(actualSize.width),
                                            actualHeight: Int(actualSize.height),
                                            requestedWidth: recordingSettings.resolution.width,
                                            requestedHeight: recordingSettings.resolution.height,
                                            settings: recordingSettings,
                                            isDisplayCapture: target.display != nil,
                                            measuredFrameRate: measuredFrameRate)
        DispatchQueue.main.async { [weak self] in
            self?.onScreenCaptureStatusChange?(status)
        }
    }

    private func currentProcessWindows() -> [SCWindow] {
        let semaphore = DispatchSemaphore(value: 0)
        let currentPID = ProcessInfo.processInfo.processIdentifier
        var windows: [SCWindow] = []
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, _ in
            windows = content?.windows.filter { window in
                window.owningApplication?.processID == currentPID
            } ?? []
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
        return windows
    }
}

extension ScreenCameraSource: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            guard isCompleteScreenFrame(sampleBuffer) else { return }
            updateScreenCaptureStatus(with: sampleBuffer)
            onScreenSampleBuffer?(sampleBuffer)
            if isRecording {
                screenWriter?.appendVideo(sampleBuffer)
            }
        case .audio:
            if isRecording {
                screenWriter?.appendAudio(sampleBuffer, source: .system)
            }
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        state = .failed(error.localizedDescription)
    }
}

extension ScreenCameraSource: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === cameraVideoOutput {
            if isRecording {
                cameraWriter?.appendVideo(sampleBuffer)
            }
        } else if output === microphoneOutput {
            onMicrophoneSampleBuffer?(sampleBuffer)
            if isRecording {
                screenWriter?.appendAudio(sampleBuffer, source: .microphone)
            }
        }
    }
}
