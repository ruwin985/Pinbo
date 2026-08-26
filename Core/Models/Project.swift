import Foundation
import CoreGraphics

/// 画中画布局关键帧：记录小窗在某个时间点的位置/大小/圆角。
/// 坐标与尺寸均为归一化（0~1），保证不同导出尺寸下布局一致。
public struct PiPKeyframe: Codable, Equatable {
    /// 相对项目时间轴的时间点（秒）
    public var time: TimeInterval
    /// 中心点，归一化坐标 (0~1)
    public var center: CGPoint
    /// 尺寸，归一化 (0~1)，相对画布宽高
    public var size: CGSize
    /// 圆角（点），渲染时按比例换算
    public var cornerRadius: CGFloat

    public init(time: TimeInterval, center: CGPoint, size: CGSize, cornerRadius: CGFloat) {
        self.time = time
        self.center = center
        self.size = size
        self.cornerRadius = cornerRadius
    }
}

/// 上下分屏布局关键帧：记录某个时间点前后摄像头的上下顺序。
public struct SplitScreenKeyframe: Codable, Equatable {
    /// 相对项目时间轴的时间点（秒）
    public var time: TimeInterval
    /// 上下分屏排列顺序。
    public var order: CameraSplitOrder

    public init(time: TimeInterval, order: CameraSplitOrder) {
        self.time = time
        self.order = order
    }
}

/// 一段字幕：带精确起止时间戳，供编辑与重新渲染使用。
public struct SubtitleSegment: Codable, Equatable, Identifiable {
    public var id: UUID
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String

    public init(id: UUID = UUID(), startTime: TimeInterval, endTime: TimeInterval, text: String) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

/// 字幕在视频画布上的全局布局：中心点、最大宽度与字体缩放均为归一化数据。
public struct SubtitleLayout: Codable, Equatable {
    public var center: CGPoint
    public var maxWidth: CGFloat
    public var fontScale: CGFloat

    public init(center: CGPoint = CGPoint(x: 0.5, y: 0.82),
                maxWidth: CGFloat = 0.86,
                fontScale: CGFloat = 1) {
        self.center = center
        self.maxWidth = maxWidth
        self.fontScale = fontScale
    }
}

/// 录制项目的来源类型，用于决定默认画布该按录制视口还是源视频比例还原。
public enum RecordingSourceKind: String, Codable, Equatable {
    case camera
    case screen
}

/// 一个录制项目：非破坏性编辑的核心数据结构。
public struct RecordingProject: Codable, Equatable {
    public var id: UUID
    public var createdAt: Date
    /// 主画面视频（iOS：后摄 / macOS：录屏）
    public var mainVideoURL: URL?
    /// 画中画视频（iOS：前摄 / macOS：Mac 摄像头）
    public var pipVideoURL: URL?
    public var duration: TimeInterval
    public var pipTrack: [PiPKeyframe]
    public var splitScreenTrack: [SplitScreenKeyframe]
    public var subtitleTrack: [SubtitleSegment]
    public var subtitleLayout: SubtitleLayout
    /// 是否为草稿。
    public var isDraft: Bool
    /// 大窗/小窗比例与小窗圆角设置。
    public var aspect: AspectSettings
    /// 项目来源：手机摄像头录制按录制页视口还原；录屏按源视频比例还原。
    public var sourceKind: RecordingSourceKind
    /// 手机摄像头默认比例下，小窗关键帧归一化时使用的录制页视口尺寸。
    public var captureViewportSize: CGSize?
    /// 原始媒体资源标识，用于避免系统录屏结束回调重复导入同一条相册视频。
    public var sourceAssetIdentifier: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        mainVideoURL: URL? = nil,
        pipVideoURL: URL? = nil,
        duration: TimeInterval = 0,
        pipTrack: [PiPKeyframe] = [],
        splitScreenTrack: [SplitScreenKeyframe] = [],
        subtitleTrack: [SubtitleSegment] = [],
        subtitleLayout: SubtitleLayout = SubtitleLayout(),
        isDraft: Bool = false,
        aspect: AspectSettings = AspectSettings(),
        sourceKind: RecordingSourceKind = .screen,
        captureViewportSize: CGSize? = nil,
        sourceAssetIdentifier: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.mainVideoURL = mainVideoURL
        self.pipVideoURL = pipVideoURL
        self.duration = duration
        self.pipTrack = pipTrack
        self.splitScreenTrack = splitScreenTrack
        self.subtitleTrack = subtitleTrack
        self.subtitleLayout = subtitleLayout
        self.isDraft = isDraft
        self.aspect = aspect
        self.sourceKind = sourceKind
        self.captureViewportSize = captureViewportSize
        self.sourceAssetIdentifier = sourceAssetIdentifier
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case mainVideoURL
        case pipVideoURL
        case duration
        case pipTrack
        case splitScreenTrack
        case subtitleTrack
        case subtitleLayout
        case isDraft
        case aspect
        case sourceKind
        case captureViewportSize
        case sourceAssetIdentifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        mainVideoURL = try container.decodeIfPresent(URL.self, forKey: .mainVideoURL)
        pipVideoURL = try container.decodeIfPresent(URL.self, forKey: .pipVideoURL)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        let decodedPipTrack = try container.decode([PiPKeyframe].self, forKey: .pipTrack)
        let decodedSplitScreenTrack = try container.decodeIfPresent([SplitScreenKeyframe].self, forKey: .splitScreenTrack) ?? []
        pipTrack = decodedPipTrack
        splitScreenTrack = decodedSplitScreenTrack
        subtitleTrack = try container.decode([SubtitleSegment].self, forKey: .subtitleTrack)
        subtitleLayout = try container.decodeIfPresent(SubtitleLayout.self, forKey: .subtitleLayout) ?? SubtitleLayout()
        isDraft = try container.decode(Bool.self, forKey: .isDraft)
        let decodedAspect = try container.decodeIfPresent(AspectSettings.self, forKey: .aspect) ?? AspectSettings()
        aspect = decodedAspect
        sourceKind = try container.decodeIfPresent(RecordingSourceKind.self, forKey: .sourceKind)
            ?? Self.inferSourceKind(aspect: decodedAspect,
                                    pipVideoURL: pipVideoURL,
                                    pipTrack: decodedPipTrack,
                                    splitScreenTrack: decodedSplitScreenTrack)
        captureViewportSize = try container.decodeIfPresent(CGSize.self, forKey: .captureViewportSize)
        sourceAssetIdentifier = try container.decodeIfPresent(String.self, forKey: .sourceAssetIdentifier)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(mainVideoURL, forKey: .mainVideoURL)
        try container.encodeIfPresent(pipVideoURL, forKey: .pipVideoURL)
        try container.encode(duration, forKey: .duration)
        try container.encode(pipTrack, forKey: .pipTrack)
        try container.encode(splitScreenTrack, forKey: .splitScreenTrack)
        try container.encode(subtitleTrack, forKey: .subtitleTrack)
        try container.encode(subtitleLayout, forKey: .subtitleLayout)
        try container.encode(isDraft, forKey: .isDraft)
        try container.encode(aspect, forKey: .aspect)
        try container.encode(sourceKind, forKey: .sourceKind)
        try container.encodeIfPresent(captureViewportSize, forKey: .captureViewportSize)
        try container.encodeIfPresent(sourceAssetIdentifier, forKey: .sourceAssetIdentifier)
    }

    private static func inferSourceKind(aspect: AspectSettings,
                                        pipVideoURL: URL?,
                                        pipTrack: [PiPKeyframe],
                                        splitScreenTrack: [SplitScreenKeyframe]) -> RecordingSourceKind {
        if aspect.isSplitScreenEnabled || !splitScreenTrack.isEmpty {
            return .camera
        }
        if aspect.recordsSecondaryVideo || pipVideoURL != nil || !pipTrack.isEmpty {
            return .camera
        }
        return .screen
    }
}
