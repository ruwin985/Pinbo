import AVFoundation
import CoreMedia
import Foundation

final class SampleBufferMovieWriter {
    /// 录屏文件中可以写入的音频来源。
    enum AudioSource: Hashable {
        /// ScreenCaptureKit 提供的电脑声音。
        case system
        /// 当前 macOS 默认输入设备提供的麦克风声音。
        case microphone
    }

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
    /// 当前写入器需要创建的音频来源轨道。
    private let audioSources: Set<AudioSource>
    /// 写入器声明的目标帧速率。
    private let frameRate: CaptureFrameRate
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    /// 电脑声音对应的写入轨道。
    private var systemAudioInput: AVAssetWriterInput?
    /// 外接输入设备声音对应的写入轨道。
    private var microphoneAudioInput: AVAssetWriterInput?
    private var startedSession = false
    private let writingQueue = DispatchQueue(label: "com.pinbo.mac.sample-buffer-writer")

    /// 创建一个实时视频写入器。
    init(outputURL: URL,
         fileType: AVFileType = .mov,
         audioSources: Set<AudioSource> = [],
         frameRate: CaptureFrameRate = .fps30) {
        self.outputURL = outputURL
        self.fileType = fileType
        self.audioSources = audioSources
        self.frameRate = frameRate
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

    /// 将指定来源的音频样本写入独立轨道，保留两路声音各自的时间戳。
    func appendAudio(_ sampleBuffer: CMSampleBuffer, source: AudioSource) {
        writingQueue.async {
            guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
            guard self.writer != nil else { return }
            let input: AVAssetWriterInput?
            switch source {
            case .system:
                input = self.systemAudioInput
            case .microphone:
                input = self.microphoneAudioInput
            }
            guard let writer = self.writer, let input else { return }
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
            self.systemAudioInput?.markAsFinished()
            self.microphoneAudioInput?.markAsFinished()
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
        let pixelCount = Int(dimensions.width) * Int(dimensions.height)
        let frameRateScale = max(1, frameRate.rawValue / 30)
        let averageBitRate = min(max(pixelCount * 4 * frameRateScale, 2_000_000), 48_000_000)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(dimensions.width),
            AVVideoHeightKey: Int(dimensions.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: averageBitRate,
                AVVideoExpectedSourceFrameRateKey: frameRate.rawValue,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw WriterError.cannotCreateWriter("无法添加视频写入轨道")
        }
        writer.add(input)
        if audioSources.contains(.system) {
            systemAudioInput = try addAudioInput(to: writer, sourceName: "电脑声音")
        }
        if audioSources.contains(.microphone) {
            microphoneAudioInput = try addAudioInput(to: writer, sourceName: "麦克风声音")
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

    /// 创建并加入一条实时 AAC 音频轨道。
    private func addAudioInput(to writer: AVAssetWriter,
                               sourceName: String) throws -> AVAssetWriterInput {
        guard let input = makeAudioInput(), writer.canAdd(input) else {
            throw WriterError.cannotCreateWriter("无法添加\(sourceName)写入轨道")
        }
        writer.add(input)
        return input
    }
}

/// 将录屏文件中的电脑声音和麦克风声音混合为单条音轨，同时原样复制视频码流。
final class ScreenRecordingAudioMixer {
    /// 双路音频混合过程中可能出现的错误。
    enum MixerError: Error, LocalizedError {
        case missingVideoTrack
        case missingVideoFormat
        case cannotCreateReader(String)
        case cannotCreateWriter(String)
        case cannotStartProcessing(String)
        case processingFailed(String)
        case processingTimedOut

        /// 面向录制页面展示的中文错误信息。
        var errorDescription: String? {
            switch self {
            case .missingVideoTrack: return "录屏文件缺少视频轨道"
            case .missingVideoFormat: return "录屏文件缺少视频格式信息"
            case .cannotCreateReader(let message): return "无法读取录屏音频：\(message)"
            case .cannotCreateWriter(let message): return "无法创建混音文件：\(message)"
            case .cannotStartProcessing(let message): return "无法开始同步声音：\(message)"
            case .processingFailed(let message): return "电脑声音与麦克风混合失败：\(message)"
            case .processingTimedOut: return "同步电脑声音与输入设备声音超时"
            }
        }
    }

    /// 音频混合使用的串行工作队列。
    private static let processingQueue = DispatchQueue(label: "com.pinbo.mac.screen-audio-mixer")

    /// 仅当文件包含多条音轨时执行混音，单音轨文件直接返回原地址。
    static func mixIfNeeded(inputURL: URL,
                            completion: @escaping (Result<URL, Error>) -> Void) {
        processingQueue.async {
            do {
                let outputURL = try mixIfNeededSynchronously(inputURL: inputURL)
                DispatchQueue.main.async { completion(.success(outputURL)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// 同步构建读取器和写入器，并等待视频直通与音频混合完成。
    private static func mixIfNeededSynchronously(inputURL: URL) throws -> URL {
        let asset = AVURLAsset(url: inputURL)
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard audioTracks.count > 1 else { return inputURL }
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw MixerError.missingVideoTrack
        }
        guard let rawVideoFormat = videoTrack.formatDescriptions.first else {
            throw MixerError.missingVideoFormat
        }
        let videoFormat = rawVideoFormat as! CMFormatDescription

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinbo_screen_mixed_\(UUID().uuidString).mov")
        var shouldKeepOutputFile = false
        defer {
            if !shouldKeepOutputFile {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }
        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw MixerError.cannotCreateReader(error.localizedDescription)
        }
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw MixerError.cannotCreateWriter(error.localizedDescription)
        }

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw MixerError.cannotCreateReader("无法添加视频直通轨道")
        }
        reader.add(videoOutput)

        let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks,
                                                      audioSettings: linearPCMAudioSettings)
        audioOutput.audioMix = makeAudioMix(audioTracks: audioTracks)
        guard reader.canAdd(audioOutput) else {
            throw MixerError.cannotCreateReader("无法添加双路音频混合轨道")
        }
        reader.add(audioOutput)

        let videoInput = AVAssetWriterInput(mediaType: .video,
                                            outputSettings: nil,
                                            sourceFormatHint: videoFormat)
        videoInput.transform = videoTrack.preferredTransform
        let audioInput = AVAssetWriterInput(mediaType: .audio,
                                            outputSettings: encodedAudioSettings)
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw MixerError.cannotCreateWriter("无法添加视频或音频输出轨道")
        }
        writer.add(videoInput)
        writer.add(audioInput)

        guard writer.startWriting() else {
            throw MixerError.cannotStartProcessing(writer.error?.localizedDescription ?? "写入器启动失败")
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw MixerError.cannotStartProcessing(reader.error?.localizedDescription ?? "读取器启动失败")
        }
        writer.startSession(atSourceTime: .zero)

        let firstError = processSamples(reader: reader,
                                        writer: writer,
                                        videoOutput: videoOutput,
                                        audioOutput: audioOutput,
                                        videoInput: videoInput,
                                        audioInput: audioInput,
                                        timeout: processingTimeout(for: videoTrack.timeRange.duration))
        if let firstError {
            reader.cancelReading()
            writer.cancelWriting()
            throw firstError
        }

        let finishSemaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { finishSemaphore.signal() }
        guard finishSemaphore.wait(timeout: .now() + 60) == .success else {
            writer.cancelWriting()
            throw MixerError.processingTimedOut
        }
        guard writer.status == .completed else {
            throw MixerError.processingFailed(writer.error?.localizedDescription ?? "混音文件写入失败")
        }
        shouldKeepOutputFile = true
        return outputURL
    }

    /// 并行复制压缩视频样本，并把两条音轨混合后的 PCM 样本编码为 AAC。
    private static func processSamples(reader: AVAssetReader,
                                       writer: AVAssetWriter,
                                       videoOutput: AVAssetReaderTrackOutput,
                                       audioOutput: AVAssetReaderAudioMixOutput,
                                       videoInput: AVAssetWriterInput,
                                       audioInput: AVAssetWriterInput,
                                       timeout: TimeInterval) -> Error? {
        let group = DispatchGroup()
        let errorLock = NSLock()
        var firstError: Error?

        /// 线程安全地保存首次出现的处理错误。
        func record(error: Error) {
            errorLock.lock()
            if firstError == nil { firstError = error }
            errorLock.unlock()
        }

        /// 线程安全地读取首次出现的处理错误。
        func recordedError() -> Error? {
            errorLock.lock()
            defer { errorLock.unlock() }
            return firstError
        }

        group.enter()
        videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "com.pinbo.mac.screen-audio-mixer.video")) {
            while videoInput.isReadyForMoreMediaData {
                guard let sampleBuffer = videoOutput.copyNextSampleBuffer() else {
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                guard videoInput.append(sampleBuffer) else {
                    record(error: MixerError.processingFailed(writer.error?.localizedDescription ?? "视频码流复制失败"))
                    reader.cancelReading()
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
            }
        }

        group.enter()
        audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "com.pinbo.mac.screen-audio-mixer.audio")) {
            while audioInput.isReadyForMoreMediaData {
                guard let sampleBuffer = audioOutput.copyNextSampleBuffer() else {
                    audioInput.markAsFinished()
                    group.leave()
                    return
                }
                guard audioInput.append(sampleBuffer) else {
                    record(error: MixerError.processingFailed(writer.error?.localizedDescription ?? "音频混合写入失败"))
                    reader.cancelReading()
                    audioInput.markAsFinished()
                    group.leave()
                    return
                }
            }
        }

        guard group.wait(timeout: .now() + timeout) == .success else {
            let timeoutError = MixerError.processingTimedOut
            record(error: timeoutError)
            reader.cancelReading()
            writer.cancelWriting()
            return recordedError()
        }
        if let firstError = recordedError() { return firstError }
        if reader.status == .failed {
            return MixerError.processingFailed(reader.error?.localizedDescription ?? "读取录屏文件失败")
        }
        return nil
    }

    /// 根据录制时长提供有限但充足的处理等待时间，避免损坏文件导致永久阻塞。
    private static func processingTimeout(for duration: CMTime) -> TimeInterval {
        let durationSeconds = duration.seconds
        guard durationSeconds.isFinite, durationSeconds > 0 else { return 300 }
        return min(max(durationSeconds * 2 + 60, 300), 3_600)
    }

    /// 创建电脑声音稍低、麦克风保持原音量的混音参数。
    private static func makeAudioMix(audioTracks: [AVAssetTrack]) -> AVAudioMix {
        let mix = AVMutableAudioMix()
        mix.inputParameters = audioTracks.enumerated().map { index, track in
            let parameter = AVMutableAudioMixInputParameters(track: track)
            parameter.setVolume(index == 0 ? 0.8 : 1.0, at: .zero)
            return parameter
        }
        return mix
    }

    /// 音频混合读取阶段使用的统一双声道浮点 PCM 格式。
    private static var linearPCMAudioSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    /// 最终单音轨使用的高码率 AAC 编码参数。
    private static var encodedAudioSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ]
    }
}
