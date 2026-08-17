import Foundation
import AVFoundation
import CoreImage
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

struct VideoTrackTransform {
    let orientation: CGImagePropertyOrientation?

    init(track: AVAssetTrack) {
        orientation = Self.orientation(for: track.preferredTransform)
    }

    private static func orientation(for transform: CGAffineTransform) -> CGImagePropertyOrientation? {
        let a = rounded(transform.a)
        let b = rounded(transform.b)
        let c = rounded(transform.c)
        let d = rounded(transform.d)

        switch (a, b, c, d) {
        case (1, 0, 0, 1): return .up
        case (-1, 0, 0, -1): return .down
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, 1): return .upMirrored
        case (1, 0, 0, -1): return .downMirrored
        case (0, 1, 1, 0): return .leftMirrored
        case (0, -1, -1, 0): return .rightMirrored
        default: return nil
        }
    }

    private static func rounded(_ value: CGFloat) -> Int {
        return Int(value.rounded())
    }
}

private struct SubtitleRenderKey: Hashable {
    let text: String
    let canvasWidth: Int
    let canvasHeight: Int
    let centerX: Int
    let centerY: Int
    let maxWidth: Int
    let fontScale: Int
}

/// 自定义合成指令：携带主/画中画轨道 ID 及布局参数（每个 instruction 自带参数，避免全局状态）。
final class PiPCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    var timeRange: CMTimeRange
    var enablePostProcessing: Bool = false
    var containsTweening: Bool = true
    var requiredSourceTrackIDs: [NSValue]?
    var passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let mainTrackID: CMPersistentTrackID
    let pipTrackID: CMPersistentTrackID?

    var canvas: CGSize = CGSize(width: 1080, height: 1920)
    var pipKeyframes: [PiPKeyframe] = []
    var pipAspect: AspectRatio = .default
    var pipCornerRatio: CGFloat = 0.12
    var totalDuration: Double = 0
    var subtitles: [SubtitleSegment] = []
    var subtitleLayout: SubtitleLayout = SubtitleLayout()
    // 各轨道方向信息（把帧摆正）
    var mainTransform: VideoTrackTransform?
    var pipTransform: VideoTrackTransform?

    init(timeRange: CMTimeRange, mainTrackID: CMPersistentTrackID, pipTrackID: CMPersistentTrackID?) {
        self.timeRange = timeRange
        self.mainTrackID = mainTrackID
        self.pipTrackID = pipTrackID
        var ids: [NSValue] = [NSNumber(value: mainTrackID)]
        if let pip = pipTrackID { ids.append(NSNumber(value: pip)) }
        self.requiredSourceTrackIDs = ids
        super.init()
    }
}

/// 自定义视频合成器（CoreImage + Metal）：主画面 aspectFill + 画中画（关键帧移动、圆角/圆形）+ 字幕。
/// 复用单个 Metal-backed CIContext，性能良好；不使用 postProcessingAsVideoLayers（避免其不稳定性）。
final class PiPVideoCompositor: NSObject, AVVideoCompositing {

    private let ciContext: CIContext = {
        if let dev = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: dev)
        }
        return CIContext()
    }()
    private let renderQueue = DispatchQueue(label: "com.pinbo.compositor.render")
    private var subtitleCache: [SubtitleRenderKey: CIImage] = [:]
    private var renderedFrameCount = 0

    var sourcePixelBufferAttributes: [String: Any]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: Any] {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderQueue.async {
            self.subtitleCache.removeAll()
            self.renderedFrameCount = 0
            self.ciContext.clearCaches()
        }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async {
            guard let instruction = request.videoCompositionInstruction as? PiPCompositionInstruction,
                  let dst = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "Pinbo", code: -20)); return
            }
            autoreleasepool {
                self.render(request: request, instruction: instruction, dst: dst)
            }
        }
    }

    private func render(request: AVAsynchronousVideoCompositionRequest,
                        instruction: PiPCompositionInstruction,
                        dst: CVPixelBuffer) {
            let canvas = instruction.canvas
            let time = request.compositionTime.seconds

            var output = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: canvas))

            // 主画面 aspectFill（先按方向摆正）
            if let mainBuf = request.sourceFrame(byTrackID: instruction.mainTrackID) {
                var mainImg = CIImage(cvPixelBuffer: mainBuf)
                mainImg = self.oriented(mainImg, transform: instruction.mainTransform)
                let main = self.aspectFill(mainImg, into: canvas)
                output = main.composited(over: output)
            }

            // 画中画：定位到当前关键帧 + 圆角
            if let pipID = instruction.pipTrackID,
               let pipBuf = request.sourceFrame(byTrackID: pipID),
               let kf = self.keyframe(at: time, keyframes: instruction.pipKeyframes) {
                let frame = self.pipFrame(for: kf, aspect: instruction.pipAspect, in: canvas)
                var pipImg = CIImage(cvPixelBuffer: pipBuf)
                pipImg = self.oriented(pipImg, transform: instruction.pipTransform)
                var pip = self.aspectFill(pipImg, into: frame.size)
                pip = self.roundedMask(pip, size: frame.size, cornerRatio: instruction.pipCornerRatio)
                // CoreImage 原点左下，需翻转 y
                let ty = canvas.height - frame.origin.y - frame.size.height
                pip = pip.transformed(by: CGAffineTransform(translationX: frame.origin.x, y: ty))
                output = pip.composited(over: output)
            }

            // 字幕
            if let seg = instruction.subtitles.first(where: { time >= $0.startTime && time <= $0.endTime }),
               !seg.text.isEmpty,
               let text = self.renderSubtitle(seg.text, layout: instruction.subtitleLayout, canvas: canvas) {
                output = text.composited(over: output)
            }

            self.ciContext.render(output, to: dst)
            renderedFrameCount += 1
            if renderedFrameCount.isMultiple(of: 24) {
                self.ciContext.clearCaches()
            }
            request.finish(withComposedVideoFrame: dst)
    }

    // MARK: - Helpers

    private func keyframe(at time: Double, keyframes: [PiPKeyframe]) -> PiPKeyframe? {
        let sorted = keyframes.sorted { $0.time < $1.time }
        guard !sorted.isEmpty else { return nil }
        var chosen = sorted[0]
        for kf in sorted where kf.time <= time { chosen = kf }
        return chosen
    }

    /// 按轨道 preferredTransform 对应的 EXIF 方向把帧摆正。
    private func oriented(_ image: CIImage, transform: VideoTrackTransform?) -> CIImage {
        guard let orientation = transform?.orientation else { return image }
        return image.oriented(orientation)
    }

    private func pipFrame(for kf: PiPKeyframe, aspect: AspectRatio, in size: CGSize) -> CGRect {
        let w = kf.size.width * size.width
        let h = aspect.isDefault ? kf.size.height * size.height : w / aspect.ratio
        return CGRect(x: kf.center.x * size.width - w / 2,
                      y: kf.center.y * size.height - h / 2, width: w, height: h)
    }

    private func aspectFill(_ image: CIImage, into size: CGSize) -> CIImage {
        let ext = image.extent
        guard ext.width > 0, ext.height > 0 else { return image }
        let scale = max(size.width / ext.width, size.height / ext.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let sExt = scaled.extent
        let tx = (size.width - sExt.width) / 2 - sExt.origin.x
        let ty = (size.height - sExt.height) / 2 - sExt.origin.y
        return scaled.transformed(by: CGAffineTransform(translationX: tx, y: ty))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    private func roundedMask(_ image: CIImage, size: CGSize, cornerRatio: CGFloat) -> CIImage {
        let radius = min(size.width, size.height) / 2 * max(0, min(cornerRatio, 1))
        guard radius > 0.5, let rounded = CIFilter(name: "CIRoundedRectangleGenerator") else { return image }
        rounded.setValue(CIVector(cgRect: CGRect(origin: .zero, size: size)), forKey: "inputExtent")
        rounded.setValue(radius, forKey: "inputRadius")
        rounded.setValue(CIColor.white, forKey: "inputColor")
        guard let mask = rounded.outputImage,
              let blend = CIFilter(name: "CIBlendWithAlphaMask") else { return image }
        let clear = CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: size))
        blend.setValue(image, forKey: kCIInputImageKey)
        blend.setValue(clear, forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: kCIInputMaskImageKey)
        return blend.outputImage ?? image
    }

    private func renderSubtitle(_ text: String, layout: SubtitleLayout, canvas: CGSize) -> CIImage? {
        #if canImport(UIKit)
        let normalized = normalizedSubtitleLayout(layout)
        let key = SubtitleRenderKey(text: text,
                                    canvasWidth: Int(canvas.width.rounded()),
                                    canvasHeight: Int(canvas.height.rounded()),
                                    centerX: Int((normalized.center.x * 10_000).rounded()),
                                    centerY: Int((normalized.center.y * 10_000).rounded()),
                                    maxWidth: Int((normalized.maxWidth * 10_000).rounded()),
                                    fontScale: Int((normalized.fontScale * 10_000).rounded()))
        if let cached = subtitleCache[key] { return cached }

        let inset = max(24, canvas.width * 0.04)
        let maxWidth = min(normalized.maxWidth * canvas.width, canvas.width - inset * 2)
        let font = UIFont.systemFont(ofSize: max(28, min(canvas.width, canvas.height) * 0.06 * normalized.fontScale), weight: .bold)
        let padding = max(8, font.pointSize * 0.2)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        let measureAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: para
        ]
        let strokeAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
            .strokeColor: UIColor.black,
            .strokeWidth: 5.0,
            .paragraphStyle: para
        ]
        let fillAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
            .paragraphStyle: para
        ]
        let textWidth = maxWidth - padding * 2
        let maxTextHeight = ceil(font.lineHeight * 3)
        let fitting = (text as NSString).boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                                                      options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                      attributes: measureAttrs,
                                                      context: nil)
        let textHeight = min(maxTextHeight, max(ceil(font.lineHeight), ceil(fitting.height)))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: maxWidth, height: textHeight + padding * 2),
                                               format: format)
        let img = renderer.image { ctx in
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: UIColor.black.cgColor)
            (text as NSString).draw(in: CGRect(x: padding,
                                               y: padding,
                                               width: textWidth,
                                               height: textHeight),
                                    withAttributes: strokeAttrs)
            (text as NSString).draw(in: CGRect(x: padding,
                                               y: padding,
                                               width: textWidth,
                                               height: textHeight),
                                    withAttributes: fillAttrs)
        }
        guard let ci = CIImage(image: img) else { return nil }
        let frame = subtitleFrame(size: img.size, layout: normalized, canvas: canvas)
        let y = canvas.height - frame.origin.y - frame.height
        let rendered = ci.transformed(by: CGAffineTransform(translationX: frame.origin.x, y: y))
        subtitleCache[key] = rendered
        return rendered
        #else
        return nil
        #endif
    }

    private func normalizedSubtitleLayout(_ layout: SubtitleLayout) -> SubtitleLayout {
        SubtitleLayout(center: CGPoint(x: min(max(layout.center.x, 0), 1),
                                       y: min(max(layout.center.y, 0), 1)),
                       maxWidth: min(max(layout.maxWidth, 0.45), 0.94),
                       fontScale: min(max(layout.fontScale, 0.65), 2.2))
    }

    private func subtitleFrame(size: CGSize, layout: SubtitleLayout, canvas: CGSize) -> CGRect {
        let inset = max(24, canvas.width * 0.04)
        let width = min(size.width, canvas.width - inset * 2)
        let height = min(size.height, canvas.height - inset * 2)
        var origin = CGPoint(x: layout.center.x * canvas.width - width / 2,
                             y: layout.center.y * canvas.height - height / 2)
        origin.x = min(max(origin.x, inset), canvas.width - inset - width)
        origin.y = min(max(origin.y, inset), canvas.height - inset - height)
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }
}
