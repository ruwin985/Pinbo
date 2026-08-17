import Foundation
import AVFoundation
import Speech
import Photos

/// 统一管理相机、麦克风、语音识别、相册权限。
/// 注意：语音识别与麦克风是两个独立权限；本 App 的实时字幕需要语音识别权限，随麦克风一并申请。
enum PermissionManager {

    static var cameraGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }
    static var micGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    static var photoGranted: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        return s == .authorized || s == .limited
    }

    static func requestCamera(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { g in
            DispatchQueue.main.async { completion(g) }
        }
    }

    /// 申请麦克风 + 语音识别（两者一起，供录音与实时字幕使用）。
    static func requestMicAndSpeech(_ completion: @escaping (_ mic: Bool, _ speech: Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { micGranted in
            SFSpeechRecognizer.requestAuthorization { speechStatus in
                DispatchQueue.main.async {
                    completion(micGranted, speechStatus == .authorized)
                }
            }
        }
    }

    static func requestPhoto(_ completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { s in
            DispatchQueue.main.async { completion(s == .authorized || s == .limited) }
        }
    }
}
