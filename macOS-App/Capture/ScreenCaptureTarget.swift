import AppKit
import ScreenCaptureKit

struct ScreenCaptureTarget: Identifiable, Equatable {
    enum Kind: Equatable {
        case display(SCDisplay)
        case window(SCWindow)
    }

    let id: String
    let title: String
    let subtitle: String?
    let icon: NSImage?
    let kind: Kind
    let excludedWindows: [SCWindow]
    var thumbnail: NSImage?

    static func == (lhs: ScreenCaptureTarget, rhs: ScreenCaptureTarget) -> Bool {
        lhs.id == rhs.id
    }

    var display: SCDisplay? {
        switch kind {
        case .display(let display): return display
        case .window: return nil
        }
    }

    var window: SCWindow? {
        switch kind {
        case .display: return nil
        case .window(let window): return window
        }
    }

    func makeFilter(excluding additionalWindows: [SCWindow] = []) -> SCContentFilter {
        switch kind {
        case .display(let display):
            let excluded = (excludedWindows + additionalWindows).deduplicatedByWindowID()
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            if #available(macOS 14.2, *) {
                filter.includeMenuBar = true
            }
            return filter
        case .window(let window):
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    var pixelSize: CGSize {
        switch kind {
        case .display(let display):
            return CGSize(width: max(1, display.width), height: max(1, display.height))
        case .window(let window):
            let scale = NSScreen.screens.first { $0.frame.intersects(window.frame) }?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2
            return CGSize(width: max(1, window.frame.width * scale),
                          height: max(1, window.frame.height * scale))
        }
    }
}

final class ScreenCaptureTargetProvider {
    func loadTargets(completion: @escaping (Result<[ScreenCaptureTarget], Error>) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let content else {
                DispatchQueue.main.async { completion(.success([])) }
                return
            }
            var targets: [ScreenCaptureTarget] = []
            let currentPID = ProcessInfo.processInfo.processIdentifier
            let ownWindows = content.windows.filter { window in
                window.owningApplication?.processID == currentPID
            }
            for (index, display) in content.displays.enumerated() {
                targets.append(ScreenCaptureTarget(id: "display-\(display.displayID)",
                                                   title: "桌面 \(index + 1)",
                                                   subtitle: "\(display.width) × \(display.height)",
                                                   icon: NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil),
                                                   kind: .display(display),
                                                   excludedWindows: ownWindows))
            }

            let windows = content.windows
                .filter { window in
                    window.isOnScreen
                    && window.windowLayer == 0
                    && window.frame.width >= 80
                    && window.frame.height >= 60
                    && window.owningApplication?.processID != currentPID
                }
                .sorted { lhs, rhs in
                    let lhsName = lhs.owningApplication?.applicationName ?? ""
                    let rhsName = rhs.owningApplication?.applicationName ?? ""
                    if lhsName == rhsName { return (lhs.title ?? "") < (rhs.title ?? "") }
                    return lhsName < rhsName
                }

            for window in windows {
                let appName = window.owningApplication?.applicationName ?? "应用窗口"
                let title = window.title?.isEmpty == false ? window.title! : appName
                targets.append(ScreenCaptureTarget(id: "window-\(window.windowID)",
                                                   title: title,
                                                   subtitle: appName,
                                                   icon: Self.icon(for: window.owningApplication),
                                                   kind: .window(window),
                                                   excludedWindows: []))
            }

            DispatchQueue.main.async { completion(.success(targets)) }
        }
    }

    func loadThumbnail(for target: ScreenCaptureTarget, completion: @escaping (NSImage?) -> Void) {
        guard #available(macOS 14.0, *) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let filter = target.makeFilter()
        let config = SCStreamConfiguration()
        let size = thumbnailSize(for: target)
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 3
        config.preservesAspectRatio = true

        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in
            let nsImage = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            DispatchQueue.main.async { completion(nsImage) }
        }
    }

    private func thumbnailSize(for target: ScreenCaptureTarget) -> CGSize {
        let pixelSize = target.pixelSize
        let maxWidth: CGFloat = 520
        let maxHeight: CGFloat = 320
        let scale = min(maxWidth / pixelSize.width, maxHeight / pixelSize.height, 1)
        return CGSize(width: max(160, (pixelSize.width * scale).rounded()),
                      height: max(100, (pixelSize.height * scale).rounded()))
    }

    private static func icon(for application: SCRunningApplication?) -> NSImage? {
        guard let bundleIdentifier = application?.bundleIdentifier,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
              let icon = app.icon else {
            return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        }
        return icon
    }
}

private extension Array where Element == SCWindow {
    func deduplicatedByWindowID() -> [SCWindow] {
        var seen = Set<CGWindowID>()
        return filter { window in
            seen.insert(window.windowID).inserted
        }
    }
}
