import AppKit

final class HomeWindowController: NSWindowController {
    private var homeViewController: MacHomeViewController?
    private var recordingWindowController: MacRecordingWindowController?

    init() {
        let controller = MacHomeViewController()
        homeViewController = controller
        let window = NSWindow(contentViewController: controller)
        window.title = "拍呗"
        window.setContentSize(CGSize(width: 1120, height: 760))
        window.minSize = CGSize(width: 900, height: 620)
        window.center()
        window.backgroundColor = .windowBackgroundColor
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.styleMask.insert(.fullSizeContentView)
        window.sharingType = .none
        super.init(window: window)
        configureHomeCallbacks(controller)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func openSourcePicker() {
        let picker = SourcePickerViewController()
        picker.onBack = { [weak self] in
            self?.showHome()
        }
        picker.onStartRecording = { [weak self] target in
            self?.openRecording(target: target)
        }
        window?.contentViewController = picker
        window?.title = "选择录屏内容"
    }

    private func showHome() {
        let home = MacHomeViewController()
        homeViewController = home
        configureHomeCallbacks(home)
        window?.contentViewController = home
        window?.title = "拍呗"
    }

    private func openRecording(target: ScreenCaptureTarget) {
        let recorder = MacRecordingWindowController(target: target)
        recorder.onFinish = { [weak self, weak recorder] _ in
            recorder?.close()
            self?.recordingWindowController = nil
            self?.showHome()
            self?.window?.makeKeyAndOrderFront(nil)
        }
        recorder.onCancel = { [weak self, weak recorder] in
            recorder?.close()
            self?.recordingWindowController = nil
            self?.showHome()
            self?.window?.makeKeyAndOrderFront(nil)
        }
        recordingWindowController = recorder
        recorder.showWindow(nil)
        recorder.window?.makeKeyAndOrderFront(nil)
        window?.orderOut(nil)
    }

    private func configureHomeCallbacks(_ home: MacHomeViewController) {
        home.onOpenScreenRecording = { [weak self] in
            self?.openSourcePicker()
        }
        home.onOpenDraft = { project in
            if let url = project.mainVideoURL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}
