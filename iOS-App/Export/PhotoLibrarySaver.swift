import Foundation
import Photos

/// 把导出的视频保存到系统相册。
enum PhotoLibrarySaver {

    enum SaveError: Error, LocalizedError {
        case denied
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .denied: return "未获得相册写入权限"
            case .failed(let m): return "保存失败：\(m)"
            }
        }
    }

    /// 保存视频到相册（自动申请「仅添加」权限）。
    static func save(videoURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(.failure(SaveError.denied)) }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
            }, completionHandler: { success, error in
                DispatchQueue.main.async {
                    if success {
                        completion(.success(()))
                    } else {
                        completion(.failure(SaveError.failed(error?.localizedDescription ?? "未知错误")))
                    }
                }
            })
        }
    }
}
