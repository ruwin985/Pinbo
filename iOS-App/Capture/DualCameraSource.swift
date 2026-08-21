import Foundation
import AVFoundation
import QuartzCore

/// iOS 双摄采集源：后摄 = 主画面，前摄 = 画中画。
/// 同一组 MultiCam 采样流同时驱动预览和分路写文件，避免录制开始时停掉预览。
final class DualCameraSource: NSObject, CaptureSourceProviding {

    weak var delegate: CaptureSourceDelegate?
    private(set) var state: CaptureState = .idle {
        didSet { let s = state; DispatchQueue.main.async { self.delegate?.captureSource(self, didChange: s) } }
    }

    static var isSupported: Bool { AVCaptureMultiCamSession.isMultiCamSupported }

    private let session = AVCaptureMultiCamSession()
    private let sessionQueue = DispatchQueue(label: "com.pinbo.capture.session")
    private let outputQueue = DispatchQueue(label: "com.pinbo.capture.output")

    private let backVideoOutput = AVCaptureVideoDataOutput()
    private let frontVideoOutput = AVCaptureVideoDataOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()

    private let backPreviewLayer = AVSampleBufferDisplayLayer()
    private let frontPreviewLayer = AVSampleBufferDisplayLayer()

    private var recorder: MultiCamMovieRecorder?
    private var isRecordingPiP = true
    private var hasRegisteredSessionObservers = false

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Configure

    func configure() throws {
        guard Self.isSupported else {
            state = .failed("当前设备不支持多摄（需 A12 芯片及以上）")
            throw err("MultiCam not supported")
        }
        var configureError: Error?
        sessionQueue.sync {
            do {
                try self.configureSessionOnQueue()
            } catch {
                configureError = error
            }
        }
        if let configureError { throw configureError }
    }

    private func configureSessionOnQueue() throws {
        if state == .configured || state == .recording { return }
        registerSessionObserversIfNeeded()

        configurePreviewLayers()
        session.beginConfiguration()
        do {
            try configureCamera(position: .back, output: backVideoOutput)
            try configureCamera(position: .front, output: frontVideoOutput)
            try configureMic()
            session.commitConfiguration()
        } catch {
            session.commitConfiguration()
            throw error
        }

        if #available(iOS 16.0, *), session.hardwareCost > 1 {
            state = .failed("双摄硬件负载过高，请稍后重试")
            throw err("MultiCam hardware cost is too high: \(session.hardwareCost)")
        }
        state = .configured
    }

    private func configurePreviewLayers() {
        backPreviewLayer.videoGravity = .resizeAspectFill
        frontPreviewLayer.videoGravity = .resizeAspectFill
        if #available(iOS 17.0, *) {
            backPreviewLayer.preventsCapture = false
            frontPreviewLayer.preventsCapture = false
        }
    }

    private func configureCamera(position: AVCaptureDevice.Position,
                                 output: AVCaptureVideoDataOutput) throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw err("无法获取摄像头")
        }
        let frameDuration = try configureDeviceForMultiCam(device)
        let input = try AVCaptureDeviceInput(device: device)
        input.videoMinFrameDurationOverride = frameDuration
        guard session.canAddInput(input) else { throw err("无法添加摄像头输入") }
        session.addInputWithNoConnections(input)

        output.alwaysDiscardsLateVideoFrames = false
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(output) else { throw err("无法添加视频输出") }
        session.addOutputWithNoConnections(output)

        guard let port = input.ports(for: .video, sourceDeviceType: device.deviceType,
                                     sourceDevicePosition: position).first else {
            throw err("无法获取视频端口")
        }
        let connection = AVCaptureConnection(inputPorts: [port], output: output)
        guard session.canAddConnection(connection) else { throw err("无法连接视频输出") }
        session.addConnection(connection)
        if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
        if position == .front, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }

    private func configureDeviceForMultiCam(_ device: AVCaptureDevice) throws -> CMTime {
        guard let format = Self.preferredMultiCamFormat(for: device) else {
            throw err("当前摄像头不支持双摄格式")
        }
        let frameDuration = Self.supportsFrameRate(24, format: format)
            ? CMTime(value: 1, timescale: 24)
            : CMTime(value: 1, timescale: 30)
        try device.lockForConfiguration()
        device.activeFormat = format
        device.videoZoomFactor = max(1, device.minAvailableVideoZoomFactor)
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        device.unlockForConfiguration()
        return frameDuration
    }

    private static func preferredMultiCamFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let targetPixelCount = 640 * 480
        let candidates = device.formats.filter { format in
            format.isMultiCamSupported && (supportsFrameRate(24, format: format) || supportsFrameRate(30, format: format))
        }
        return candidates.sorted { lhs, rhs in
            let lhsPixels = pixelCount(for: lhs)
            let rhsPixels = pixelCount(for: rhs)
            let lhsFits = lhsPixels <= targetPixelCount
            let rhsFits = rhsPixels <= targetPixelCount
            if lhsFits != rhsFits { return lhsFits }
            return lhsFits ? lhsPixels > rhsPixels : lhsPixels < rhsPixels
        }.first
    }

    private static func supportsFrameRate(_ frameRate: Double, format: AVCaptureDevice.Format) -> Bool {
        format.videoSupportedFrameRateRanges.contains { range in
            range.minFrameRate <= frameRate && frameRate <= range.maxFrameRate
        }
    }

    private static func pixelCount(for format: AVCaptureDevice.Format) -> Int {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return Int(dimensions.width) * Int(dimensions.height)
    }

    private func configureMic() throws {
        guard let device = AVCaptureDevice.default(for: .audio) else { throw err("无法获取麦克风") }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw err("无法添加音频输入") }
        session.addInputWithNoConnections(input)

        guard let port = input.ports(for: .audio, sourceDeviceType: device.deviceType,
                                     sourceDevicePosition: device.position).first else { return }
        audioDataOutput.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(audioDataOutput) else { throw err("无法添加音频数据输出") }
        session.addOutputWithNoConnections(audioDataOutput)
        let connection = AVCaptureConnection(inputPorts: [port], output: audioDataOutput)
        if session.canAddConnection(connection) { session.addConnection(connection) }
    }

    // MARK: - Preview

    func makeMainPreviewLayer() -> CALayer? { backPreviewLayer }
    func makePiPPreviewLayer() -> CALayer? { frontPreviewLayer }

    // MARK: - Running

    func startRunning() {
        startRunning(completion: nil)
    }

    func startRunning(completion: ((Bool) -> Void)?) {
        sessionQueue.async {
            if !self.session.isRunning {
                self.session.startRunning()
            }
            let isRunning = self.session.isRunning
            if !isRunning {
                self.state = .failed("相机启动失败，请退出后重试")
            }
            DispatchQueue.main.async { completion?(isRunning) }
        }
    }

    func stopRunning() {
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    // MARK: - Recording

    func startRecording() {
        startRecording(includePiP: true)
    }

    func startRecording(includePiP: Bool = true) {
        outputQueue.async {
            guard self.state != .recording else { return }
            let dir = FileManager.default.temporaryDirectory
            let stamp = "\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(8))"
            let mainURL = dir.appendingPathComponent("pinbo_back_\(stamp).mov")
            let pipURL = includePiP ? dir.appendingPathComponent("pinbo_front_\(stamp).mov") : nil
            do {
                self.recorder = try MultiCamMovieRecorder(mainURL: mainURL, pipURL: pipURL)
                self.isRecordingPiP = includePiP
                self.state = .recording
            } catch {
                self.recorder = nil
                self.state = .failed(Self.message(for: error))
            }
        }
    }

    func stopRecording() {
        outputQueue.async {
            guard self.state == .recording, let recorder = self.recorder else { return }
            self.recorder = nil
            recorder.finish { result in
                self.outputQueue.async {
                    switch result {
                    case .success(let output):
                        self.state = .stopped
                        DispatchQueue.main.async {
                            self.delegate?.captureSource(self,
                                                         didFinishRecordingMain: output.main,
                                                         pip: self.isRecordingPiP ? output.pip : nil)
                        }
                    case .failure(let error):
                        self.state = .failed(Self.message(for: error))
                    }
                }
            }
        }
    }

    private func enqueuePreview(_ sampleBuffer: CMSampleBuffer, to layer: AVSampleBufferDisplayLayer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        DispatchQueue.main.async {
            if layer.status == .failed { layer.flush() }
            if layer.isReadyForMoreMediaData {
                layer.enqueue(sampleBuffer)
            }
        }
    }

    private func appendMainVideo(_ sampleBuffer: CMSampleBuffer) {
        guard state == .recording, let recorder else { return }
        do {
            try recorder.appendMainVideo(sampleBuffer)
        } catch {
            self.recorder = nil
            state = .failed(Self.message(for: error))
        }
    }

    private func appendPiPVideo(_ sampleBuffer: CMSampleBuffer) {
        guard state == .recording, let recorder else { return }
        do {
            try recorder.appendPiPVideo(sampleBuffer)
        } catch {
            recorder.disablePiP()
            isRecordingPiP = false
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        if state == .recording, let recorder {
            do {
                try recorder.appendAudio(sampleBuffer)
            } catch {
                self.recorder = nil
                state = .failed(Self.message(for: error))
            }
        }
        delegate?.captureSource(self, didOutput: sampleBuffer)
    }

    private func err(_ m: String) -> NSError {
        NSError(domain: "Pinbo", code: -2, userInfo: [NSLocalizedDescriptionKey: m])
    }

    private static func message(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain || nsError.domain == AVFoundationErrorDomain {
            return "相机录制失败（\(nsError.domain) \(nsError.code)），请重试"
        }
        let message = nsError.localizedDescription
        if message == "The operation could not be completed" || message == "The operation couldn’t be completed" {
            return "相机录制失败（\(nsError.domain) \(nsError.code)），请重试"
        }
        return message
    }

    private func registerSessionObserversIfNeeded() {
        guard !hasRegisteredSessionObservers else { return }
        hasRegisteredSessionObservers = true
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
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
        outputQueue.async {
            self.recorder = nil
            self.state = .failed(error.map { Self.message(for: $0) } ?? "相机运行异常，请退出后重试")
        }
    }

    @objc private func sessionWasInterrupted(_ notification: Notification) {
        outputQueue.async {
            self.recorder = nil
            self.state = .failed("相机被系统中断，请关闭其他占用相机的功能后重试")
        }
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        startRunning()
    }
}

// MARK: - Sample output

extension DualCameraSource: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === backVideoOutput {
            enqueuePreview(sampleBuffer, to: backPreviewLayer)
            appendMainVideo(sampleBuffer)
        } else if output === frontVideoOutput {
            enqueuePreview(sampleBuffer, to: frontPreviewLayer)
            appendPiPVideo(sampleBuffer)
        } else if output === audioDataOutput {
            appendAudio(sampleBuffer)
        }
    }
}

// MARK: - Asset writer

private final class MultiCamMovieRecorder {
    struct Output {
        let main: URL
        let pip: URL?
    }

    fileprivate enum RecorderError: LocalizedError {
        case missingVideoFormat
        case cannotAddVideoInput
        case cannotAddAudioInput
        case cannotStartWriting(String)
        case appendFailed(String)
        case missingMainTrack
        case missingPiPTrack

        var errorDescription: String? {
            switch self {
            case .missingVideoFormat: return "录制失败：无法读取视频格式"
            case .cannotAddVideoInput: return "录制失败：无法添加视频写入轨"
            case .cannotAddAudioInput: return "录制失败：无法添加音频写入轨"
            case .cannotStartWriting(let message): return "录制失败：\(message)"
            case .appendFailed(let message): return "录制失败：\(message)"
            case .missingMainTrack: return "录制失败：主画面无视频轨"
            case .missingPiPTrack: return "录制失败：前摄无视频轨"
            }
        }
    }

    private let mainURL: URL
    private let pipURL: URL?
    private let mainWriter: CameraTrackWriter
    private var pipWriter: CameraTrackWriter?
    private var isFinishing = false

    init(mainURL: URL, pipURL: URL?) throws {
        self.mainURL = mainURL
        self.pipURL = pipURL
        mainWriter = try CameraTrackWriter(outputURL: mainURL, recordsAudio: true)
        pipWriter = try pipURL.map { try CameraTrackWriter(outputURL: $0, recordsAudio: false) }
    }

    func appendMainVideo(_ sampleBuffer: CMSampleBuffer) throws {
        guard !isFinishing else { return }
        try mainWriter.appendVideo(sampleBuffer)
    }

    func appendPiPVideo(_ sampleBuffer: CMSampleBuffer) throws {
        guard !isFinishing else { return }
        try pipWriter?.appendVideo(sampleBuffer)
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) throws {
        guard !isFinishing else { return }
        try mainWriter.appendAudio(sampleBuffer)
    }

    func disablePiP() {
        pipWriter?.cancel()
        pipWriter = nil
    }

    func finish(_ completion: @escaping (Result<Output, Error>) -> Void) {
        guard !isFinishing else { return }
        isFinishing = true

        var tasks: [(writer: CameraTrackWriter, isMain: Bool)] = [(mainWriter, true)]
        if let pipWriter { tasks.append((pipWriter, false)) }

        var remaining = tasks.count
        var mainResultURL: URL?
        var pipResultURL: URL?
        var firstError: Error?

        for task in tasks {
            task.writer.finish { result in
                switch result {
                case .success(let url):
                    if task.isMain {
                        mainResultURL = url
                    } else {
                        pipResultURL = url
                    }
                case .failure(let error):
                    if task.isMain {
                        firstError = error
                    }
                }

                remaining -= 1
                guard remaining == 0 else { return }

                if let firstError {
                    completion(.failure(firstError))
                    return
                }
                guard let mainResultURL else {
                    completion(.failure(RecorderError.missingMainTrack))
                    return
                }
                completion(.success(Output(main: mainResultURL, pip: pipResultURL)))
            }
        }
    }
}

private final class CameraTrackWriter {
    private let outputURL: URL
    private let writer: AVAssetWriter
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var startTime = CMTime.invalid
    private var hasStarted = false
    private var hasVideoFrames = false
    private var isFinishing = false

    init(outputURL: URL, recordsAudio: Bool) throws {
        self.outputURL = outputURL
        try? FileManager.default.removeItem(at: outputURL)
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = true
        if recordsAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw MultiCamMovieRecorder.RecorderError.cannotAddAudioInput }
            writer.add(input)
            audioInput = input
        }
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) throws {
        guard !isFinishing, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if videoInput == nil { try addVideoInput(from: sampleBuffer) }
        guard let videoInput else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !hasStarted { try startWriting(at: timestamp) }
        guard videoInput.isReadyForMoreMediaData else { return }
        if videoInput.append(sampleBuffer) {
            hasVideoFrames = true
        } else {
            throw MultiCamMovieRecorder.RecorderError.appendFailed(writer.error?.localizedDescription ?? "视频帧写入失败")
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) throws {
        guard !isFinishing,
              hasStarted,
              CMSampleBufferDataIsReady(sampleBuffer),
              let audioInput,
              audioInput.isReadyForMoreMediaData else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard !startTime.isValid || CMTimeCompare(timestamp, startTime) >= 0 else { return }
        if !audioInput.append(sampleBuffer) {
            throw MultiCamMovieRecorder.RecorderError.appendFailed(writer.error?.localizedDescription ?? "音频帧写入失败")
        }
    }

    func finish(_ completion: @escaping (Result<URL, Error>) -> Void) {
        guard !isFinishing else { return }
        isFinishing = true
        guard hasStarted, hasVideoFrames else {
            writer.cancelWriting()
            completion(.failure(MultiCamMovieRecorder.RecorderError.missingMainTrack))
            return
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting { [writer, outputURL] in
            if writer.status == .completed {
                Self.validateVideoTrack(at: outputURL, completion: completion)
            } else {
                completion(.failure(MultiCamMovieRecorder.RecorderError.appendFailed(writer.error?.localizedDescription ?? "文件保存失败")))
            }
        }
    }

    func cancel() {
        guard !isFinishing else { return }
        isFinishing = true
        writer.cancelWriting()
    }

    private func addVideoInput(from sampleBuffer: CMSampleBuffer) throws {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw MultiCamMovieRecorder.RecorderError.missingVideoFormat
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let width = max(1, Int(dimensions.width))
        let height = max(1, Int(dimensions.height))
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(width: width, height: height))
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw MultiCamMovieRecorder.RecorderError.cannotAddVideoInput }
        writer.add(input)
        videoInput = input
    }

    private func startWriting(at timestamp: CMTime) throws {
        guard writer.startWriting() else {
            throw MultiCamMovieRecorder.RecorderError.cannotStartWriting(writer.error?.localizedDescription ?? "无法启动文件写入")
        }
        writer.startSession(atSourceTime: timestamp)
        startTime = timestamp
        hasStarted = true
    }

    private static func validateVideoTrack(at url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        let asset = AVURLAsset(url: url)
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) {
            var error: NSError?
            let status = asset.statusOfValue(forKey: "tracks", error: &error)
            guard status == .loaded else {
                completion(.failure(error ?? MultiCamMovieRecorder.RecorderError.appendFailed("录制文件读取失败")))
                return
            }
            if asset.tracks(withMediaType: .video).isEmpty {
                completion(.failure(MultiCamMovieRecorder.RecorderError.missingMainTrack))
            } else {
                completion(.success(url))
            }
        }
    }

    private static func videoSettings(width: Int, height: Int) -> [String: Any] {
        let pixelCount = width * height
        let averageBitRate = min(max(pixelCount * 4, 1_200_000), 6_000_000)
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: averageBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
    }

    private static var audioSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]
    }
}
