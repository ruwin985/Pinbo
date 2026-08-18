import AVFoundation
import Foundation
import Speech

final class MacPermissionManager {
    static func requestCamera(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

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
