import Foundation
import Speech
import AVFoundation

/// 实时语音转文字（设备端）。中/英可切换。
/// 注意：系统识别单次约有时长限制，长录制需分段重启（本 Demo 已做简单自动重启）。
public final class LiveSpeechRecognizer {

    public enum Language: String {
        case chinese = "zh-CN"
        case english = "en-US"
    }

    /// 部分/最终识别结果回调（在主线程）
    public var onText: ((String, _ isFinal: Bool) -> Void)?

    /// 一段识别最终确定时回调完整 transcription（含逐词时间戳），供精准分段使用。
    /// timeOffset 为本段相对整段录音起点的偏移（秒）。
    public var onFinalTranscription: ((SFTranscription, _ timeOffset: TimeInterval) -> Void)?

    /// 录音开始的参考时间，用于计算各段的 timeOffset。
    private var startDate: Date?
    private var accumulatedOffset: TimeInterval = 0

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var isRunning = false

    public init(language: Language = .chinese) {
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.rawValue))
    }

    /// 申请语音识别权限
    public static func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion(status == .authorized) }
        }
    }

    public func setLanguage(_ language: Language) {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.rawValue))
    }

    public func start(timeOffset: TimeInterval = 0) {
        guard let recognizer, recognizer.isAvailable else {
            onText?("[语音识别不可用]", true)
            return
        }
        isRunning = true
        startDate = Date().addingTimeInterval(-timeOffset)
        accumulatedOffset = max(0, timeOffset)
        beginTask()
    }

    private func beginTask() {
        request = SFSpeechAudioBufferRecognitionRequest()
        request?.shouldReportPartialResults = true

        let segmentStartOffset = accumulatedOffset

        guard let recognizer, let request else { return }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async { self.onText?(text, result.isFinal) }
                if result.isFinal {
                    let transcription = result.bestTranscription
                    DispatchQueue.main.async {
                        self.onFinalTranscription?(transcription, segmentStartOffset)
                    }
                }
            }
            if error != nil || (result?.isFinal ?? false) {
                // 到达单次识别上限或出错，若仍在运行则自动重启接续
                self.restartIfNeeded()
            }
        }
    }

    private func restartIfNeeded() {
        task = nil
        request = nil
        guard isRunning else { return }
        // 累加已识别时长作为下一段的时间偏移
        if let startDate {
            accumulatedOffset = Date().timeIntervalSince(startDate)
        }
        beginTask()
    }

    /// 送入音频缓冲（来自采集源的音频 data output）
    public func append(_ sampleBuffer: CMSampleBuffer) {
        request?.appendAudioSampleBuffer(sampleBuffer)
    }

    /// 停止识别。调用 endAudio 让最后一段得到 final 结果（触发 onFinalTranscription），不立即 cancel。
    public func stop() {
        isRunning = false
        request?.endAudio()
        // 不调用 task?.cancel()，否则拿不到最后一段 final 结果。
        request = nil
    }
}
