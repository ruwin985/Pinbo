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

    /// 导出长边。双路视频 + 字幕合成时用 1280 控制峰值内存，避免保存时被系统杀掉。
    public var exportLongEdge: CGFloat = 1280

    public init() {}

    /// 构建结果：可用于预览（AVPlayerItem）或导出（AVAssetExportSession）。
    public struct Built {
        public let composition: AVMutableComposition
        public let videoComposition: AVMutableVideoComposition
    }

    /// 根据项目数据构建 composition + videoComposition。
    /// - Parameter includeSubtitles: 是否把字幕烧进画面。预览时可传 false，改用 UI 叠加层显示字幕（可即时编辑）。
    public func build(project: RecordingProject,
                      includeSubtitles: Bool = true,
                      trimStart: TimeInterval = 0,
                      trimEnd: TimeInterval? = nil) throws -> Built {
        guard let mainURL = project.mainVideoURL else { throw CompositorError.missingMainVideo }

        let mainAsset = AVURLAsset(url: mainURL)
        let pipAsset = project.aspect.isPiPEnabled ? project.pipVideoURL.map { AVURLAsset(url: $0) } : nil

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
        if let mainAudio = mainAsset.tracks(withMediaType: .audio).first,
           let compAudio = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try compAudio.insertTimeRange(sourceRange, of: mainAudio, at: .zero)
        }

        // 画中画轨道
        var pipSourceTrack: AVAssetTrack?
        var pipTrackID: CMPersistentTrackID?
        let hasPip = project.aspect.isPiPEnabled && pipAsset != nil && !project.pipTrack.isEmpty
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

        // 画布尺寸按主画面比例设置
        let canvas = project.aspect.main.canvasSize(longEdge: exportLongEdge)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = canvas
        videoComposition.frameDuration = CMTime(value: 1, timescale: 24)
        videoComposition.customVideoCompositorClass = PiPVideoCompositor.self

        let instruction = PiPCompositionInstruction(timeRange: outputRange,
                                                     mainTrackID: mainTrackID,
                                                     pipTrackID: hasPip ? pipTrackID : nil)
        instruction.canvas = canvas
        instruction.pipKeyframes = shifted(project.pipTrack, by: startSeconds)
        instruction.pipAspect = project.aspect.pip.aspect
        instruction.pipCornerRatio = project.aspect.pip.cornerRatio
        instruction.totalDuration = duration.seconds
        instruction.subtitles = includeSubtitles ? shifted(project.subtitleTrack, by: startSeconds, duration: duration.seconds) : []
        instruction.subtitleLayout = project.subtitleLayout
        // 传入各轨道方向信息，供合成器把帧摆正（修复方向被旋转）
        instruction.mainTransform = VideoTrackTransform(track: mainVideoTrack)
        if let pip = pipSourceTrack {
            instruction.pipTransform = VideoTrackTransform(track: pip)
        }
        videoComposition.instructions = [instruction]

        return Built(composition: composition, videoComposition: videoComposition)
    }

    public func export(project: RecordingProject,
                       trimStart: TimeInterval = 0,
                       trimEnd: TimeInterval? = nil,
                       completion: @escaping (Result<URL, Error>) -> Void) {
        let built: Built
        do {
            built = try build(project: project, trimStart: trimStart, trimEnd: trimEnd)
        } catch {
            completion(.failure(error)); return
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinbo_export_\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: outURL)

        guard let exporter = AVAssetExportSession(asset: built.composition,
                                                  presetName: AVAssetExportPreset1280x720) else {
            completion(.failure(CompositorError.exportSessionFailed("无法创建导出会话"))); return
        }
        exporter.videoComposition = built.videoComposition
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

}
