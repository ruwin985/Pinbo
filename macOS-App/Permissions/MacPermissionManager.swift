import AVFoundation
import Foundation
import Speech

/// 摄像头权限请求完成后的明确结果。
enum CameraAuthorizationResult {
    /// 已允许应用访问摄像头。
    case authorized
    /// 用户已拒绝应用访问摄像头。
    case denied
    /// 系统策略或家长控制限制了摄像头访问。
    case restricted
}

/// 统一管理 macOS 录制功能使用的系统权限。
final class MacPermissionManager {
    /// 当前是否已经获得摄像头权限。
    static var isCameraAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    /// 当前是否已经获得默认输入设备权限。
    static var isMicrophoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// 请求摄像头权限，并区分授权、拒绝和受限状态。
    static func requestCameraAuthorization(_ completion: @escaping (CameraAuthorizationResult) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(.authorized)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    completion(granted ? .authorized : .denied)
                }
            }
        case .denied:
            completion(.denied)
        case .restricted:
            completion(.restricted)
        @unknown default:
            completion(.denied)
        }
    }

    /// 请求摄像头权限，并兼容旧的布尔结果调用方式。
    static func requestCamera(_ completion: @escaping (Bool) -> Void) {
        requestCameraAuthorization { result in
            completion(result == .authorized)
        }
    }

    /// 请求默认输入设备权限，用于声音录制和可选的字幕识别。
    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    static func requestSpeech(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion(status == .authorized) }
        }
    }

    static func requestCameraMicAndSpeech(_ completion: @escaping (_ camera: Bool, _ microphone: Bool, _ speech: Bool) -> Void) {
        requestCamera { cameraGranted in
            requestMicrophone { micGranted in
                requestSpeech { speechGranted in
                    completion(cameraGranted, micGranted, speechGranted)
                }
            }
        }
    }
}
