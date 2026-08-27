import Foundation

/// macOS 录制可用的一个具体分辨率档位。
struct MacRecordingResolution: Equatable {
    /// 分辨率宽度，单位为像素。
    let width: Int
    /// 分辨率高度，单位为像素。
    let height: Int
    /// 参数浮窗中展示的名称。
    let displayName: String

    /// 用于本地持久化的稳定标识。
    var rawValue: String {
        switch (width, height) {
        case (1280, 720): return "720p"
        case (1920, 1080): return "1080p"
        case (3840, 2160): return "4K"
        default: return "\(width)x\(height)"
        }
    }

    /// 720p 标准分辨率档位。
    static let p720 = MacRecordingResolution(width: 1280, height: 720, displayName: "720p")
    /// 1080p 标准分辨率档位。
    static let p1080 = MacRecordingResolution(width: 1920, height: 1080, displayName: "1080p")
    /// 4K 标准分辨率档位。
    static let p4K = MacRecordingResolution(width: 3840, height: 2160, displayName: "4K")

    /// 从旧版本或新版本的本地值恢复分辨率。
    init?(rawValue: String) {
        switch rawValue {
        case "720p": self = .p720
        case "1080p": self = .p1080
        case "4K": self = .p4K
        default:
            let parts = rawValue.split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
            self.init(width: parts[0], height: parts[1], displayName: "最大（\(parts[0])×\(parts[1])）")
        }
    }

    /// 使用具体像素尺寸创建分辨率档位。
    init(width: Int, height: Int, displayName: String) {
        self.width = max(2, width)
        self.height = max(2, height)
        self.displayName = displayName
    }

    /// 根据当前录制目标的原生像素尺寸生成可用分辨率选项。
    static func options(for sourceSize: CGSize) -> [MacRecordingResolution] {
        let sourceWidth = max(2, Int(sourceSize.width.rounded()))
        let sourceHeight = max(2, Int(sourceSize.height.rounded()))
        let sourceLongEdge = max(sourceWidth, sourceHeight)
        let standardOptions = [p720, p1080, p4K].filter {
            max($0.width, $0.height) <= sourceLongEdge
        }
        let maximumOption = MacRecordingResolution(width: sourceWidth,
                                                   height: sourceHeight,
                                                   displayName: "最大（\(sourceWidth)×\(sourceHeight)）")
        var options = standardOptions
        if !options.contains(where: { $0.hasSameDimensions(as: maximumOption) }) {
            options.append(maximumOption)
        }
        return options
    }

    /// 判断两个分辨率是否具有相同的像素尺寸。
    func hasSameDimensions(as other: MacRecordingResolution) -> Bool {
        width == other.width && height == other.height
    }
}

/// macOS 录屏页面使用的分辨率与帧速率设置。
struct MacRecordingSettings: Equatable {
    /// 当前录制输出的目标分辨率。
    var resolution: MacRecordingResolution
    /// 当前录制输出的目标帧速率。
    var frameRate: CaptureFrameRate

    /// macOS 录屏页面支持的默认分辨率列表，用于无法读取显示器信息时兜底。
    static let fallbackResolutions: [MacRecordingResolution] = [.p720, .p1080, .p4K]
    /// macOS 录屏页面支持的帧速率列表。
    static let supportedFrameRates: [CaptureFrameRate] = [.fps24, .fps30, .fps60]
    /// 无法读取录制目标尺寸时使用的默认参数。
    static let `default` = MacRecordingSettings(resolution: .p1080, frameRate: .fps30)

    /// 创建一组 macOS 录制参数。
    init(resolution: MacRecordingResolution = MacRecordingSettings.default.resolution,
         frameRate: CaptureFrameRate = MacRecordingSettings.default.frameRate) {
        self.resolution = resolution
        self.frameRate = Self.supportedFrameRates.contains(frameRate) ? frameRate : Self.default.frameRate
    }

    /// 根据当前录制目标创建默认参数，默认使用设备支持的最大原生像素。
    static func defaultSettings(for sourceSize: CGSize) -> MacRecordingSettings {
        let resolutions = MacRecordingResolution.options(for: sourceSize)
        return MacRecordingSettings(resolution: resolutions.last ?? fallbackResolutions.last!,
                                    frameRate: .fps30)
    }

    /// 展示给参数入口的简短文本。
    var displayText: String {
        "\(resolution.displayName) · \(frameRate.displayName)"
    }

    /// 当前设置对应的最大输出长边像素。
    var maximumLongEdge: Int {
        max(resolution.width, resolution.height)
    }

    /// 根据输入视频尺寸计算保持比例且不放大的输出尺寸。
    func outputDimensions(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        let safeWidth = max(2, sourceWidth)
        let safeHeight = max(2, sourceHeight)
        let sourceLongEdge = max(safeWidth, safeHeight)
        let targetLongEdge = min(sourceLongEdge, maximumLongEdge)
        let scale = CGFloat(targetLongEdge) / CGFloat(sourceLongEdge)
        let width = Self.evenDimension(Int((CGFloat(safeWidth) * scale).rounded()))
        let height = Self.evenDimension(Int((CGFloat(safeHeight) * scale).rounded()))
        return (width, height)
    }

    /// 将分辨率与帧速率转换为 UserDefaults 可保存的参数。
    func persistedValues() -> (resolution: String, frameRate: Int) {
        (resolution.rawValue, frameRate.rawValue)
    }

    /// 将尺寸调整为 H.264 常用的偶数像素。
    private static func evenDimension(_ dimension: Int) -> Int {
        let safeDimension = max(2, dimension)
        return safeDimension.isMultiple(of: 2) ? safeDimension : safeDimension - 1
    }
}

/// macOS 录制参数的本地存储，保证下次进入录制页仍保留上次选择。
final class MacRecordingSettingsStore {
    /// 全局共享的参数存储实例。
    static let shared = MacRecordingSettingsStore()

    /// 保存参数的 UserDefaults 容器。
    private let defaults: UserDefaults
    /// 分辨率对应的 UserDefaults key。
    private let resolutionKey = "pinbo.mac.recording.resolution"
    /// 帧速率对应的 UserDefaults key。
    private let frameRateKey = "pinbo.mac.recording.frameRate"

    /// 使用指定的 UserDefaults 容器创建存储对象。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 读取本地参数；没有历史参数时默认使用当前录制目标的最大原生像素。
    func load(availableResolutions: [MacRecordingResolution] = MacRecordingSettings.fallbackResolutions,
              defaultSettings: MacRecordingSettings? = nil) -> MacRecordingSettings {
        let fallback = defaultSettings
            ?? MacRecordingSettings(resolution: availableResolutions.last ?? MacRecordingSettings.default.resolution,
                                    frameRate: MacRecordingSettings.default.frameRate)
        let resolution = defaults.string(forKey: resolutionKey)
            .flatMap(MacRecordingResolution.init(rawValue:))
            .flatMap { savedResolution in
                availableResolutions.first { $0.hasSameDimensions(as: savedResolution) }
            }
            ?? fallback.resolution
        let frameRate = CaptureFrameRate(rawValue: defaults.integer(forKey: frameRateKey))
            ?? fallback.frameRate
        return MacRecordingSettings(resolution: resolution, frameRate: frameRate)
    }

    /// 保存当前参数到本地。
    func save(_ settings: MacRecordingSettings) {
        let values = settings.persistedValues()
        defaults.set(values.resolution, forKey: resolutionKey)
        defaults.set(values.frameRate, forKey: frameRateKey)
    }
}
