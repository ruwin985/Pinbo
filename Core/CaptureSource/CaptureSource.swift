import Foundation
import AVFoundation

/// 采集源的当前状态。
public enum CaptureState: Equatable {
    case idle
    case configured
    case recording
    case stopped
    case failed(String)
}

/// 采集源事件回调。
public protocol CaptureSourceDelegate: AnyObject {
    /// 状态变化
    func captureSource(_ source: CaptureSourceProviding, didChange state: CaptureState)
    /// 录制完成，产出主画面 + 画中画两路文件
    func captureSource(_ source: CaptureSourceProviding,
                       didFinishRecordingMain mainURL: URL?,
                       pip pipURL: URL?)
    /// 采集到用于语音识别的音频缓冲（供实时字幕使用）
    func captureSource(_ source: CaptureSourceProviding,
                       didOutput audioBuffer: CMSampleBuffer)
}

/// 采集源统一抽象：
/// - iOS 实现：AVCaptureMultiCamSession（后摄 = 主画面，前摄 = 画中画）
/// - macOS 实现：ScreenCaptureKit（录屏 = 主画面）+ 摄像头（画中画）
/// 上层（字幕 / 编辑 / 合成）对具体平台无感知。
public protocol CaptureSourceProviding: AnyObject {
    var delegate: CaptureSourceDelegate? { get set }
    var state: CaptureState { get }

    /// 当前设备是否支持该采集源（如 iOS 的多摄能力）
    static var isSupported: Bool { get }

    /// 配置采集会话（申请设备、建立输入输出）
    func configure() throws

    /// 主画面预览层（后摄，全屏）
    func makeMainPreviewLayer() -> AVCaptureVideoPreviewLayer?
    /// 画中画预览层（前摄，小窗）
    func makePiPPreviewLayer() -> AVCaptureVideoPreviewLayer?

    func startRunning()
    func stopRunning()

    func startRecording()
    func stopRecording()
}
