import Foundation

/// 草稿本地存储：把 RecordingProject 及其视频文件持久化到 Documents/Drafts。
public final class DraftStore {

    public static let shared = DraftStore()
    private init() { try? FileManager.default.createDirectory(at: draftsDir, withIntermediateDirectories: true) }

    private let fm = FileManager.default

    private var draftsDir: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Drafts", isDirectory: true)
    }

    private func dir(for id: UUID) -> URL {
        draftsDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// 保存草稿：把视频文件复制进草稿目录并落盘元数据。返回持久化后的 project。
    @discardableResult
    public func save(_ project: RecordingProject) throws -> RecordingProject {
        var p = project
        p.isDraft = true
        let folder = dir(for: p.id)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        if let main = p.mainVideoURL {
            p.mainVideoURL = try persistFile(main, into: folder, basename: "main")
        }
        if let pip = p.pipVideoURL {
            p.pipVideoURL = try persistFile(pip, into: folder, basename: "pip")
        }

        let data = try JSONEncoder().encode(p)
        try data.write(to: folder.appendingPathComponent("project.json"))
        return p
    }

    /// 若文件已在草稿目录内则不复制，否则复制进目标目录。
    private func persistFile(_ src: URL, into folder: URL, basename: String) throws -> URL {
        let ext = src.pathExtension.isEmpty ? "mov" : src.pathExtension
        let name = "\(basename).\(ext)"
        let dest = folder.appendingPathComponent(name)
        if src.standardizedFileURL == dest.standardizedFileURL { return dest }
        try removeExistingFiles(in: folder, basename: basename)
        try fm.copyItem(at: src, to: dest)
        return dest
    }

    private func removeExistingFiles(in folder: URL, basename: String) throws {
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.deletingPathExtension().lastPathComponent == basename {
            try fm.removeItem(at: file)
        }
    }

    /// 载入全部草稿，按创建时间倒序。
    public func loadAll() -> [RecordingProject] {
        guard let subdirs = try? fm.contentsOfDirectory(at: draftsDir,
                                                        includingPropertiesForKeys: nil) else { return [] }
        var result: [RecordingProject] = []
        for sub in subdirs {
            let json = sub.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: json),
                  var p = try? JSONDecoder().decode(RecordingProject.self, from: data) else { continue }
            // 修正为当前绝对路径（沙盒路径可能变化，用文件名重建）
            p.mainVideoURL = existingFile(sub, basename: "main")
            p.pipVideoURL = existingFile(sub, basename: "pip")
            result.append(p)
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    private func existingFile(_ folder: URL, basename: String) -> URL? {
        let candidates = ["mp4", "mov", "m4v"].map { folder.appendingPathComponent("\(basename).\($0)") }
        if let existing = candidates.first(where: { fm.fileExists(atPath: $0.path) }) {
            return existing
        }
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.deletingPathExtension().lastPathComponent == basename }
    }

    public func delete(_ id: UUID) throws {
        let folder = dir(for: id)
        guard fm.fileExists(atPath: folder.path) else { return }
        try fm.removeItem(at: folder)
    }
}
