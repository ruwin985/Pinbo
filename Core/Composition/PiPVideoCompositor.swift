import Foundation
import AVFoundation
import CoreImage
import CoreText
import ImageIO

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
    var fitsMainContent: Bool = false
    var isSplitScreenEnabled: Bool = false
    var splitScreenOrder: CameraSplitOrder = .frontTop
    var splitScreenTopRatio: CGFloat = 0.5
    var splitScreenKeyframes: [SplitScreenKeyframe] = []
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

/// 自定义视频合成器（CoreImage + Metal）：主画面适配比例 + 画中画（关键帧移动、圆角/圆形）+ 字幕。
/// 复用单个 Metal-backed CIContext，性能良好；不使用 postProcessingAsVideoLayers（避免其不稳定性）。
final class PiPVideoCompositor: NSObject, AVVideoCompositing {

    private let ciContext: CIContext = {
        let options: [CIContextOption: Any] = [.cacheIntermediates: false]
        if let dev = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: dev, options: options)
        }
        return CIContext(options: options)
    }()
    private let renderQueue = DispatchQueue(label: "com.pinbo.compositor.render")
    private var subtitleCache: [SubtitleRenderKey: CIImage] = [:]
    private var renderedFrameCount = 0

    var sourcePixelBufferAttributes: [String: Any]? {
        [
            kCVPixelBufferPixelFormatTypeKey as String: [
                NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
                NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                NSNumber(value: kCVPixelFormatType_32BGRA),
            ],
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
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

            if instruction.isSplitScreenEnabled {
                let layout = self.splitScreenLayout(at: time,
                                                    keyframes: instruction.splitScreenKeyframes,
                                                    fallbackOrder: instruction.splitScreenOrder,
                                                    fallbackTopRatio: instruction.splitScreenTopRatio)
                let frames = self.splitFrames(for: layout.order, topRatio: layout.topRatio, in: canvas)
                if let mainBuf = request.sourceFrame(byTrackID: instruction.mainTrackID) {
                    var mainImg = CIImage(cvPixelBuffer: mainBuf)
                    mainImg = self.oriented(mainImg, transform: instruction.mainTransform)
                    output = self.place(mainImg, in: frames.back, canvas: canvas).composited(over: output)
                }
                if let pipID = instruction.pipTrackID,
                   let pipBuf = request.sourceFrame(byTrackID: pipID) {
                    var pipImg = CIImage(cvPixelBuffer: pipBuf)
                    pipImg = self.oriented(pipImg, transform: instruction.pipTransform)
                    output = self.place(pipImg, in: frames.front, canvas: canvas).composited(over: output)
                }
            } else {
                if let mainBuf = request.sourceFrame(byTrackID: instruction.mainTrackID) {
                    var mainImg = CIImage(cvPixelBuffer: mainBuf)
                    mainImg = self.oriented(mainImg, transform: instruction.mainTransform)
                    let main = instruction.fitsMainContent
                        ? self.aspectFit(mainImg, into: canvas)
                        : self.aspectFill(mainImg, into: canvas)
                    output = main.composited(over: output)
                }

                if let pipID = instruction.pipTrackID,
                   let pipBuf = request.sourceFrame(byTrackID: pipID),
                   let kf = self.keyframe(at: time, keyframes: instruction.pipKeyframes) {
                    let frame = self.pipFrame(for: kf, aspect: instruction.pipAspect, in: canvas)
                    var pipImg = CIImage(cvPixelBuffer: pipBuf)
                    pipImg = self.oriented(pipImg, transform: instruction.pipTransform)
                    var pip = self.aspectFill(pipImg, into: frame.size)
                    pip = self.roundedMask(pip, size: frame.size, cornerRatio: instruction.pipCornerRatio)
                    let ty = canvas.height - frame.origin.y - frame.size.height
                    pip = pip.transformed(by: CGAffineTransform(translationX: frame.origin.x, y: ty))
                    output = pip.composited(over: output)
                }
            }

            // 字幕
            if let seg = instruction.subtitles.first(where: { time >= $0.startTime && time <= $0.endTime }),
               !seg.text.isEmpty,
               let text = self.renderSubtitle(seg.text, layout: instruction.subtitleLayout, canvas: canvas) {
                output = text.composited(over: output)
            }

            self.ciContext.render(output, to: dst)
            renderedFrameCount += 1
            if renderedFrameCount.isMultiple(of: 8) {
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

    /// 获取指定时间点应该使用的上下分屏布局。
    private func splitScreenLayout(at time: Double,
                                   keyframes: [SplitScreenKeyframe],
                                   fallbackOrder: CameraSplitOrder,
                                   fallbackTopRatio: CGFloat) -> SplitScreenKeyframe {
        let sorted = keyframes.sorted { $0.time < $1.time }
        guard !sorted.isEmpty else {
            return SplitScreenKeyframe(time: time, order: fallbackOrder, topRatio: fallbackTopRatio)
        }
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

    /// 根据上半部分占比计算前后摄像头在画布上的区域。
    private func splitFrames(for order: CameraSplitOrder,
                             topRatio: CGFloat,
                             in size: CGSize) -> (front: CGRect, back: CGRect) {
        let topHeight = size.height * AspectSettings.clampedSplitTopRatio(topRatio)
        let top = CGRect(x: 0, y: 0, width: size.width, height: topHeight)
        let bottom = CGRect(x: 0, y: topHeight, width: size.width, height: size.height - topHeight)
        return order == .frontTop ? (front: top, back: bottom) : (front: bottom, back: top)
    }

    /// 将指定画面按填充方式放置到目标区域。
    private func place(_ image: CIImage, in frame: CGRect, canvas: CGSize) -> CIImage {
        let fitted = aspectFill(image, into: frame.size)
        let y = canvas.height - frame.origin.y - frame.height
        return fitted.transformed(by: CGAffineTransform(translationX: frame.origin.x, y: y))
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

    private func aspectFit(_ image: CIImage, into size: CGSize) -> CIImage {
        let ext = image.extent
        guard ext.width > 0, ext.height > 0 else { return image }
        let scale = min(size.width / ext.width, size.height / ext.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let sExt = scaled.extent
        let tx = (size.width - sExt.width) / 2 - sExt.origin.x
        let ty = (size.height - sExt.height) / 2 - sExt.origin.y
        return scaled.transformed(by: CGAffineTransform(translationX: tx, y: ty))
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
        let fontSize = max(28, min(canvas.width, canvas.height) * 0.06 * normalized.fontScale)
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        let padding = max(8, fontSize * 0.2)
        let textWidth = max(1, maxWidth - padding * 2)
        let paragraph = makeSubtitleParagraphStyle()
        let measureText = makeSubtitleString(text, font: font, paragraph: paragraph, strokeOnly: false)
        let framesetter = CTFramesetterCreateWithAttributedString(measureText)
        let fitting = CTFramesetterSuggestFrameSizeWithConstraints(framesetter,
                                                                   CFRange(location: 0, length: measureText.length),
                                                                   nil,
                                                                   CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                                                                   nil)
        let lineHeight = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
        let textHeight = min(ceil(lineHeight * 3), max(lineHeight, ceil(fitting.height)))
        let renderSize = CGSize(width: ceil(maxWidth), height: ceil(textHeight + padding * 2))

        guard let image = renderSubtitleImage(text,
                                              font: font,
                                              paragraph: paragraph,
                                              textRect: CGRect(x: padding, y: padding, width: textWidth, height: textHeight),
                                              size: renderSize) else { return nil }
        let ci = CIImage(cgImage: image)
        let frame = subtitleFrame(size: renderSize, layout: normalized, canvas: canvas)
        let y = canvas.height - frame.origin.y - frame.height
        let rendered = ci.transformed(by: CGAffineTransform(translationX: frame.origin.x, y: y))
        subtitleCache[key] = rendered
        return rendered
    }

    private func makeSubtitleParagraphStyle() -> CTParagraphStyle {
        var alignment = CTTextAlignment.center
        var lineBreak = CTLineBreakMode.byWordWrapping
        return withUnsafePointer(to: &alignment) { alignmentPointer in
            withUnsafePointer(to: &lineBreak) { lineBreakPointer in
                var settings = [
                    CTParagraphStyleSetting(spec: .alignment,
                                            valueSize: MemoryLayout<CTTextAlignment>.size,
                                            value: alignmentPointer),
                    CTParagraphStyleSetting(spec: .lineBreakMode,
                                            valueSize: MemoryLayout<CTLineBreakMode>.size,
                                            value: lineBreakPointer)
                ]
                return CTParagraphStyleCreate(&settings, settings.count)
            }
        }
    }

    private func makeSubtitleString(_ text: String,
                                    font: CTFont,
                                    paragraph: CTParagraphStyle,
                                    strokeOnly: Bool) -> NSAttributedString {
        let strokeColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        let fillColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        var attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTParagraphStyleAttributeName as NSAttributedString.Key: paragraph,
            kCTForegroundColorAttributeName as NSAttributedString.Key: fillColor
        ]
        if strokeOnly {
            attributes[kCTStrokeColorAttributeName as NSAttributedString.Key] = strokeColor
            attributes[kCTStrokeWidthAttributeName as NSAttributedString.Key] = 5.0
        }
        return NSAttributedString(string: text, attributes: attributes)
    }

    private func renderSubtitleImage(_ text: String,
                                     font: CTFont,
                                     paragraph: CTParagraphStyle,
                                     textRect: CGRect,
                                     size: CGSize) -> CGImage? {
        let width = max(1, Int(size.width.rounded(.up)))
        let height = max(1, Int(size.height.rounded(.up)))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        context.clear(bounds)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.9))
        drawSubtitle(text, font: font, paragraph: paragraph, rect: textRect, in: context, strokeOnly: true)
        drawSubtitle(text, font: font, paragraph: paragraph, rect: textRect, in: context, strokeOnly: false)
        return context.makeImage()
    }

    private func drawSubtitle(_ text: String,
                              font: CTFont,
                              paragraph: CTParagraphStyle,
                              rect: CGRect,
                              in context: CGContext,
                              strokeOnly: Bool) {
        let path = CGMutablePath()
        path.addRect(rect)
        let attributed = makeSubtitleString(text, font: font, paragraph: paragraph, strokeOnly: strokeOnly)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil)
        CTFrameDraw(frame, context)
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
