import Foundation
import NaturalLanguage
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

    /// 从累计识别文本中提取当前应该显示的一句话，并限制最大显示字符数。
    public static func currentDisplaySentence(from text: String, maxCharacters: Int = 36) -> String {
        var currentSentence = ""
        var latestCompletedSentence = ""
        for character in text {
            currentSentence.append(character)
            if sentenceEndChars.contains(character) {
                latestCompletedSentence = currentSentence
                currentSentence = ""
            }
        }

        let preferredSentence = currentSentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? latestCompletedSentence
            : currentSentence
        let trimmedSentence = preferredSentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSentence.count > maxCharacters else { return trimmedSentence }
        return String(trimmedSentence.suffix(maxCharacters))
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

/// 从当前字幕中挑选适合强调显示的重点词语范围。
public enum SubtitleEmphasisDetector {

    /// 中文口语中不适合作为重点词展示的高频虚词。
    private static let chineseStopWords: Set<String> = [
        "一个", "一些", "这个", "那个", "这些", "那些", "我们", "你们", "他们", "它们",
        "就是", "还是", "可以", "可能", "然后", "因为", "所以", "但是", "如果", "已经",
        "正在", "进行", "需要", "觉得", "其实", "比较", "非常", "特别", "这里", "那里"
    ]

    /// 英文口语中不适合作为重点词展示的高频虚词。
    private static let englishStopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from", "has",
        "have", "he", "her", "his", "i", "if", "in", "is", "it", "its", "me", "my",
        "of", "on", "or", "our", "she", "so", "that", "the", "their", "them", "they",
        "this", "to", "was", "we", "were", "will", "with", "you", "your"
    ]

    /// 返回字幕中最多三个重点词范围，范围以 UTF-16 为基准，可直接用于富文本属性。
    public static func ranges(in text: String) -> [NSRange] {
        let fullRange = text.startIndex..<text.endIndex
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        var scores: [NSRange: Int] = [:]
        collectPatternCandidates(in: text, scores: &scores)
        collectLinguisticCandidates(in: text, range: fullRange, scores: &scores)
        collectNameCandidates(in: text, range: fullRange, scores: &scores)

        let maximumCount: Int
        switch text.count {
        case ...10: maximumCount = 1
        case ...24: maximumCount = 2
        default: maximumCount = 3
        }

        let ranked = scores.sorted { left, right in
            if left.value == right.value {
                if left.key.length == right.key.length {
                    return left.key.location < right.key.location
                }
                return left.key.length > right.key.length
            }
            return left.value > right.value
        }

        var selected: [NSRange] = []
        for candidate in ranked {
            guard !selected.contains(where: { NSIntersectionRange($0, candidate.key).length > 0 }) else { continue }
            selected.append(candidate.key)
            if selected.count == maximumCount { break }
        }
        return selected.sorted { $0.location < $1.location }
    }

    /// 收集数字、百分比、话题词和较长英文词等天然重点内容。
    private static func collectPatternCandidates(in text: String, scores: inout [NSRange: Int]) {
        let pattern = #"(?:[#@][\p{L}\p{N}_]+)|(?:\d+(?:[.,]\d+)?(?:%|[A-Za-z]+)?)|(?:[A-Za-z][A-Za-z0-9_-]{2,})"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        expression.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let range = match?.range else { return }
            let token = (text as NSString).substring(with: range)
            let patternScore: Int
            if token.hasPrefix("#") || token.hasPrefix("@") {
                patternScore = 110
            } else if token.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) {
                patternScore = 95
            } else if range.location > 0, token.first?.isUppercase == true {
                patternScore = 72
            } else {
                patternScore = 24
            }
            scores[range] = max(scores[range] ?? 0, patternScore + min(range.length, 12))
        }
    }

    /// 使用系统自然语言词性分析收集名词、动词、形容词、数字和成语候选。
    private static func collectLinguisticCandidates(in text: String,
                                                    range: Range<String.Index>,
                                                    scores: inout [NSRange: Int]) {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        if let language = NLLanguageRecognizer.dominantLanguage(for: text) {
            tagger.setLanguage(language, range: range)
        }
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation]
        tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass, options: options) { tag, tokenRange in
            let token = String(text[tokenRange])
            guard isMeaningful(token) else { return true }
            guard let baseScore = score(for: tag) else { return true }
            let nsRange = NSRange(tokenRange, in: text)
            scores[nsRange] = max(scores[nsRange] ?? 0, baseScore + min(token.count, 8))
            return true
        }
    }

    /// 使用系统实体识别提高人名、地名和组织名称的强调优先级。
    private static func collectNameCandidates(in text: String,
                                              range: Range<String.Index>,
                                              scores: inout [NSRange: Int]) {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        if let language = NLLanguageRecognizer.dominantLanguage(for: text) {
            tagger.setLanguage(language, range: range)
        }
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(in: range, unit: .word, scheme: .nameType, options: options) { tag, tokenRange in
            guard tag == .personalName || tag == .placeName || tag == .organizationName else { return true }
            let nsRange = NSRange(tokenRange, in: text)
            scores[nsRange] = max(scores[nsRange] ?? 0, 120 + min(nsRange.length, 16))
            return true
        }
    }

    /// 判断候选词是否包含有效内容，并过滤常见中英文虚词。
    private static func isMeaningful(_ token: String) -> Bool {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty,
              !chineseStopWords.contains(normalized),
              !englishStopWords.contains(normalized) else { return false }
        return normalized.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// 根据词性返回强调优先级，分值越高越优先显示。
    private static func score(for tag: NLTag?) -> Int? {
        switch tag {
        case .number: return 85
        case .idiom: return 72
        case .noun: return 58
        case .adjective: return 48
        case .verb: return 42
        case .otherWord: return 28
        default: return nil
        }
    }
}
