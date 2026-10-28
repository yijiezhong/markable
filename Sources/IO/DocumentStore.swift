import Foundation

/// 保存结果。冲突时**不写入**（FR-007、宪法 I）。
enum SaveOutcome: Equatable {
    case saved(mtimeMs: Int64)
    case conflict(currentMtimeMs: Int64)
}

/// 文件 IO 契约（见 contracts/native-services.md）。
protocol DocumentStore {
    func open(path: URL) throws -> Document
    func save(_ document: Document, to path: URL, expectedMtimeMs: Int64) throws -> SaveOutcome
    func saveAs(_ document: Document, to path: URL) throws -> SaveOutcome
}

/// 基于本地文件系统的实现：纯 Markdown，无锁定格式。
struct FileDocumentStore: DocumentStore {
    func open(path: URL) throws -> Document {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw DocumentError.notFound(path)
        }
        let data = try Data(contentsOf: path)
        guard let text = String(data: data, encoding: .utf8) else {
            throw DocumentError.notUTF8(path)
        }
        return Document(openedAt: path, content: text, modifiedAt: Self.modificationDate(of: path))
    }

    func save(_ document: Document, to path: URL, expectedMtimeMs: Int64) throws -> SaveOutcome {
        let current = Self.mtimeMs(of: path)
        // 磁盘文件在编辑期间被外部修改 → 冲突，禁止静默覆盖。
        if current != expectedMtimeMs {
            return .conflict(currentMtimeMs: current)
        }
        try document.content.write(to: path, atomically: true, encoding: .utf8)
        return .saved(mtimeMs: Self.mtimeMs(of: path))
    }

    func saveAs(_ document: Document, to path: URL) throws -> SaveOutcome {
        try document.content.write(to: path, atomically: true, encoding: .utf8)
        return .saved(mtimeMs: Self.mtimeMs(of: path))
    }

    // MARK: - Helpers

    static func modificationDate(of path: URL) -> Date? {
        try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    static func mtimeMs(of path: URL) -> Int64 {
        guard let date = modificationDate(of: path) else { return 0 }
        return Int64(date.timeIntervalSince1970 * 1000)
    }
}
