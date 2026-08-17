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
            p.mainVideoURL = try persistFile(main, into: folder, name: "main.mov")
        }
        if let pip = p.pipVideoURL {
            p.pipVideoURL = try persistFile(pip, into: folder, name: "pip.mov")
        }

        let data = try JSONEncoder().encode(p)
        try data.write(to: folder.appendingPathComponent("project.json"))
        return p
    }

    /// 若文件已在草稿目录内则不复制，否则复制进目标目录。
    private func persistFile(_ src: URL, into folder: URL, name: String) throws -> URL {
        let dest = folder.appendingPathComponent(name)
        if src.standardizedFileURL == dest.standardizedFileURL { return dest }
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
        try fm.copyItem(at: src, to: dest)
        return dest
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
            p.mainVideoURL = existingFile(sub, "main.mov")
            p.pipVideoURL = existingFile(sub, "pip.mov")
            result.append(p)
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    private func existingFile(_ folder: URL, _ name: String) -> URL? {
        let url = folder.appendingPathComponent(name)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    public func delete(_ id: UUID) {
        try? fm.removeItem(at: dir(for: id))
    }
}
