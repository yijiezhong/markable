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
        guard let text = Self.decode(data) else {
            throw DocumentError.notUTF8(path)
        }
        return Document(openedAt: path, content: text, modifiedAt: Self.modificationDate(of: path))
    }

    /// GB18030（兼容 GBK）：Darwin 的 Foundation 没有现成 `String.Encoding` 静态成员，用 CF 转换。
    static let gb18030: String.Encoding = {
        let cf = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }()

    /// 文本解码：UTF-8 优先，失败时回退常见中文编码（GB18030/GBK、UTF-16 各字节序）。
    /// 之前只认 UTF-8，遇到 GBK 编码的 .md 会静默失败，打开后是一个空白「未命名」窗口。
    static func decode(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        for encoding in [Self.gb18030, .utf16, .utf16LittleEndian, .utf16BigEndian, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return nil
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
