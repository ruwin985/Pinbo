import AppKit

final class MacRecordingWindowController: NSWindowController {
    private let recordingViewController: MacRecordingViewController

    var onFinish: ((RecordingProject) -> Void)? {
        didSet { recordingViewController.onFinish = onFinish }
    }

    var onCancel: (() -> Void)? {
        didSet { recordingViewController.onCancel = onCancel }
    }

    init(target: ScreenCaptureTarget) {
        let controller = MacRecordingViewController(target: target)
        recordingViewController = controller
        let window = NSWindow(contentViewController: controller)
        window.title = "拍呗录屏"
        window.setContentSize(CGSize(width: 1180, height: 760))
        window.minSize = CGSize(width: 920, height: 620)
        window.center()
        window.backgroundColor = .black
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.sharingType = .none
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }
}
