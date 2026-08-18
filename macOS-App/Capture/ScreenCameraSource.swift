import AVFoundation
import CoreMedia
import ScreenCaptureKit

final class ScreenCameraSource: NSObject {
    enum SourceError: Error, LocalizedError {
        case unsupported
        case missingTarget
        case noCamera
        case noMicrophone
        case cannotConfigureCamera
        case cannotConfigureMicrophone
        case cannotAddScreenOutput(String)

        var errorDescription: String? {
            switch self {
            case .unsupported: return "macOS 12.3 及以上才支持 ScreenCaptureKit 录屏"
            case .missingTarget: return "请先选择要录制的桌面或应用窗口"
            case .noCamera: return "无法获取电脑摄像头"
            case .noMicrophone: return "无法获取麦克风"
            case .cannotConfigureCamera: return "无法配置摄像头"
            case .cannotConfigureMicrophone: return "无法配置麦克风"
            case .cannotAddScreenOutput(let message): return message
            }
        }
    }

    var onStateChange: ((CaptureState) -> Void)?
    var onScreenSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onFinishRecording: ((_ mainURL: URL?, _ pipURL: URL?) -> Void)?

    private(set) var state: CaptureState = .idle {
        didSet { DispatchQueue.main.async { self.onStateChange?(self.state) } }
    }

    private let target: ScreenCaptureTarget
    private let screenQueue = DispatchQueue(label: "com.pinbo.mac.screen-stream")
    private let cameraQueue = DispatchQueue(label: "com.pinbo.mac.camera-session")
    private let cameraDataQueue = DispatchQueue(label: "com.pinbo.mac.camera-data")
    private let microphoneQueue = DispatchQueue(label: "com.pinbo.mac.microphone-data")

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

    func configure() throws {
        guard #available(macOS 12.3, *) else { throw SourceError.unsupported }
        try configureScreenStream()
        state = .configured
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
            if self.cameraSession.outputs.contains(where: { $0 === self.cameraVideoOutput }) {
                self.cameraSession.removeOutput(self.cameraVideoOutput)
            }
            if let cameraInput = self.cameraInput,
               self.cameraSession.inputs.contains(where: { $0 === cameraInput }) {
                self.cameraSession.removeInput(cameraInput)
            }
            self.cameraSession.commitConfiguration()
            self.cameraInput = nil
            self.cameraPreviewLayer = nil
            self.isCameraConfigured = false
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
            if self.cameraSession.outputs.contains(where: { $0 === self.microphoneOutput }) {
                self.cameraSession.removeOutput(self.microphoneOutput)
            }
            if let microphoneInput = self.microphoneInput,
               self.cameraSession.inputs.contains(where: { $0 === microphoneInput }) {
                self.cameraSession.removeInput(microphoneInput)
            }
            self.cameraSession.commitConfiguration()
            self.microphoneInput = nil
            self.isMicrophoneConfigured = false
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
        screenWriter = SampleBufferMovieWriter(outputURL: mainURL, includesAudio: true)
        cameraWriter = includePiP ? SampleBufferMovieWriter(outputURL: pipURL) : nil
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
        let size = target.pixelSize.scaledDown(maxLongEdge: 1920)
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 5
        config.showsCursor = true
        config.scalesToFit = true
        if #available(macOS 13.0, *) {
            config.capturesAudio = false
        }
        if #available(macOS 14.0, *) {
            config.preservesAspectRatio = true
            config.captureResolution = .nominal
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        } catch {
            throw SourceError.cannotAddScreenOutput(error.localizedDescription)
        }
        screenStream = stream
        screenConfiguration = config
    }

    private func configureCameraIfNeeded() throws {
        guard !isCameraConfigured else { return }
        cameraSession.beginConfiguration()
        defer { cameraSession.commitConfiguration() }
        cameraSession.sessionPreset = .high

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video) else {
            throw SourceError.noCamera
        }
        let cameraInput = try AVCaptureDeviceInput(device: camera)
        guard cameraSession.canAddInput(cameraInput) else { throw SourceError.cannotConfigureCamera }
        cameraSession.addInput(cameraInput)
        self.cameraInput = cameraInput

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
    }

    private func configureMicrophoneIfNeeded() throws {
        guard !isMicrophoneConfigured else { return }
        cameraSession.beginConfiguration()
        defer { cameraSession.commitConfiguration() }
        cameraSession.sessionPreset = .high

        guard let microphone = AVCaptureDevice.default(for: .audio) else { throw SourceError.noMicrophone }
        let microphoneInput = try AVCaptureDeviceInput(device: microphone)
        guard cameraSession.canAddInput(microphoneInput) else { throw SourceError.cannotConfigureMicrophone }
        cameraSession.addInput(microphoneInput)
        self.microphoneInput = microphoneInput

        guard cameraSession.canAddOutput(microphoneOutput) else { throw SourceError.cannotConfigureMicrophone }
        cameraSession.addOutput(microphoneOutput)
        microphoneOutput.setSampleBufferDelegate(self, queue: microphoneQueue)
        isMicrophoneConfigured = true
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
            onScreenSampleBuffer?(sampleBuffer)
            if isRecording {
                screenWriter?.appendVideo(sampleBuffer)
            }
        case .audio:
            onAudioSampleBuffer?(sampleBuffer)
            if isRecording {
                screenWriter?.appendAudio(sampleBuffer)
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
            onAudioSampleBuffer?(sampleBuffer)
            if isRecording {
                screenWriter?.appendAudio(sampleBuffer)
            }
        }
    }
}

private extension CGSize {
    func scaledDown(maxLongEdge: CGFloat) -> CGSize {
        let longEdge = max(width, height)
        guard longEdge > maxLongEdge else { return self.roundedAtLeastOne }
        let scale = maxLongEdge / longEdge
        return CGSize(width: width * scale, height: height * scale).roundedAtLeastOne
    }

    var roundedAtLeastOne: CGSize {
        CGSize(width: max(1, width.rounded()), height: max(1, height.rounded()))
    }
}
