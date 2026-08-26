import UIKit
import AVFoundation

/// 承载相机预览层的容器视图，随视图 bounds 自动布局预览层。
final class PreviewLayerView: UIView {
    /// 实际承载相机或采样缓冲画面的图层。
    private let previewLayer: CALayer
    /// 视频在预览容器中的填充方式。
    var videoGravity: AVLayerVideoGravity {
        didSet { applyVideoGravity() }
    }

    /// 使用指定预览图层创建容器视图。
    init(previewLayer: CALayer, videoGravity: AVLayerVideoGravity = .resizeAspectFill) {
        self.previewLayer = previewLayer
        self.videoGravity = videoGravity
        super.init(frame: .zero)
        clipsToBounds = true
        applyVideoGravity()
        layer.addSublayer(previewLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 跟随容器尺寸同步预览图层尺寸，避免拖动分屏时图层动画滞后露出黑底。
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }

    /// 将当前填充方式应用到不同类型的视频预览图层。
    private func applyVideoGravity() {
        if let captureLayer = previewLayer as? AVCaptureVideoPreviewLayer {
            captureLayer.videoGravity = videoGravity
        } else if let sampleLayer = previewLayer as? AVSampleBufferDisplayLayer {
            sampleLayer.videoGravity = videoGravity
        }
    }
}
