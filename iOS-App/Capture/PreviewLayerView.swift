import UIKit
import AVFoundation

/// 承载相机预览层的容器视图，随视图 bounds 自动布局预览层。
final class PreviewLayerView: UIView {
    private let previewLayer: CALayer
    var videoGravity: AVLayerVideoGravity {
        didSet { applyVideoGravity() }
    }

    init(previewLayer: CALayer, videoGravity: AVLayerVideoGravity = .resizeAspectFill) {
        self.previewLayer = previewLayer
        self.videoGravity = videoGravity
        super.init(frame: .zero)
        applyVideoGravity()
        layer.addSublayer(previewLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }

    private func applyVideoGravity() {
        if let captureLayer = previewLayer as? AVCaptureVideoPreviewLayer {
            captureLayer.videoGravity = videoGravity
        } else if let sampleLayer = previewLayer as? AVSampleBufferDisplayLayer {
            sampleLayer.videoGravity = videoGravity
        }
    }
}
