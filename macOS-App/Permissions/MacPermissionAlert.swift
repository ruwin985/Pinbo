import AppKit

/// 展示权限提示并跳转到对应的系统设置页面。
final class MacPermissionAlert {
    /// 应用可能请求的系统权限类型。
    enum PermissionKind {
        case screenRecording
        case camera
        case microphone
        case speech

        var title: String {
            switch self {
            case .screenRecording: return "需要屏幕录制权限"
            case .camera: return "需要摄像头权限"
            case .microphone: return "需要麦克风权限"
            case .speech: return "需要语音识别权限"
            }
        }

        var message: String {
            switch self {
            case .screenRecording:
                return "请在系统设置中允许拍呗录制屏幕。授权后需要重新打开录屏页面。"
            case .camera:
                return "请在系统设置中允许拍呗使用摄像头，才能显示前摄小窗口。"
            case .microphone:
                return "请在系统设置中允许拍呗使用麦克风，才能录制声音和生成字幕。"
            case .speech:
                return "请在系统设置中允许拍呗使用语音识别，才能生成实时字幕。"
            }
        }

        var settingsURL: URL? {
            switch self {
            case .screenRecording:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            case .camera:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
            case .microphone:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            case .speech:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
            }
        }
    }

    /// 直接打开指定权限的系统设置页面。
    static func openSettings(kind: PermissionKind) {
        guard let url = kind.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// 展示权限说明弹窗，并允许用户跳转系统设置。
    static func show(kind: PermissionKind, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = kind.title
        alert.informativeText = kind.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "去授权")
        alert.addButton(withTitle: "取消")

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            openSettings(kind: kind)
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}
