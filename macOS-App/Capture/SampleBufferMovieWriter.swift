import AVFoundation
import CoreMedia
import Foundation

final class SampleBufferMovieWriter {
    enum WriterError: Error, LocalizedError {
        case cannotCreateWriter(String)
        case missingFormatDescription
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .cannotCreateWriter(let message): return message
            case .missingFormatDescription: return "缺少视频格式信息"
            case .writerFailed(let message): return message
            }
        }
    }

    private let outputURL: URL
    private let fileType: AVFileType
    private let includesAudio: Bool
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var startedSession = false
    private let writingQueue = DispatchQueue(label: "com.pinbo.mac.sample-buffer-writer")

    init(outputURL: URL, fileType: AVFileType = .mov, includesAudio: Bool = false) {
        self.outputURL = outputURL
        self.fileType = fileType
        self.includesAudio = includesAudio
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        writingQueue.async {
            guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
            do {
                try self.ensureWriter(for: sampleBuffer)
                guard let writer = self.writer, let input = self.videoInput else { return }
                guard writer.status == .writing || writer.status == .unknown else { return }
                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                if !self.startedSession {
                    writer.startSession(atSourceTime: presentationTime)
                    self.startedSession = true
                }
                if input.isReadyForMoreMediaData {
                    input.append(sampleBuffer)
                }
            } catch {
                self.writer?.cancelWriting()
            }
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        writingQueue.async {
            guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
            guard self.writer != nil else { return }
            guard let writer = self.writer, let input = self.audioInput else { return }
            guard writer.status == .writing || writer.status == .unknown else { return }
            if input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        }
    }

    func finish(completion: @escaping (Result<URL, Error>) -> Void) {
        writingQueue.async {
            guard let writer = self.writer else {
                DispatchQueue.main.async { completion(.success(self.outputURL)) }
                return
            }
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            writer.finishWriting {
                DispatchQueue.main.async {
                    if writer.status == .completed {
                        completion(.success(self.outputURL))
                    } else {
                        completion(.failure(WriterError.writerFailed(writer.error?.localizedDescription ?? "写入失败")))
                    }
                }
            }
        }
    }

    private func ensureWriter(for sampleBuffer: CMSampleBuffer) throws {
        if writer != nil { return }
        try? FileManager.default.removeItem(at: outputURL)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        } catch {
            throw WriterError.cannotCreateWriter(error.localizedDescription)
        }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw WriterError.missingFormatDescription
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(dimensions.width),
            AVVideoHeightKey: Int(dimensions.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, Int(dimensions.width * dimensions.height * 4)),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw WriterError.cannotCreateWriter("无法添加视频写入轨道")
        }
        writer.add(input)
        if includesAudio, let audioInput = makeAudioInput() {
            writer.add(audioInput)
            self.audioInput = audioInput
        }
        guard writer.startWriting() else {
            throw WriterError.cannotCreateWriter(writer.error?.localizedDescription ?? "无法开始写入")
        }
        self.writer = writer
        self.videoInput = input
    }

    private func makeAudioInput() -> AVAssetWriterInput? {
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
}
