#if DEBUG
import AVFoundation
import Darwin
import Foundation

final class CameraSmokeTestRunner: NSObject {
    private static var activeRunner: CameraSmokeTestRunner?

    private let source = DualCameraSource()
    private var didFinish = false

    static func runIfRequested() {
        guard CommandLine.arguments.contains("--pinbo-camera-smoke") else { return }
        let runner = CameraSmokeTestRunner()
        activeRunner = runner
        runner.start()
    }

    private func start() {
        print("PINBO_CAMERA_SMOKE_START")
        requestCameraAndMic { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.finishFailure("permissions_denied")
                return
            }
            self.source.delegate = self
            do {
                try self.source.configure()
            } catch {
                self.finishFailure("configure_failed: \(Self.describe(error))")
                return
            }
            self.source.startRunning { [weak self] isRunning in
                guard let self else { return }
                guard isRunning else {
                    self.finishFailure("preview_start_failed")
                    return
                }
                print("PINBO_CAMERA_SMOKE_RECORD_START")
                self.source.startRecording(includePiP: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self, !self.didFinish else { return }
                    print("PINBO_CAMERA_SMOKE_RECORD_STOP")
                    self.source.stopRecording()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                    guard let self, !self.didFinish else { return }
                    self.finishFailure("timeout")
                }
            }
        }
    }

    private func requestCameraAndMic(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { videoGranted in
            AVCaptureDevice.requestAccess(for: .audio) { audioGranted in
                DispatchQueue.main.async { completion(videoGranted && audioGranted) }
            }
        }
    }

    private func validateVideo(at mainURL: URL, pipURL: URL?) {
        validateVideoTrack(at: mainURL, label: "main") { [weak self] mainDuration, mainError in
            guard let self else { return }
            if let mainError {
                self.finishFailure(mainError)
                return
            }
            guard let mainDuration, let pipURL else {
                self.finishFailure("missing_pip_url")
                return
            }
            self.validateVideoTrack(at: pipURL, label: "pip") { [weak self] pipDuration, pipError in
                guard let self else { return }
                if let pipError {
                    self.finishFailure(pipError)
                    return
                }
                guard let pipDuration else {
                    self.finishFailure("pip_missing_duration")
                    return
                }
                print("PINBO_CAMERA_SMOKE_SUCCESS mainDuration=\(mainDuration) pipDuration=\(pipDuration) main=\(mainURL.path) pip=\(pipURL.path)")
                self.didFinish = true
                CameraSmokeTestRunner.activeRunner = nil
                exit(0)
            }
        }
    }

    private func validateVideoTrack(at url: URL,
                                    label: String,
                                    completion: @escaping (TimeInterval?, String?) -> Void) {
        let asset = AVURLAsset(url: url)
        asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) { [weak self] in
            guard let self else { return }
            var error: NSError?
            let status = asset.statusOfValue(forKey: "tracks", error: &error)
            guard status == .loaded else {
                completion(nil, "\(label)_asset_load_failed: \(error?.localizedDescription ?? "unknown")")
                return
            }
            let videoTracks = asset.tracks(withMediaType: .video)
            guard !videoTracks.isEmpty else {
                completion(nil, "\(label)_missing_video_track")
                return
            }
            completion(asset.duration.seconds, nil)
        }
    }

    private func finishFailure(_ message: String) {
        print("PINBO_CAMERA_SMOKE_FAILURE \(message)")
        didFinish = true
        CameraSmokeTestRunner.activeRunner = nil
        exit(2)
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code) \(nsError.localizedDescription)"
    }
}

extension CameraSmokeTestRunner: CaptureSourceDelegate {
    func captureSource(_ source: CaptureSourceProviding, didChange state: CaptureState) {
        print("PINBO_CAMERA_SMOKE_STATE \(state)")
        if case .failed(let message) = state, !didFinish {
            finishFailure("state_failed: \(message)")
        }
    }

    func captureSource(_ source: CaptureSourceProviding,
                       didFinishRecordingMain mainURL: URL?,
                       pip pipURL: URL?) {
        guard let mainURL else {
            finishFailure("missing_main_url")
            return
        }
        validateVideo(at: mainURL, pipURL: pipURL)
    }

    func captureSource(_ source: CaptureSourceProviding, didOutput audioBuffer: CMSampleBuffer) {}
}
#endif
