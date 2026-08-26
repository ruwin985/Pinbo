import Foundation
import WebKit

/// App 本地缓存清理结果，用于向用户说明实际释放情况。
struct AppStorageCleanupResult {
    /// 本次清理删除的文件和目录数量。
    var removedItemCount: Int = 0
    /// 本次清理预估释放的磁盘空间字节数。
    var removedBytes: Int64 = 0

    /// 本次清理释放空间的可读文案。
    var formattedRemovedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: removedBytes)
    }

    /// 合并一次文件删除统计。
    mutating func addRemovedItem(bytes: Int64) {
        removedItemCount += 1
        removedBytes += max(0, bytes)
    }
}

/// 手机端 App 存储清理器：清理缓存、临时录制文件和首页不可见的无效草稿残留。
enum AppStorageCleaner {
    /// 屏幕录制导入到草稿前使用的临时目录名称。
    private static let screenRecordingImportDirectoryName = "ScreenRecordingImports"
    /// 文件大小计算需要读取的资源键。
    private static let sizeResourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey
    ]

    /// 清除可安全删除的本地缓存，并保留首页可见的草稿作品。
    static func clearCache(preserving drafts: [RecordingProject], completion: @escaping (AppStorageCleanupResult) -> Void) {
        let preservedURLs = preservedVideoURLs(from: drafts)
        DispatchQueue.global(qos: .utility).async {
            var result = AppStorageCleanupResult()
            URLCache.shared.removeAllCachedResponses()
            removeContents(of: cachesDirectory(), preserving: preservedURLs, result: &result)
            removeContents(of: FileManager.default.temporaryDirectory, preserving: preservedURLs, result: &result)
            removeContents(of: screenRecordingImportDirectory(), preserving: preservedURLs, result: &result)
            removeInvisibleDraftResidue(preserving: drafts, result: &result)

            DispatchQueue.main.async {
                let websiteCacheTypes: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]
                WKWebsiteDataStore.default().removeData(ofTypes: websiteCacheTypes, modifiedSince: .distantPast) {
                    DispatchQueue.main.async {
                        completion(result)
                    }
                }
            }
        }
    }

    /// 删除录制完成后已经复制入草稿目录的临时源文件。
    static func removeTransientRecordingFiles(from originalProject: RecordingProject, keeping savedProject: RecordingProject? = nil) {
        let keptURLs = preservedVideoURLs(from: [savedProject].compactMap { $0 })
        let sourceURLs = [originalProject.mainVideoURL, originalProject.pipVideoURL].compactMap { $0 }
        sourceURLs.forEach { sourceURL in
            guard isTransientRecordingFile(sourceURL), !shouldPreserve(sourceURL, preserving: keptURLs) else { return }
            try? FileManager.default.removeItem(at: sourceURL)
        }
    }

    /// 返回用户缓存目录地址。
    private static func cachesDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }

    /// 返回屏幕录制导入临时目录地址。
    private static func screenRecordingImportDirectory() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(screenRecordingImportDirectoryName, isDirectory: true)
    }

    /// 返回草稿根目录地址。
    private static func draftsDirectory() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Drafts", isDirectory: true)
    }

    /// 收集需要保留的草稿视频文件地址。
    private static func preservedVideoURLs(from drafts: [RecordingProject]) -> Set<URL> {
        Set(drafts.flatMap { [$0.mainVideoURL, $0.pipVideoURL] }.compactMap { $0?.standardizedFileURL })
    }

    /// 删除目录下的所有内容，但保留明确传入的草稿视频文件。
    private static func removeContents(of directory: URL?, preserving preservedURLs: Set<URL>, result: inout AppStorageCleanupResult) {
        guard let directory,
              FileManager.default.fileExists(atPath: directory.path),
              let contents = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                          includingPropertiesForKeys: Array(sizeResourceKeys),
                                                                          options: []) else { return }
        contents.forEach { removeItem(at: $0, preserving: preservedURLs, result: &result) }
    }

    /// 删除首页不可见的坏草稿目录，避免“没有作品”但仍占用大量文稿与数据。
    private static func removeInvisibleDraftResidue(preserving drafts: [RecordingProject], result: inout AppStorageCleanupResult) {
        guard let directory = draftsDirectory(),
              FileManager.default.fileExists(atPath: directory.path),
              let contents = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                          includingPropertiesForKeys: [.isDirectoryKey],
                                                                          options: []) else { return }
        let visibleDraftFolderNames = Set(drafts.map { $0.id.uuidString })
        contents.forEach { draftURL in
            guard !visibleDraftFolderNames.contains(draftURL.lastPathComponent) else { return }
            removeItem(at: draftURL, preserving: [], result: &result)
        }
    }

    /// 删除单个文件或目录，并累计释放空间。
    private static func removeItem(at url: URL, preserving preservedURLs: Set<URL>, result: inout AppStorageCleanupResult) {
        guard !shouldPreserve(url, preserving: preservedURLs) else { return }
        let itemSize = allocatedSize(of: url)
        do {
            try FileManager.default.removeItem(at: url)
            result.addRemovedItem(bytes: itemSize)
        } catch {
            // 单个系统缓存文件删除失败不影响整体清理，继续处理其他项目。
        }
    }

    /// 判断目标路径是否需要保留，包含保留文件本身或其父目录。
    private static func shouldPreserve(_ url: URL, preserving preservedURLs: Set<URL>) -> Bool {
        let standardizedURL = url.standardizedFileURL
        return preservedURLs.contains { preservedURL in
            standardizedURL == preservedURL || preservedURL.path.hasPrefix(standardizedURL.path + "/")
        }
    }

    /// 判断文件是否属于录制过程产生的可清理临时文件。
    private static func isTransientRecordingFile(_ url: URL) -> Bool {
        isURL(url, inside: FileManager.default.temporaryDirectory) ||
        screenRecordingImportDirectory().map { isURL(url, inside: $0) } == true
    }

    /// 判断文件是否位于指定目录内部。
    private static func isURL(_ url: URL, inside directory: URL) -> Bool {
        let filePath = url.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        return filePath == directoryPath || filePath.hasPrefix(directoryPath + "/")
    }

    /// 计算文件或目录已分配磁盘空间，删除前用于估算释放大小。
    private static func allocatedSize(of url: URL) -> Int64 {
        if let values = try? url.resourceValues(forKeys: sizeResourceKeys), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }

        guard let enumerator = FileManager.default.enumerator(at: url,
                                                              includingPropertiesForKeys: Array(sizeResourceKeys),
                                                              options: []) else { return 0 }
        return enumerator.compactMap { item -> Int64? in
            guard let fileURL = item as? URL,
                  let values = try? fileURL.resourceValues(forKeys: sizeResourceKeys),
                  values.isRegularFile == true else { return nil }
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }.reduce(0, +)
    }
}
