import AVFoundation
import Photos
import ReplayKit

final class SampleHandler: RPBroadcastSampleHandler {
    private var movieWriter: BroadcastMovieWriter?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        movieWriter = BroadcastMovieWriter()
    }

    override func broadcastPaused() {}

    override func broadcastResumed() {}

    override func broadcastFinished() {
        guard let movieWriter else { return }
        self.movieWriter = nil
        movieWriter.finishAndPublishDraftCandidate()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        movieWriter?.append(sampleBuffer, type: sampleBufferType)
    }
}

private final class BroadcastMovieWriter {
    private let queue = DispatchQueue(label: "com.pinbo.screen-broadcast.movie-writer")
    private let outputURL: URL
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var appAudioInput: AVAssetWriterInput?
    private var micAudioInput: AVAssetWriterInput?
    private var hasStartedSession = false
    private var hasWrittenVideo = false
    private var isFinished = false

    init() {
        let filename = "Pinbo-ScreenRecording-\(UUID().uuidString).mov"
        outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: outputURL)
    }

    func append(_ sampleBuffer: CMSampleBuffer, type: RPSampleBufferType) {
        queue.async {
            guard !self.isFinished, CMSampleBufferDataIsReady(sampleBuffer) else { return }
            switch type {
            case .video:
                self.appendVideo(sampleBuffer)
            case .audioApp:
                self.appendAudio(sampleBuffer, to: self.appAudioInput)
            case .audioMic:
                self.appendAudio(sampleBuffer, to: self.micAudioInput)
            @unknown default:
                break
            }
        }
    }

    func finishAndPublishDraftCandidate() {
        let semaphore = DispatchSemaphore(value: 0)
        var videoURL: URL?
        queue.async {
            self.isFinished = true
            guard let writer = self.writer, self.hasWrittenVideo else {
                semaphore.signal()
                return
            }
            self.videoInput?.markAsFinished()
            self.appAudioInput?.markAsFinished()
            self.micAudioInput?.markAsFinished()
            writer.finishWriting {
                if writer.status == .completed {
                    videoURL = self.outputURL
                }
                semaphore.signal()
            }
        }
        _ = semaphore.wait(timeout: .now() + 30)
        guard let videoURL else { return }
        saveToPhotoLibrary(videoURL)
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        do {
            try ensureWriter(for: sampleBuffer)
            guard let writer, let videoInput else { return }
            guard writer.status == .writing || writer.status == .unknown else { return }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard presentationTime.isValid else { return }
            if !hasStartedSession {
                writer.startSession(atSourceTime: presentationTime)
                hasStartedSession = true
            }
            guard videoInput.isReadyForMoreMediaData else { return }
            if videoInput.append(sampleBuffer) {
                hasWrittenVideo = true
            }
        } catch {
            writer?.cancelWriting()
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard hasStartedSession else { return }
        guard let writer, let input else { return }
        guard writer.status == .writing || writer.status == .unknown else { return }
        guard input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    private func ensureWriter(for sampleBuffer: CMSampleBuffer) throws {
        if writer != nil { return }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(dimensions.width),
            AVVideoHeightKey: Int(dimensions.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(4_000_000, Int(dimensions.width * dimensions.height * 4)),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard assetWriter.canAdd(videoInput) else { return }
        assetWriter.add(videoInput)
        let appAudioInput = makeAudioInput()
        let micAudioInput = makeAudioInput()
        if assetWriter.canAdd(appAudioInput) {
            assetWriter.add(appAudioInput)
            self.appAudioInput = appAudioInput
        }
        if assetWriter.canAdd(micAudioInput) {
            assetWriter.add(micAudioInput)
            self.micAudioInput = micAudioInput
        }
        guard assetWriter.startWriting() else { return }
        writer = assetWriter
        self.videoInput = videoInput
    }

    private func makeAudioInput() -> AVAssetWriterInput {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        return input
    }

    private func saveToPhotoLibrary(_ videoURL: URL) {
        let saveBlock = {
            let semaphore = DispatchSemaphore(value: 0)
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
            }, completionHandler: { _, _ in
                try? FileManager.default.removeItem(at: videoURL)
                semaphore.signal()
            })
            _ = semaphore.wait(timeout: .now() + 20)
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            saveBlock()
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                if newStatus == .authorized || newStatus == .limited {
                    saveBlock()
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 20)
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }
}
