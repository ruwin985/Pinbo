import Foundation
import AVFoundation

/// iOS 双摄采集源：后摄 = 主画面，前摄 = 画中画。
/// 采用「系统预览层 + MovieFileOutput 分路直录」策略：性能最佳（预览走 GPU 零成本），
/// 两路各写一个文件，音频挂在后摄一路，音频同时给实时字幕。
final class DualCameraSource: NSObject, CaptureSourceProviding {

    weak var delegate: CaptureSourceDelegate?
    private(set) var state: CaptureState = .idle {
        didSet { let s = state; DispatchQueue.main.async { self.delegate?.captureSource(self, didChange: s) } }
    }

    static var isSupported: Bool { AVCaptureMultiCamSession.isMultiCamSupported }

    private let session = AVCaptureMultiCamSession()
    private let sessionQueue = DispatchQueue(label: "com.pinbo.capture.session")
    private let audioQueue = DispatchQueue(label: "com.pinbo.capture.audio")

    // 后摄（主画面）
    private let backMovieOutput = AVCaptureMovieFileOutput()
    private var backPreviewLayer: AVCaptureVideoPreviewLayer?

    // 前摄（画中画）
    private let frontMovieOutput = AVCaptureMovieFileOutput()
    private var frontPreviewLayer: AVCaptureVideoPreviewLayer?

    // 音频（供实时字幕）
    private let audioDataOutput = AVCaptureAudioDataOutput()

    private var backFileURL: URL?
    private var frontFileURL: URL?
    private var pendingFinishCount = 0
    private var isRecordingPiP = true

    // MARK: - Configure

    func configure() throws {
        guard Self.isSupported else {
            state = .failed("当前设备不支持多摄（需 A12 芯片及以上）")
            throw err("MultiCam not supported")
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        try configureCamera(position: .back, output: backMovieOutput, storePreview: { self.backPreviewLayer = $0 })
        try configureCamera(position: .front, output: frontMovieOutput, storePreview: { self.frontPreviewLayer = $0 })
        try configureMic()

        state = .configured
    }

    private func configureCamera(position: AVCaptureDevice.Position,
                                 output: AVCaptureMovieFileOutput,
                                 storePreview: (AVCaptureVideoPreviewLayer) -> Void) throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw err("无法获取摄像头")
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw err("无法添加摄像头输入") }
        session.addInputWithNoConnections(input)

        guard session.canAddOutput(output) else { throw err("无法添加视频输出") }
        session.addOutputWithNoConnections(output)

        guard let port = input.ports(for: .video, sourceDeviceType: device.deviceType,
                                     sourceDevicePosition: position).first else {
            throw err("无法获取视频端口")
        }
        let connection = AVCaptureConnection(inputPorts: [port], output: output)
        guard session.canAddConnection(connection) else { throw err("无法连接视频输出") }
        session.addConnection(connection)
        // 录制方向设为竖屏，使文件本身正立（避免后期方向纠正的歧义）
        if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
        // 前摄镜像，符合自拍习惯
        if position == .front, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }

        let preview = AVCaptureVideoPreviewLayer()
        preview.setSessionWithNoConnection(session)
        preview.videoGravity = .resizeAspectFill
        let previewConn = AVCaptureConnection(inputPort: port, videoPreviewLayer: preview)
        guard session.canAddConnection(previewConn) else { throw err("无法连接预览") }
        session.addConnection(previewConn)
        if previewConn.isVideoOrientationSupported { previewConn.videoOrientation = .portrait }
        if position == .front, previewConn.isVideoMirroringSupported {
            previewConn.automaticallyAdjustsVideoMirroring = false
            previewConn.isVideoMirrored = true
        }
        storePreview(preview)
    }

    private func configureMic() throws {
        guard let device = AVCaptureDevice.default(for: .audio) else { throw err("无法获取麦克风") }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw err("无法添加音频输入") }
        session.addInputWithNoConnections(input)

        guard let port = input.ports(for: .audio, sourceDeviceType: device.deviceType,
                                     sourceDevicePosition: device.position).first else { return }
        // 音频写入后摄文件
        let toMovie = AVCaptureConnection(inputPorts: [port], output: backMovieOutput)
        if session.canAddConnection(toMovie) { session.addConnection(toMovie) }

        // 音频 data output 用于实时字幕
        guard session.canAddOutput(audioDataOutput) else { throw err("无法添加音频数据输出") }
        session.addOutputWithNoConnections(audioDataOutput)
        audioDataOutput.setSampleBufferDelegate(self, queue: audioQueue)
        let toData = AVCaptureConnection(inputPorts: [port], output: audioDataOutput)
        if session.canAddConnection(toData) { session.addConnection(toData) }
    }

    // MARK: - Preview

    func makeMainPreviewLayer() -> AVCaptureVideoPreviewLayer? { backPreviewLayer }
    func makePiPPreviewLayer() -> AVCaptureVideoPreviewLayer? { frontPreviewLayer }

    // MARK: - Running

    func startRunning() {
        sessionQueue.async { if !self.session.isRunning { self.session.startRunning() } }
    }
    func stopRunning() {
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    // MARK: - Recording

    func startRecording() {
        startRecording(includePiP: true)
    }

    func startRecording(includePiP: Bool = true) {
        sessionQueue.async {
            let dir = FileManager.default.temporaryDirectory
            let stamp = Int(Date().timeIntervalSince1970)
            let back = dir.appendingPathComponent("pinbo_back_\(stamp).mov")
            self.backFileURL = back
            self.frontFileURL = nil
            self.isRecordingPiP = includePiP
            self.pendingFinishCount = includePiP ? 2 : 1
            self.backMovieOutput.startRecording(to: back, recordingDelegate: self)
            if includePiP {
                let front = dir.appendingPathComponent("pinbo_front_\(stamp).mov")
                self.frontFileURL = front
                self.frontMovieOutput.startRecording(to: front, recordingDelegate: self)
            }
            self.state = .recording
        }
    }

    func stopRecording() {
        sessionQueue.async {
            if self.backMovieOutput.isRecording { self.backMovieOutput.stopRecording() }
            if self.frontMovieOutput.isRecording { self.frontMovieOutput.stopRecording() }
        }
    }

    private func err(_ m: String) -> NSError {
        NSError(domain: "Pinbo", code: -2, userInfo: [NSLocalizedDescriptionKey: m])
    }
}

// MARK: - Recording delegate

extension DualCameraSource: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        sessionQueue.async {
            self.pendingFinishCount -= 1
            if self.pendingFinishCount <= 0 {
                DispatchQueue.main.async {
                    self.state = .stopped
                    self.delegate?.captureSource(self,
                                                 didFinishRecordingMain: self.backFileURL,
                                                 pip: self.isRecordingPiP ? self.frontFileURL : nil)
                }
            }
        }
    }
}

// MARK: - Audio for subtitle

extension DualCameraSource: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        delegate?.captureSource(self, didOutput: sampleBuffer)
    }
}
