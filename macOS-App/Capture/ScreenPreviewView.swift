import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo

final class ScreenPreviewView: NSView {
    private let ciContext = CIContext()
    private let imageLayer = CALayer()
    private let renderQueue = DispatchQueue(label: "com.pinbo.mac.screen-preview.render")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
    }

    func display(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let retainedBuffer = pixelBuffer
        renderQueue.async { [weak self] in
            guard let self else { return }
            let image = CIImage(cvPixelBuffer: retainedBuffer)
            guard let cgImage = self.ciContext.createCGImage(image, from: image.extent) else { return }
            DispatchQueue.main.async {
                self.imageLayer.contents = cgImage
            }
        }
    }
}
