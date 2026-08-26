import AVFoundation
import Photos
import ReplayKit

/// ReplayKit 屏幕直播扩展入口，负责把系统录屏样本写成相册视频。
final class SampleHandler: RPBroadcastSampleHandler {
    /// 当前录屏文件写入器。
    private var movieWriter: BroadcastMovieWriter?

    /// 系统录屏开始后创建写入器。
    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        movieWriter = BroadcastMovieWriter()
    }

    /// 系统弹出停止确认框等场景会暂停样本输出，此时用最后一帧继续补齐视频时间轴。
    override func broadcastPaused() {
        movieWriter?.beginSystemPause()
    }

    /// 用户取消系统停止弹窗后恢复真实样本写入。
    override func broadcastResumed() {
        movieWriter?.endSystemPause()
    }

    /// 用户真正停止系统录屏后完成文件写入并保存到相册。
    override func broadcastFinished() {
        guard let movieWriter else { return }
        self.movieWriter = nil
        movieWriter.finishAndPublishDraftCandidate()
    }

    /// 处理 ReplayKit 输出的屏幕和音频样本。
    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        movieWriter?.append(sampleBuffer, type: sampleBufferType)
    }
}

/// 屏幕录制文件写入器，负责维持连续时间轴并发布相册候选视频。
private final class BroadcastMovieWriter {
    /// 串行写入队列，避免多路音视频样本竞争 AVAssetWriter。
    private let queue = DispatchQueue(label: "com.pinbo.screen-broadcast.movie-writer")
    /// 录屏临时输出文件地址。
    private let outputURL: URL
    /// 系统停止确认框期间补帧间隔，15fps 足够维持成片时长且避免体积过大。
    private let pauseFrameInterval = CMTime(value: 1, timescale: 15)
    /// 兜底视频帧间隔，用于系统样本没有携带帧时长时保持递增。
    private let fallbackVideoFrameDuration = CMTime(value: 1, timescale: 30)
    /// 兜底音频时间步长，用于音频样本没有携带时长时保持递增。
    private let fallbackAudioStep = CMTime(value: 1, timescale: 48_000)
    /// 单次恢复时最多补齐的暂停帧数量，避免系统弹窗长时间停留导致扩展阻塞过久。
    private let maximumPauseCatchUpFrameCount = 900
    /// AVFoundation 文件写入器。
    private var writer: AVAssetWriter?
    /// 屏幕视频轨输入。
    private var videoInput: AVAssetWriterInput?
    /// App 内声音轨输入。
    private var appAudioInput: AVAssetWriterInput?
    /// 麦克风声音轨输入。
    private var micAudioInput: AVAssetWriterInput?
    /// 标记 AVAssetWriter 是否已经开启写入 session。
    private var hasStartedSession = false
    /// 标记是否至少写入过一帧视频。
    private var hasWrittenVideo = false
    /// 标记写入器是否已经结束，避免结束后继续追加样本。
    private var isFinished = false
    /// 标记 ReplayKit 当前是否处于系统暂停态。
    private var isSystemPaused = false
    /// 系统暂停期间用于追加最后一帧的定时器。
    private var pauseFrameTimer: DispatchSourceTimer?
    /// 暂停补帧已经覆盖到的墙钟时间。
    private var pauseLastFillWallTime: TimeInterval?
    /// 最近一次真实视频样本，暂停期间用它复制补帧。
    private var lastRealVideoSampleBuffer: CMSampleBuffer?
    /// 最近一次写入视频轨的输出时间戳。
    private var lastVideoOutputPresentationTime = CMTime.invalid
    /// 最近一次真实视频样本的来源时间戳。
    private var lastVideoSourcePresentationTime = CMTime.invalid
    /// 最近一次 App 音频轨的输出时间戳。
    private var lastAppAudioOutputPresentationTime = CMTime.invalid
    /// 最近一次麦克风音频轨的输出时间戳。
    private var lastMicAudioOutputPresentationTime = CMTime.invalid
    /// 来源时间戳到输出时间戳的补偿偏移，用于系统暂停恢复后保持单调连续。
    private var mediaTimeOffset = CMTime.zero
    /// 暂停补帧已经推进到的输出时间，后续真实样本不能早于该时间。
    private var pauseFillEndTime: CMTime?

    /// 创建录屏临时文件路径。
    init() {
        let filename = "Pinbo-ScreenRecording-\(UUID().uuidString).mov"
        outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: outputURL)
    }

    /// 追加 ReplayKit 样本到对应音视频轨。
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

    /// 系统暂停采样时启动补帧，避免用户未真正停止录屏时成片时间轴停住。
    func beginSystemPause() {
        queue.async {
            guard !self.isFinished, self.hasStartedSession, !self.isSystemPaused else { return }
            self.isSystemPaused = true
            self.pauseLastFillWallTime = Date().timeIntervalSinceReferenceDate
            self.startPauseFrameTimer()
        }
    }

    /// 系统恢复采样后停止补帧，后续真实样本会自动按补偿时间戳继续写入。
    func endSystemPause() {
        queue.async {
            self.fillPausedVideoFrames(until: Date().timeIntervalSinceReferenceDate)
            self.isSystemPaused = false
            self.stopPauseFrameTimer()
            self.pauseLastFillWallTime = nil
        }
    }

    /// 完成写入并保存相册候选视频。
    func finishAndPublishDraftCandidate() {
        let semaphore = DispatchSemaphore(value: 0)
        var videoURL: URL?
        queue.async {
            if self.isSystemPaused {
                self.fillPausedVideoFrames(until: Date().timeIntervalSinceReferenceDate)
            }
            self.stopPauseFrameTimer()
            self.pauseLastFillWallTime = nil
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

    /// 追加屏幕视频样本，并在系统暂停恢复后修正来源时间戳。
    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        do {
            try ensureWriter(for: sampleBuffer)
            guard let writer, let videoInput else { return }
            guard writer.status == .writing || writer.status == .unknown else { return }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard presentationTime.isValid else { return }
            let frameDuration = videoFrameDuration(for: sampleBuffer, sourcePresentationTime: presentationTime)
            let outputPresentationTime = adjustedOutputPresentationTime(for: presentationTime,
                                                                        previousOutputTime: lastVideoOutputPresentationTime,
                                                                        minimumStep: frameDuration,
                                                                        floorTime: pauseFillEndTime)
            let outputSampleBuffer = retimedSampleBufferIfNeeded(sampleBuffer,
                                                                 sourcePresentationTime: presentationTime,
                                                                 outputPresentationTime: outputPresentationTime)
            guard let outputSampleBuffer else { return }
            if !hasStartedSession {
                writer.startSession(atSourceTime: outputPresentationTime)
                hasStartedSession = true
            }
            guard videoInput.isReadyForMoreMediaData else { return }
            if videoInput.append(outputSampleBuffer) {
                hasWrittenVideo = true
                lastRealVideoSampleBuffer = outputSampleBuffer
                lastVideoSourcePresentationTime = presentationTime
                lastVideoOutputPresentationTime = outputPresentationTime
            }
        } catch {
            writer?.cancelWriting()
        }
    }

    /// 追加音频样本，并沿用视频暂停补偿后的时间轴。
    private func appendAudio(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard hasStartedSession else { return }
        guard let writer, let input else { return }
        guard writer.status == .writing || writer.status == .unknown else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid else { return }
        let previousOutputTime = input === appAudioInput ? lastAppAudioOutputPresentationTime : lastMicAudioOutputPresentationTime
        let outputPresentationTime = adjustedOutputPresentationTime(for: presentationTime,
                                                                    previousOutputTime: previousOutputTime,
                                                                    minimumStep: audioStep(for: sampleBuffer),
                                                                    floorTime: pauseFillEndTime)
        let outputSampleBuffer = retimedSampleBufferIfNeeded(sampleBuffer,
                                                             sourcePresentationTime: presentationTime,
                                                             outputPresentationTime: outputPresentationTime)
        guard let outputSampleBuffer else { return }
        guard input.isReadyForMoreMediaData else { return }
        if input.append(outputSampleBuffer) {
            if input === appAudioInput {
                lastAppAudioOutputPresentationTime = outputPresentationTime
            } else {
                lastMicAudioOutputPresentationTime = outputPresentationTime
            }
        }
    }

    /// 按首帧视频格式创建 AVAssetWriter 和音视频输入轨。
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

    /// 创建实时 AAC 音频输入轨。
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

    /// 启动暂停补帧定时器。
    private func startPauseFrameTimer() {
        stopPauseFrameTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pauseFrameInterval.seconds,
                       repeating: pauseFrameInterval.seconds)
        timer.setEventHandler { [weak self] in
            self?.appendPausedVideoFrameIfNeeded()
        }
        pauseFrameTimer = timer
        timer.resume()
    }

    /// 停止暂停补帧定时器。
    private func stopPauseFrameTimer() {
        pauseFrameTimer?.cancel()
        pauseFrameTimer = nil
    }

    /// 系统弹窗暂停采样期间复制最后一帧继续推进视频时间轴。
    private func appendPausedVideoFrameIfNeeded() {
        guard isSystemPaused, !isFinished else { return }
        fillPausedVideoFrames(until: Date().timeIntervalSinceReferenceDate)
    }

    /// 按墙钟时间补齐系统暂停期间缺失的视频帧。
    private func fillPausedVideoFrames(until wallTime: TimeInterval) {
        guard let lastFillWallTime = pauseLastFillWallTime else { return }
        let missingFrameCount = min(maximumPauseCatchUpFrameCount,
                                    Int((wallTime - lastFillWallTime) / pauseFrameInterval.seconds))
        guard missingFrameCount > 0 else { return }
        for _ in 0..<missingFrameCount {
            guard appendSinglePausedVideoFrame() else { break }
            pauseLastFillWallTime = (pauseLastFillWallTime ?? lastFillWallTime) + pauseFrameInterval.seconds
        }
    }

    /// 追加一帧暂停补偿帧。
    @discardableResult
    private func appendSinglePausedVideoFrame() -> Bool {
        guard hasStartedSession, let writer, let videoInput else { return false }
        guard writer.status == .writing || writer.status == .unknown else { return false }
        guard videoInput.isReadyForMoreMediaData else { return false }
        guard let lastRealVideoSampleBuffer, lastVideoOutputPresentationTime.isValid else { return false }
        let nextPresentationTime = lastVideoOutputPresentationTime + pauseFrameInterval
        guard let duplicatedSampleBuffer = copySampleBuffer(lastRealVideoSampleBuffer,
                                                           outputPresentationTime: nextPresentationTime) else { return false }
        if videoInput.append(duplicatedSampleBuffer) {
            hasWrittenVideo = true
            lastVideoOutputPresentationTime = nextPresentationTime
            pauseFillEndTime = nextPresentationTime
            return true
        }
        return false
    }

    /// 计算视频样本的输出时间戳，必要时增加偏移保证时间轴不倒退。
    private func adjustedOutputPresentationTime(for sourcePresentationTime: CMTime,
                                                previousOutputTime: CMTime,
                                                minimumStep: CMTime,
                                                floorTime: CMTime?) -> CMTime {
        var outputPresentationTime = sourcePresentationTime + mediaTimeOffset
        var requiredPresentationTime: CMTime?
        if previousOutputTime.isValid,
           CMTimeCompare(outputPresentationTime, previousOutputTime) <= 0 {
            requiredPresentationTime = previousOutputTime + minimumStep
        }
        if let floorTime,
           floorTime.isValid,
           CMTimeCompare(outputPresentationTime, floorTime) <= 0 {
            let afterFloorTime = floorTime + minimumStep
            if let currentRequiredTime = requiredPresentationTime {
                requiredPresentationTime = CMTimeMaximum(currentRequiredTime, afterFloorTime)
            } else {
                requiredPresentationTime = afterFloorTime
            }
        }
        if let requiredPresentationTime,
           CMTimeCompare(requiredPresentationTime, outputPresentationTime) > 0 {
            mediaTimeOffset = mediaTimeOffset + (requiredPresentationTime - outputPresentationTime)
            outputPresentationTime = requiredPresentationTime
        }
        return outputPresentationTime
    }

    /// 只有时间戳发生变化时才复制样本，避免无谓拷贝。
    private func retimedSampleBufferIfNeeded(_ sampleBuffer: CMSampleBuffer,
                                             sourcePresentationTime: CMTime,
                                             outputPresentationTime: CMTime) -> CMSampleBuffer? {
        if CMTimeCompare(sourcePresentationTime, outputPresentationTime) == 0 {
            return sampleBuffer
        }
        return copySampleBuffer(sampleBuffer, outputPresentationTime: outputPresentationTime)
    }

    /// 复制样本并把所有时间戳平移到新的输出展示时间。
    private func copySampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                  outputPresentationTime: CMTime) -> CMSampleBuffer? {
        var timingEntryCount: CMItemCount = 0
        var status = CMSampleBufferGetSampleTimingInfoArray(sampleBuffer,
                                                            entryCount: 0,
                                                            arrayToFill: nil,
                                                            entriesNeededOut: &timingEntryCount)
        guard status == noErr else { return nil }
        if timingEntryCount == 0 {
            var timingInfo = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sampleBuffer),
                                                presentationTimeStamp: outputPresentationTime,
                                                decodeTimeStamp: .invalid)
            var copiedSampleBuffer: CMSampleBuffer?
            status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                           sampleBuffer: sampleBuffer,
                                                           sampleTimingEntryCount: 1,
                                                           sampleTimingArray: &timingInfo,
                                                           sampleBufferOut: &copiedSampleBuffer)
            return status == noErr ? copiedSampleBuffer : nil
        }
        var timingInfoArray = Array(repeating: CMSampleTimingInfo(duration: .invalid,
                                                                  presentationTimeStamp: .invalid,
                                                                  decodeTimeStamp: .invalid),
                                    count: timingEntryCount)
        status = CMSampleBufferGetSampleTimingInfoArray(sampleBuffer,
                                                        entryCount: timingEntryCount,
                                                        arrayToFill: &timingInfoArray,
                                                        entriesNeededOut: &timingEntryCount)
        guard status == noErr else { return nil }
        let originalPresentationTime = timingInfoArray.first?.presentationTimeStamp ?? CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let presentationTimeOffset = outputPresentationTime - originalPresentationTime
        for index in timingInfoArray.indices {
            if timingInfoArray[index].presentationTimeStamp.isValid {
                timingInfoArray[index].presentationTimeStamp = timingInfoArray[index].presentationTimeStamp + presentationTimeOffset
            }
            if timingInfoArray[index].decodeTimeStamp.isValid {
                timingInfoArray[index].decodeTimeStamp = timingInfoArray[index].decodeTimeStamp + presentationTimeOffset
            }
        }
        var copiedSampleBuffer: CMSampleBuffer?
        status = timingInfoArray.withUnsafeBufferPointer { timingInfoBuffer in
            CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                  sampleBuffer: sampleBuffer,
                                                  sampleTimingEntryCount: timingInfoArray.count,
                                                  sampleTimingArray: timingInfoBuffer.baseAddress,
                                                  sampleBufferOut: &copiedSampleBuffer)
        }
        return status == noErr ? copiedSampleBuffer : nil
    }

    /// 获取当前视频样本时长，没有时使用最近两帧差值或默认 30fps。
    private func videoFrameDuration(for sampleBuffer: CMSampleBuffer,
                                    sourcePresentationTime: CMTime) -> CMTime {
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isValid, duration.seconds > 0 {
            return duration
        }
        if lastVideoSourcePresentationTime.isValid,
           CMTimeCompare(sourcePresentationTime, lastVideoSourcePresentationTime) > 0 {
            let frameDuration = sourcePresentationTime - lastVideoSourcePresentationTime
            if frameDuration.seconds > 0, frameDuration.seconds < 1 {
                return frameDuration
            }
        }
        return fallbackVideoFrameDuration
    }

    /// 获取当前音频样本时长，没有时使用极小步长保证时间戳单调。
    private func audioStep(for sampleBuffer: CMSampleBuffer) -> CMTime {
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isValid, duration.seconds > 0 {
            return duration
        }
        return fallbackAudioStep
    }

    /// 保存录屏文件到系统相册，主 App 会从相册中导入草稿。
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
