import Testing
import Foundation
@testable import Markable

/// 批量导出：文件收集与相对目录还原。
@Suite("BatchExporter")
struct BatchExporterTests {
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-test-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("sub/deep"), withIntermediateDirectories: true)
        try "# A\n".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "# B\n".write(to: root.appendingPathComponent("sub/b.md"), atomically: true, encoding: .utf8)
        try "# C\n".write(to: root.appendingPathComponent("sub/deep/c.md"), atomically: true, encoding: .utf8)
        try "ignored\n".write(to: root.appendingPathComponent("sub/note.txt"), atomically: true, encoding: .utf8)
        return root
    }

    @Test("递归收集 .md，忽略其它扩展名")
    func collectsMarkdown() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = BatchExporter.markdownFiles(under: root)
        #expect(files.count == 3)
        #expect(files.allSatisfy { $0.pathExtension == "md" })
        // 排序稳定
        #expect(files == files.sorted { $0.path < $1.path })
    }

    @Test("相对目录还原嵌套结构")
    func relativeDirectories() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = BatchExporter.markdownFiles(under: root)
        let mapping = Dictionary(uniqueKeysWithValues: files.map {
            ($0.deletingPathExtension().lastPathComponent, BatchExporter.relativeDirectory(of: $0, under: root))
        })
        #expect(mapping["a"] == "")
        #expect(mapping["b"] == "sub")
        #expect(mapping["c"] == "sub/deep")
    }

    @Test("空目录返回空列表")
    func empty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(BatchExporter.markdownFiles(under: root).isEmpty)
    }
}
