import Foundation
import CoreGraphics

/// 统一比例枚举，主/副视频通用。
/// `.default` 表示"默认/铺满"：不裁剪，主画面用全屏、小窗用源比例。
public enum AspectRatio: String, Codable, CaseIterable {
    case `default` = "默认"
    case r1x1 = "1:1"
    case r3x4 = "3:4"
    case r4x3 = "4:3"
    case r9x16 = "9:16"
    case r16x9 = "16:9"

    /// 是否为"默认/铺满"（不裁剪）。
    public var isDefault: Bool { self == .default }

    /// 宽高比（宽/高）。`.default` 返回 0 作为哨兵（表示铺满/源比例）。
    public var ratio: CGFloat {
        switch self {
        case .default: return 0
        case .r1x1: return 1.0
        case .r3x4: return 3.0 / 4.0
        case .r4x3: return 4.0 / 3.0
        case .r9x16: return 9.0 / 16.0
        case .r16x9: return 16.0 / 9.0
        }
    }

    /// 给定宽度求高度（`.default` 用小窗默认竖向比例兜底）。
    public func height(forWidth w: CGFloat) -> CGFloat {
        return defaultSize(forWidth: w).height
    }

    /// 给定宽度求默认显示尺寸（小窗 `.default` 使用当前默认竖向尺寸）。
    public func defaultSize(forWidth w: CGFloat) -> CGSize {
        let r = isDefault ? (110.0 / 150.0) : ratio
        return CGSize(width: w, height: w / r)
    }

    /// 导出画布尺寸（长边 1920）。`.default` 用竖屏 9:16 全屏。
    public func canvasSize(longEdge: CGFloat = 1920) -> CGSize {
        let r = isDefault ? (9.0 / 16.0) : ratio
        if r >= 1 {
            return CGSize(width: longEdge, height: (longEdge / r).rounded())
        } else {
            return CGSize(width: (longEdge * r).rounded(), height: longEdge)
        }
    }
}

/// 画中画小窗外观设置（比例 + 圆角）。
public struct PiPStyle: Codable, Equatable {
    public var aspect: AspectRatio
    /// 圆角比例 0~1，1 表示最大圆角（正方形时为圆形）。
    public var cornerRatio: CGFloat

    public init(aspect: AspectRatio = .default, cornerRatio: CGFloat = 0.12) {
        self.aspect = aspect
        self.cornerRatio = cornerRatio
    }
}

/// 上下分屏时前后摄像头的排列顺序。
public enum CameraSplitOrder: String, Codable, Equatable {
    case frontTop
    case backTop

    public mutating func toggle() {
        self = self == .frontTop ? .backTop : .frontTop
    }
}

/// 大窗 + 小窗的比例设置集合。
public struct AspectSettings: Codable, Equatable {
    public var main: AspectRatio
    public var isPiPEnabled: Bool
    public var isSplitScreenEnabled: Bool
    public var splitOrder: CameraSplitOrder
    public var pip: PiPStyle

    public var recordsSecondaryVideo: Bool {
        isPiPEnabled || isSplitScreenEnabled
    }

    public init(main: AspectRatio = .default,
                isPiPEnabled: Bool = true,
                isSplitScreenEnabled: Bool = false,
                splitOrder: CameraSplitOrder = .frontTop,
                pip: PiPStyle = PiPStyle()) {
        self.main = main
        self.isSplitScreenEnabled = isSplitScreenEnabled
        self.isPiPEnabled = isSplitScreenEnabled ? false : isPiPEnabled
        self.splitOrder = splitOrder
        self.pip = pip
    }

    private enum CodingKeys: String, CodingKey {
        case main
        case isPiPEnabled
        case isSplitScreenEnabled
        case splitOrder
        case pip
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        main = try container.decodeIfPresent(AspectRatio.self, forKey: .main) ?? .default
        let decodedSplitScreen = try container.decodeIfPresent(Bool.self, forKey: .isSplitScreenEnabled) ?? false
        isSplitScreenEnabled = decodedSplitScreen
        isPiPEnabled = decodedSplitScreen ? false : (try container.decodeIfPresent(Bool.self, forKey: .isPiPEnabled) ?? true)
        splitOrder = try container.decodeIfPresent(CameraSplitOrder.self, forKey: .splitOrder) ?? .frontTop
        pip = try container.decodeIfPresent(PiPStyle.self, forKey: .pip) ?? PiPStyle()
    }
}
