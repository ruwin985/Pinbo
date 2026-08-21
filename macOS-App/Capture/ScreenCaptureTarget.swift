import AppKit
import ApplicationServices
import ScreenCaptureKit

/// 录屏选择页中展示和录制使用的捕获目标。
struct ScreenCaptureTarget: Identifiable, Equatable {
    /// 支持录制的内容类型。
    enum Kind: Equatable {
        /// 整个桌面显示器。
        case display(SCDisplay)
        /// 单个独立应用窗口。
        case window(SCWindow)
    }

    /// 目标唯一标识。
    let id: String
    /// 主标题。
    let title: String
    /// 副标题。
    let subtitle: String?
    /// 展示图标。
    let icon: NSImage?
    /// 捕获目标类型。
    let kind: Kind
    /// 录制桌面时需要排除的窗口。
    let excludedWindows: [SCWindow]
    /// 选择页缩略图。
    var thumbnail: NSImage?

    /// 只按稳定 ID 判断目标是否相同。
    static func == (lhs: ScreenCaptureTarget, rhs: ScreenCaptureTarget) -> Bool {
        lhs.id == rhs.id
    }

    /// 当前目标关联的显示器。
    var display: SCDisplay? {
        switch kind {
        case .display(let display): return display
        case .window: return nil
        }
    }

    /// 当前目标关联的独立窗口。
    var window: SCWindow? {
        switch kind {
        case .display: return nil
        case .window(let window): return window
        }
    }

    /// 生成 ScreenCaptureKit 使用的内容过滤器。
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

    /// 当前目标的录制像素尺寸。
    var pixelSize: CGSize {
        switch kind {
        case .display(let display):
            return CGSize(width: max(1, display.width), height: max(1, display.height))
        case .window(let window):
            let scale = ScreenCaptureCoordinateMapper.screen(for: window)?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2
            return CGSize(width: max(1, window.frame.width * scale),
                          height: max(1, window.frame.height * scale))
        }
    }
}

/// 负责从 ScreenCaptureKit 枚举可录制桌面和所有 Space 中正在展示的窗口。
final class ScreenCaptureTargetProvider {
    /// 异步读取选择页可展示的录制目标。
    func loadTargets(completion: @escaping (Result<[ScreenCaptureTarget], Error>) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let content else {
                DispatchQueue.main.async { completion(.success([])) }
                return
            }
            let currentPID = ProcessInfo.processInfo.processIdentifier
            let visibleWindowIDs = Self.visibleWindowIDsAcrossSpaces()
            let ownWindows = content.windows.filter { window in
                window.owningApplication?.processID == currentPID
            }
            var targets = Self.displayTargets(from: content.displays, excluding: ownWindows)
            let windows = content.windows
                .filter { window in
                    Self.isEligibleVisibleWindow(window,
                                                 visibleWindowIDs: visibleWindowIDs,
                                                 currentPID: currentPID)
                }
                .sorted { lhs, rhs in
                    Self.sortVisibleWindows(lhs, before: rhs, displays: content.displays)
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

    /// 异步读取目标缩略图。
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

    /// 根据目标尺寸换算缩略图截图尺寸。
    private func thumbnailSize(for target: ScreenCaptureTarget) -> CGSize {
        let pixelSize = target.pixelSize
        let maxWidth: CGFloat = 520
        let maxHeight: CGFloat = 320
        let scale = min(maxWidth / pixelSize.width, maxHeight / pixelSize.height, 1)
        return CGSize(width: max(160, (pixelSize.width * scale).rounded()),
                      height: max(100, (pixelSize.height * scale).rounded()))
    }

    /// 生成桌面显示器目标。
    private static func displayTargets(from displays: [SCDisplay], excluding ownWindows: [SCWindow]) -> [ScreenCaptureTarget] {
        displays.enumerated().map { index, display in
            ScreenCaptureTarget(id: "display-\(display.displayID)",
                                title: "桌面 \(index + 1)",
                                subtitle: "\(display.width) × \(display.height)",
                                icon: NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil),
                                kind: .display(display),
                                excludedWindows: ownWindows)
        }
    }

    /// 获取 AppKit 认为所有 Space 上当前可见的窗口编号。
    private static func visibleWindowIDsAcrossSpaces() -> Set<CGWindowID> {
        let numbers = NSWindow.windowNumbers(options: [.allApplications, .allSpaces]) ?? []
        return Set(numbers.map { CGWindowID($0.uint32Value) })
    }

    /// 判断窗口是否为需要展示的可见应用窗口。
    private static func isEligibleVisibleWindow(_ window: SCWindow,
                                                visibleWindowIDs: Set<CGWindowID>,
                                                currentPID: pid_t) -> Bool {
        guard visibleWindowIDs.contains(window.windowID) else { return false }
        guard window.owningApplication?.processID != currentPID else { return false }
        guard window.owningApplication?.applicationName.isEmpty == false else { return false }
        guard window.windowLayer == 0 else { return false }
        guard window.frame.width >= 80, window.frame.height >= 60 else { return false }
        return true
    }

    /// 将窗口按显示器、位置和应用名排序，保证列表稳定。
    private static func sortVisibleWindows(_ lhs: SCWindow, before rhs: SCWindow, displays: [SCDisplay]) -> Bool {
        let lhsDisplayIndex = displayIndex(for: lhs, displays: displays)
        let rhsDisplayIndex = displayIndex(for: rhs, displays: displays)
        if lhsDisplayIndex != rhsDisplayIndex { return lhsDisplayIndex < rhsDisplayIndex }
        if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY < rhs.frame.minY }
        if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
        let lhsName = lhs.owningApplication?.applicationName ?? ""
        let rhsName = rhs.owningApplication?.applicationName ?? ""
        if lhsName == rhsName {
            return (lhs.title ?? "").localizedStandardCompare(rhs.title ?? "") == .orderedAscending
        }
        return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
    }

    /// 返回窗口所在显示器的排序索引。
    private static func displayIndex(for window: SCWindow, displays: [SCDisplay]) -> Int {
        guard let display = ScreenCaptureCoordinateMapper.display(for: window, displays: displays),
              let index = displays.firstIndex(where: { $0.displayID == display.displayID }) else {
            return Int.max
        }
        return index
    }

    /// 获取应用图标。
    private static func icon(for application: SCRunningApplication?) -> NSImage? {
        guard let bundleIdentifier = application?.bundleIdentifier,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .first(where: { $0.processIdentifier == application?.processID }),
              let icon = app.icon else {
            return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        }
        return icon
    }
}

/// 负责点击卡片后定位实际窗口并显示蓝色边框。
final class ScreenCaptureTargetHighlighter {
    /// 单例高亮工具。
    static let shared = ScreenCaptureTargetHighlighter()

    /// 当前高亮窗口。
    private var overlayWindow: NSWindow?

    /// 私有化初始化，保证复用同一个蓝框窗口。
    private init() {}

    /// 定位并高亮录屏目标。
    @discardableResult
    func focusAndHighlight(_ target: ScreenCaptureTarget) -> Bool {
        switch target.kind {
        case .display(let display):
            guard let frame = ScreenCaptureCoordinateMapper.appKitFrame(for: display) else { return false }
            showHighlight(frame: frame)
            return true
        case .window(let window):
            activateApplication(for: window)
            let raised = raiseWindowIfPossible(window)
            guard let frame = ScreenCaptureCoordinateMapper.appKitFrame(for: window) else { return raised }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                self?.showHighlight(frame: frame.insetBy(dx: -4, dy: -4))
            }
            return raised
        }
    }

    /// 激活窗口所属应用，触发系统切换到对应 Space。
    private func activateApplication(for window: SCWindow) {
        guard let application = runningApplication(for: window) else { return }
        application.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
    }

    /// 在有辅助功能权限时抬起具体窗口。
    private func raiseWindowIfPossible(_ window: SCWindow) -> Bool {
        guard let processID = window.owningApplication?.processID else { return false }
        guard AXIsProcessTrusted() else { return false }
        let applicationElement = AXUIElementCreateApplication(processID)
        guard let axWindow = accessibilityWindow(matching: window, in: applicationElement) else { return false }
        AXUIElementSetAttributeValue(applicationElement, kAXFrontmostAttribute as CFString, true as CFBoolean)
        AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, true as CFBoolean)
        AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, true as CFBoolean)
        return AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString) == .success
    }

    /// 从辅助功能窗口列表中匹配 ScreenCaptureKit 窗口。
    private func accessibilityWindow(matching window: SCWindow, in applicationElement: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else {
            return nil
        }
        return windows.first { matches(window, axWindow: $0) }
    }

    /// 判断辅助功能窗口是否对应指定 ScreenCaptureKit 窗口。
    private func matches(_ window: SCWindow, axWindow: AXUIElement) -> Bool {
        if let number = axWindowNumber(axWindow), number == window.windowID { return true }
        let titleMatched = axTitle(axWindow).map { $0 == (window.title ?? "") } ?? false
        let frameMatched = axFrame(axWindow).map { frame in
            let targetFrame = ScreenCaptureCoordinateMapper.appKitFrame(for: window) ?? window.frame
            return abs(frame.minX - targetFrame.minX) <= 12
                && abs(frame.minY - targetFrame.minY) <= 12
                && abs(frame.width - targetFrame.width) <= 12
                && abs(frame.height - targetFrame.height) <= 12
        } ?? false
        return titleMatched && frameMatched
    }

    /// 读取辅助功能窗口编号。
    private func axWindowNumber(_ axWindow: AXUIElement) -> CGWindowID? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, "AXWindowNumber" as CFString, &value) == .success,
              let number = value as? NSNumber else {
            return nil
        }
        return CGWindowID(number.uint32Value)
    }

    /// 读取辅助功能窗口标题。
    private func axTitle(_ axWindow: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// 读取辅助功能窗口 AppKit 坐标。
    private func axFrame(_ axWindow: AXUIElement) -> CGRect? {
        guard let position = axValue(axWindow, attribute: kAXPositionAttribute as CFString, type: .cgPoint),
              let size = axValue(axWindow, attribute: kAXSizeAttribute as CFString, type: .cgSize) else {
            return nil
        }
        var point = CGPoint.zero
        var frameSize = CGSize.zero
        AXValueGetValue(position, .cgPoint, &point)
        AXValueGetValue(size, .cgSize, &frameSize)
        return ScreenCaptureCoordinateMapper.appKitFrame(fromTopLeftFrame: CGRect(origin: point, size: frameSize))
    }

    /// 读取 AXValue 类型属性。
    private func axValue(_ axWindow: AXUIElement, attribute: CFString, type: AXValueType) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, attribute, &value) == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = rawValue as! AXValue
        guard AXValueGetType(axValue) == type else { return nil }
        return axValue
    }

    /// 查找窗口所属运行应用。
    private func runningApplication(for window: SCWindow) -> NSRunningApplication? {
        guard let application = window.owningApplication else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: application.bundleIdentifier)
            .first { $0.processIdentifier == application.processID }
    }

    /// 展示蓝色边框，直到下一次选择或离开录屏选择页。
    private func showHighlight(frame: CGRect) {
        if let overlayWindow {
            overlayWindow.setFrame(frame, display: true)
            overlayWindow.contentView?.frame = CGRect(origin: .zero, size: frame.size)
            overlayWindow.orderFrontRegardless()
            return
        }
        let window = NSWindow(contentRect: frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        let borderView = HighlightBorderView(frame: CGRect(origin: .zero, size: frame.size))
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = borderView
        window.orderFrontRegardless()
        overlayWindow = window
    }

    /// 清理当前蓝色边框。
    func clearHighlight() {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
    }
}

/// 将 ScreenCaptureKit 顶点坐标转换为 AppKit 窗口坐标。
enum ScreenCaptureCoordinateMapper {
    /// 查找窗口所在的 ScreenCaptureKit 显示器。
    static func display(for window: SCWindow, displays: [SCDisplay]) -> SCDisplay? {
        displays.max { lhs, rhs in
            lhs.frame.intersection(window.frame).area < rhs.frame.intersection(window.frame).area
        }
    }

    /// 查找窗口所在的 AppKit 屏幕。
    static func screen(for window: SCWindow) -> NSScreen? {
        appKitFrame(for: window).flatMap { frame in
            NSScreen.screens.max { lhs, rhs in
                lhs.frame.intersection(frame).area < rhs.frame.intersection(frame).area
            }
        }
    }

    /// 将 ScreenCaptureKit 显示器 frame 转成 AppKit frame。
    static func appKitFrame(for display: SCDisplay) -> CGRect? {
        screen(for: display)?.frame
    }

    /// 将 ScreenCaptureKit 窗口 frame 转成 AppKit frame。
    static func appKitFrame(for window: SCWindow) -> CGRect? {
        guard let screen = screenMatchingSCKFrame(window.frame) else { return nil }
        return appKitFrame(fromTopLeftFrame: window.frame, in: screen)
    }

    /// 将全局顶点坐标 frame 转成 AppKit frame。
    static func appKitFrame(fromTopLeftFrame frame: CGRect) -> CGRect {
        guard let screen = screenMatchingSCKFrame(frame) else { return frame }
        return appKitFrame(fromTopLeftFrame: frame, in: screen)
    }

    /// 根据显示器 ID 查找 AppKit 屏幕。
    private static func screen(for display: SCDisplay) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDirectDisplayID(number.uint32Value) == display.displayID
        }
    }

    /// 查找与 ScreenCaptureKit frame 最匹配的 AppKit 屏幕。
    private static func screenMatchingSCKFrame(_ frame: CGRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            let lhsFrame = topLeftFrame(for: lhs)
            let rhsFrame = topLeftFrame(for: rhs)
            return lhsFrame.intersection(frame).area < rhsFrame.intersection(frame).area
        }
    }

    /// 把 AppKit 屏幕转换成 ScreenCaptureKit/CGWindow 的顶点坐标。
    private static func topLeftFrame(for screen: NSScreen) -> CGRect {
        guard let mainHeight = NSScreen.screens.first?.frame.height else { return screen.frame }
        return CGRect(x: screen.frame.minX,
                      y: mainHeight - screen.frame.maxY,
                      width: screen.frame.width,
                      height: screen.frame.height)
    }

    /// 在指定屏幕内转换顶点坐标为 AppKit 坐标。
    private static func appKitFrame(fromTopLeftFrame frame: CGRect, in screen: NSScreen) -> CGRect {
        let topLeftScreenFrame = topLeftFrame(for: screen)
        return CGRect(x: screen.frame.minX + frame.minX - topLeftScreenFrame.minX,
                      y: screen.frame.maxY - (frame.minY - topLeftScreenFrame.minY) - frame.height,
                      width: frame.width,
                      height: frame.height)
    }
}

/// 蓝色边框视图。
private final class HighlightBorderView: NSView {
    /// 初始化边框视图。
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 4
        layer?.borderColor = NSColor.systemBlue.cgColor
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    /// 不支持从 Interface Builder 创建。
    required init?(coder: NSCoder) { fatalError() }
}

/// SCWindow 数组工具。
private extension Array where Element == SCWindow {
    /// 按窗口 ID 去重并保持原顺序。
    func deduplicatedByWindowID() -> [SCWindow] {
        var seen = Set<CGWindowID>()
        return filter { window in
            seen.insert(window.windowID).inserted
        }
    }
}

/// CGRect 面积工具。
private extension CGRect {
    /// 矩形面积。
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}
