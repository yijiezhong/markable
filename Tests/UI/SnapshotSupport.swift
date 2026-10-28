import Foundation

/// 快照输出目录：默认写到仓库内 `.build/snapshots`（已被 git 忽略），
/// 可用 `MARKABLE_SNAPSHOT_DIR` 覆盖（例如 CI 收集产物）。
enum SnapshotSupport {
    static var outputDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["MARKABLE_SNAPSHOT_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return root.appendingPathComponent(".build/snapshots", isDirectory: true)
    }

    static func prepareOutputDirectory() throws -> URL {
        let dir = outputDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
