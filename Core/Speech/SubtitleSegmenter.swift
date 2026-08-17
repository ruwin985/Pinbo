import Foundation
import Speech

/// 把语音识别结果按句子断句，拆成与视频时长一一对应的字幕分段。
public enum SubtitleSegmenter {

    /// 中英文句末断句标点集合。
    private static let sentenceEndChars: Set<Character> = [
        "。", "！", "？", "…",
        ".", "!", "?"
    ]

    private static let sentencePauseThreshold: TimeInterval = 0.55
    private static let maxSentenceDuration: TimeInterval = 3.2
    private static let maxSentenceChars = 22

    /// 从 SFTranscription 逐词时间戳生成句子级分段。
    /// 每个 `SFTranscriptionSegment` 带 `timestamp` 与 `duration`（相对录音起点，单位秒）。
    public static func segments(from transcription: SFTranscription,
                                timeOffset: TimeInterval = 0) -> [SubtitleSegment] {
        let words = transcription.segments
        guard !words.isEmpty else { return [] }

        var result: [SubtitleSegment] = []
        var buffer = ""
        var segStart: TimeInterval = words.first!.timestamp + timeOffset
        var segEnd: TimeInterval = segStart

        func flush() {
            let text = buffer.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { buffer = ""; return }
            result.append(SubtitleSegment(startTime: segStart,
                                          endTime: max(segEnd, segStart + 0.3),
                                          text: text))
            buffer = ""
        }

        for (i, word) in words.enumerated() {
            if buffer.isEmpty {
                segStart = word.timestamp + timeOffset
            }
            let sub = word.substring
            // 中文词间不加空格；英文/数字词间加空格。
            if shouldInsertSpace(between: buffer.last, and: sub.first) {
                buffer += " "
            }
            buffer += sub
            segEnd = word.timestamp + word.duration + timeOffset

            let endsWithSentence = sub.last.map { sentenceEndChars.contains($0) } ?? false
            let isLast = i == words.count - 1
            let hasSentencePause: Bool
            if !isLast {
                let nextStart = words[i + 1].timestamp + timeOffset
                hasSentencePause = nextStart - segEnd >= sentencePauseThreshold
            } else {
                hasSentencePause = false
            }
            let tooLongWithoutPunctuation = segEnd - segStart >= maxSentenceDuration || buffer.count >= maxSentenceChars
            if endsWithSentence || hasSentencePause || tooLongWithoutPunctuation || isLast {
                flush()
            }
        }
        return result
    }

    /// 当没有逐词时间戳时的兜底：按句末标点把整段文本切分，并按字符比例平均分配时间。
    public static func segments(fromText text: String,
                                totalDuration: TimeInterval) -> [SubtitleSegment] {
        let pieces = splitBySentenceEnd(text)
        guard !pieces.isEmpty, totalDuration > 0 else {
            return text.isEmpty ? [] : [SubtitleSegment(startTime: 0, endTime: totalDuration, text: text)]
        }
        let totalChars = max(pieces.reduce(0) { $0 + $1.count }, 1)
        var cursor: TimeInterval = 0
        var result: [SubtitleSegment] = []
        for piece in pieces {
            let ratio = Double(piece.count) / Double(totalChars)
            let dur = totalDuration * ratio
            result.append(SubtitleSegment(startTime: cursor,
                                          endTime: cursor + dur,
                                          text: piece))
            cursor += dur
        }
        return result
    }

    /// 兜底清理已有字幕：若旧项目里一整段文字被塞进同一个字幕段，按文本重新拆成多个时间段。
    public static func normalized(_ segments: [SubtitleSegment]) -> [SubtitleSegment] {
        segments.sorted { $0.startTime < $1.startTime }.flatMap { segment in
            let duration = max(0, segment.endTime - segment.startTime)
            let pieces = Self.segments(fromText: segment.text, totalDuration: duration)
            guard pieces.count > 1 else { return [segment] }
            return pieces.map { piece in
                SubtitleSegment(startTime: segment.startTime + piece.startTime,
                                endTime: segment.startTime + piece.endTime,
                                text: piece.text)
            }
        }
    }

    private static func splitBySentenceEnd(_ text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if sentenceEndChars.contains(ch) || current.count >= maxSentenceChars {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { pieces.append(trimmed) }
                current = ""
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { pieces.append(trimmed) }
        return pieces
    }

    private static func shouldInsertSpace(between previous: Character?, and next: Character?) -> Bool {
        guard let previous, let next else { return false }
        return isASCIIAlphanumeric(previous) && isASCIIAlphanumeric(next)
    }

    private static func isASCIIAlphanumeric(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else { return false }
        return scalar.value < 128 && CharacterSet.alphanumerics.contains(scalar)
    }
}
