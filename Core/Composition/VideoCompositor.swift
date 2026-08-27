import Foundation
import AVFoundation
import CoreGraphics

/// 把「主画面 + 画中画（含关键帧布局）+ 字幕」合成为竖版成品视频并导出。
///
/// 方案：
/// - 主画面、画中画都作为真实视频轨道，用 layerInstruction 的 transform 定位（画中画能真实显示画面）。
/// - 字幕用 Core Animation 层（CATextLayer）通过 animationTool 叠加，按时间戳显隐。
/// - Demo 版画中画取首个关键帧作为固定位置；完整关键帧动画在 V2。
public final class VideoCompositor {

    public enum CompositorError: Error, LocalizedError {
        case missingMainVideo
        case missingMainTrack
        case exportSessionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missingMainVideo: return "缺少主画面视频"
            case .missingMainTrack: return "主画面无视频轨"
            case .exportSessionFailed(let m): return "导出失败：\(m)"
            }
        }
    }

    /// 导出视频的目标长边，默认保持 iOS 端原有的 1280 输出策略。
    public var exportLongEdge: CGFloat = 1280
    /// 导出视频的目标帧速率，默认保持 iOS 端原有的 24fps 策略。
    public var exportFrameRate: Int = 24

    public init() {}

    /// 构建结果：可用于预览（AVPlayerItem）或导出（AVAssetExportSession）。
    public struct Built {
        public let composition: AVMutableComposition
        public let videoComposition: AVMutableVideoComposition
        /// 多路录音存在时用于同步播放和导出的混音参数。
        public let audioMix: AVAudioMix?
    }

    /// 根据项目数据构建 composition + videoComposition。
    /// - Parameter includeSubtitles: 是否把字幕烧进画面。预览时可传 false，改用 UI 叠加层显示字幕（可即时编辑）。
    public func build(project: RecordingProject,
                      includeSubtitles: Bool = true,
                      trimStart: TimeInterval = 0,
                      trimEnd: TimeInterval? = nil) throws -> Built {
        guard let mainURL = project.mainVideoURL else { throw CompositorError.missingMainVideo }

        let mainAsset = AVURLAsset(url: mainURL)
        let pipAsset = project.aspect.recordsSecondaryVideo ? project.pipVideoURL.map { AVURLAsset(url: $0) } : nil

        let composition = AVMutableComposition()

        guard let mainVideoTrack = mainAsset.tracks(withMediaType: .video).first,
              let compMainVideoTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CompositorError.missingMainTrack
        }
        let mainTrackID = compMainVideoTrack.trackID

        let assetDurationSeconds = Self.resolvedDuration(for: mainAsset,
                                                         fallback: project.duration)
        let startSeconds = min(max(trimStart, 0), assetDurationSeconds)
        let endSeconds = min(max(trimEnd ?? assetDurationSeconds, startSeconds), assetDurationSeconds)
        let outputDurationSeconds = max(endSeconds - startSeconds, 0.01)
        let sourceStart = CMTime(seconds: startSeconds, preferredTimescale: 600)
        let duration = CMTime(seconds: outputDurationSeconds, preferredTimescale: 600)
        let sourceRange = CMTimeRange(start: sourceStart, duration: duration)
        let outputRange = CMTimeRange(start: .zero, duration: duration)

        try compMainVideoTrack.insertTimeRange(sourceRange, of: mainVideoTrack, at: .zero)
        let sourceAudioTracks = mainAsset.tracks(withMediaType: .audio)
        var audioMixParameters: [AVAudioMixInputParameters] = []
        for (index, mainAudio) in sourceAudioTracks.enumerated() {
            guard let compAudio = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            do {
                try compAudio.insertTimeRange(sourceRange, of: mainAudio, at: .zero)
                let parameter = AVMutableAudioMixInputParameters(track: compAudio)
                let volume: Float = sourceAudioTracks.count > 1 && index == 0 ? 0.8 : 1
                parameter.setVolume(volume, at: .zero)
                audioMixParameters.append(parameter)
            } catch {
                composition.removeTrack(compAudio)
            }
        }
        let audioMix: AVAudioMix? = audioMixParameters.count > 1
            ? makeAudioMix(parameters: audioMixParameters)
            : nil

        // 画中画轨道
        var pipSourceTrack: AVAssetTrack?
        var pipTrackID: CMPersistentTrackID?
        let hasPip = pipAsset != nil && (project.aspect.isSplitScreenEnabled || (project.aspect.isPiPEnabled && !project.pipTrack.isEmpty))
        if let pipAsset, let track = pipAsset.tracks(withMediaType: .video).first,
           let t = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            pipSourceTrack = track
            pipTrackID = t.trackID
            let pipAssetDuration = Self.resolvedDuration(for: pipAsset,
                                                         fallback: assetDurationSeconds)
            let pipDur = min(max(0, pipAssetDuration - startSeconds), duration.seconds)
            if pipDur > 0 {
                let pipRange = CMTimeRange(start: sourceStart,
                                           duration: CMTime(seconds: pipDur, preferredTimescale: 600))
                try? t.insertTimeRange(pipRange, of: track, at: .zero)
            }
        }

        let canvas = Self.renderCanvasSize(for: mainVideoTrack,
                                           project: project,
                                           longEdge: exportLongEdge)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = canvas
        videoComposition.frameDuration = CMTime(value: 1,
                                                timescale: CMTimeScale(max(1, exportFrameRate)))
        videoComposition.customVideoCompositorClass = PiPVideoCompositor.self

        let instruction = PiPCompositionInstruction(timeRange: outputRange,
                                                     mainTrackID: mainTrackID,
                                                     pipTrackID: hasPip ? pipTrackID : nil)
        instruction.canvas = canvas
        instruction.fitsMainContent = project.aspect.main.isDefault && project.sourceKind == .screen
        instruction.pipKeyframes = mappedPiPKeyframes(shifted(project.pipTrack, by: startSeconds),
                                                      for: project)
        instruction.pipAspect = project.aspect.pip.aspect
        instruction.pipCornerRatio = project.aspect.pip.cornerRatio
        instruction.isSplitScreenEnabled = project.aspect.isSplitScreenEnabled
        instruction.splitScreenOrder = project.aspect.splitOrder
        instruction.splitScreenTopRatio = project.aspect.splitTopRatio
        instruction.splitScreenKeyframes = shifted(project.splitScreenTrack,
                                                  by: startSeconds,
                                                  fallbackOrder: project.aspect.splitOrder,
                                                  fallbackTopRatio: project.aspect.splitTopRatio)
        instruction.totalDuration = duration.seconds
        instruction.subtitles = includeSubtitles ? shifted(project.subtitleTrack, by: startSeconds, duration: duration.seconds) : []
        instruction.subtitleLayout = project.subtitleLayout
        instruction.emphasizesSubtitleKeywords = project.emphasizesSubtitleKeywords
        // 传入各轨道方向信息，供合成器把帧摆正（修复方向被旋转）
        instruction.mainTransform = VideoTrackTransform(track: mainVideoTrack)
        if let pip = pipSourceTrack {
            instruction.pipTransform = VideoTrackTransform(track: pip)
        }
        videoComposition.instructions = [instruction]

        return Built(composition: composition,
                     videoComposition: videoComposition,
                     audioMix: audioMix)
    }

    public func export(project: RecordingProject,
                       includeSubtitles: Bool = true,
                       trimStart: TimeInterval = 0,
                       trimEnd: TimeInterval? = nil,
                       completion: @escaping (Result<URL, Error>) -> Void) {
        let built: Built
        do {
            built = try build(project: project,
                              includeSubtitles: includeSubtitles,
                              trimStart: trimStart,
                              trimEnd: trimEnd)
        } catch {
            completion(.failure(error)); return
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinbo_export_\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: outURL)

        guard let exporter = AVAssetExportSession(asset: built.composition,
                                                  presetName: exportPresetName(for: built.videoComposition.renderSize)) else {
            completion(.failure(CompositorError.exportSessionFailed("无法创建导出会话"))); return
        }
        exporter.videoComposition = built.videoComposition
        exporter.audioMix = built.audioMix
        exporter.outputURL = outURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true

        exporter.exportAsynchronously {
            DispatchQueue.main.async {
                switch exporter.status {
                case .completed: completion(.success(outURL))
                case .failed, .cancelled:
                    completion(.failure(CompositorError.exportSessionFailed(
                        exporter.error?.localizedDescription ?? "未知错误")))
                default: break
                }
            }
        }
    }

    /// 使用已经绑定到合成轨道的参数创建多路声音混音配置。
    private func makeAudioMix(parameters: [AVAudioMixInputParameters]) -> AVAudioMix {
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = parameters
        return audioMix
    }

    /// 根据目标长边选择不会主动压低清晰度的导出预设。
    /// 根据目标画布和长边选择导出预设，非 16:9 画布使用最高质量预设避免被强制裁成 16:9。
    private func exportPresetName(for renderSize: CGSize) -> String {
        let ratio = renderSize.width / max(renderSize.height, 1)
        guard abs(ratio - (16.0 / 9.0)) < 0.01 else {
            return AVAssetExportPresetHighestQuality
        }
        let actualLongEdge = max(renderSize.width, renderSize.height)
        if actualLongEdge >= 3840 {
            return AVAssetExportPreset3840x2160
        }
        if actualLongEdge >= 1920 {
            return AVAssetExportPreset1920x1080
        }
        return AVAssetExportPresetHighestQuality
    }

    private func shifted(_ keyframes: [PiPKeyframe], by offset: TimeInterval) -> [PiPKeyframe] {
        let sorted = keyframes.sorted { $0.time < $1.time }
        guard let base = sorted.last(where: { $0.time <= offset }) ?? sorted.first else { return [] }
        var shifted = [PiPKeyframe(time: 0,
                                   center: base.center,
                                   size: base.size,
                                   cornerRadius: base.cornerRadius)]
        shifted.append(contentsOf: sorted.filter { $0.time > offset }.map {
            PiPKeyframe(time: $0.time - offset,
                        center: $0.center,
                        size: $0.size,
                        cornerRadius: $0.cornerRadius)
        })
        return shifted
    }

    private func mappedPiPKeyframes(_ keyframes: [PiPKeyframe],
                                    for project: RecordingProject) -> [PiPKeyframe] {
        guard project.sourceKind == .camera,
              !project.aspect.main.isDefault,
              !project.aspect.isSplitScreenEnabled,
              let viewport = project.captureViewportSize,
              viewport.width > 0,
              viewport.height > 0 else { return keyframes }

        let captureRect = Self.aspectRect(for: project.aspect.main.ratio, in: viewport)
        guard captureRect.width > 0, captureRect.height > 0 else { return keyframes }

        return keyframes.map { keyframe in
            let absoluteCenter = CGPoint(x: keyframe.center.x * viewport.width,
                                         y: keyframe.center.y * viewport.height)
            let absoluteSize = CGSize(width: keyframe.size.width * viewport.width,
                                      height: keyframe.size.height * viewport.height)
            return PiPKeyframe(time: keyframe.time,
                               center: CGPoint(x: (absoluteCenter.x - captureRect.minX) / captureRect.width,
                                               y: (absoluteCenter.y - captureRect.minY) / captureRect.height),
                               size: CGSize(width: absoluteSize.width / captureRect.width,
                                            height: absoluteSize.height / captureRect.height),
                               cornerRadius: keyframe.cornerRadius)
        }
    }

    private func shifted(_ keyframes: [SplitScreenKeyframe],
                         by offset: TimeInterval,
                         fallbackOrder: CameraSplitOrder,
                         fallbackTopRatio: CGFloat) -> [SplitScreenKeyframe] {
        let sorted = keyframes.sorted { $0.time < $1.time }
        let base = sorted.last(where: { $0.time <= offset })
            ?? sorted.first
            ?? SplitScreenKeyframe(time: 0, order: fallbackOrder, topRatio: fallbackTopRatio)
        var shifted = [SplitScreenKeyframe(time: 0, order: base.order, topRatio: base.topRatio)]
        shifted.append(contentsOf: sorted.filter { $0.time > offset }.map {
            SplitScreenKeyframe(time: $0.time - offset, order: $0.order, topRatio: $0.topRatio)
        })
        return shifted
    }

    private func shifted(_ subtitles: [SubtitleSegment], by offset: TimeInterval, duration: TimeInterval) -> [SubtitleSegment] {
        return subtitles.compactMap { segment in
            let start = segment.startTime - offset
            let end = segment.endTime - offset
            guard end >= 0, start <= duration else { return nil }
            return SubtitleSegment(id: segment.id,
                                   startTime: max(0, start),
                                   endTime: min(duration, end),
                                   text: segment.text)
        }
    }

    private static func resolvedDuration(for asset: AVAsset, fallback: TimeInterval) -> TimeInterval {
        let videoDuration = asset.tracks(withMediaType: .video)
            .map { $0.timeRange.end.seconds }
            .max() ?? 0
        let audioDuration = asset.tracks(withMediaType: .audio)
            .map { $0.timeRange.end.seconds }
            .max() ?? 0
        let candidates: [TimeInterval] = [
            asset.duration.seconds,
            videoDuration,
            audioDuration,
            fallback
        ]
        return candidates.first { $0.isFinite && $0 > 0 } ?? 0
    }

    private static func renderCanvasSize(for track: AVAssetTrack,
                                         project: RecordingProject,
                                         longEdge: CGFloat) -> CGSize {
        let sourceLongEdge = sourceLongEdge(for: track)
        let effectiveLongEdge = project.sourceKind == .screen
            ? min(longEdge, sourceLongEdge)
            : longEdge
        guard project.aspect.main.isDefault || project.aspect.isSplitScreenEnabled else {
            return project.aspect.main.canvasSize(longEdge: effectiveLongEdge)
        }
        switch project.sourceKind {
        case .camera:
            if let viewport = project.captureViewportSize,
               viewport.width > 0,
               viewport.height > 0 {
                return canvasSize(forAspectRatio: viewport.width / viewport.height,
                                  longEdge: longEdge)
            }
            return AspectRatio.default.canvasSize(longEdge: longEdge)
        case .screen:
            return sourceCanvasSize(for: track, longEdge: effectiveLongEdge)
        }
    }

    /// 返回视频轨道经过方向变换后的实际长边像素数。
    private static func sourceLongEdge(for track: AVAssetTrack) -> CGFloat {
        let transformedSize = track.naturalSize.applying(track.preferredTransform)
        return max(abs(transformedSize.width), abs(transformedSize.height))
    }

    private static func sourceCanvasSize(for track: AVAssetTrack, longEdge: CGFloat) -> CGSize {
        let transformedSize = track.naturalSize.applying(track.preferredTransform)
        let sourceSize = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return AspectRatio.default.canvasSize(longEdge: longEdge)
        }
        let sourceLongEdge = max(sourceSize.width, sourceSize.height)
        return canvasSize(forAspectRatio: sourceSize.width / sourceSize.height,
                          longEdge: min(longEdge, sourceLongEdge))
    }

    private static func canvasSize(forAspectRatio ratio: CGFloat, longEdge: CGFloat) -> CGSize {
        let safeRatio = max(ratio, 0.01)
        let width: CGFloat
        let height: CGFloat
        if safeRatio >= 1 {
            width = longEdge
            height = longEdge / safeRatio
        } else {
            width = longEdge * safeRatio
            height = longEdge
        }
        return CGSize(width: max(2, width.roundedToEven()),
                      height: max(2, height.roundedToEven()))
    }

    private static func aspectRect(for ratio: CGFloat, in size: CGSize) -> CGRect {
        guard ratio > 0, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        var width = size.width
        var height = width / ratio
        if height > size.height {
            height = size.height
            width = height * ratio
        }
        return CGRect(x: (size.width - width) / 2,
                      y: (size.height - height) / 2,
                      width: width,
                      height: height)
    }

}

private extension CGFloat {
    func roundedToEven() -> CGFloat {
        let roundedValue = Int(rounded())
        return CGFloat(roundedValue.isMultiple(of: 2) ? roundedValue : roundedValue + 1)
    }
}
