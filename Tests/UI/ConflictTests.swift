import Testing
import Foundation
@testable import Markable

/// T026：DocumentStore 冲突集成测试（真实临时文件）。
@Suite("DocumentStore 冲突")
struct ConflictTests {
    @Test("外部修改后保存返回 conflict 且不写入磁盘")
    func conflictDetectedAndNotWritten() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("markable-\(UUID().uuidString).md")
        try "# B\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileDocumentStore()
        // 用 1 秒前的 mtime 作为"打开时"记录 → 与当前磁盘 mtime 不一致
        let staleMtime = FileDocumentStore.mtimeMs(of: url) - 1000
        let doc = Document(openedAt: url, content: "# C\n", modifiedAt: nil)

        let outcome = try store.save(doc, to: url, expectedMtimeMs: staleMtime)

        if case .conflict = outcome {
            // 期望分支
        } else {
            Issue.record("应返回 conflict，实际：\(outcome)")
        }
        // 磁盘内容必须保持未变
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == "# B\n")
    }

    @Test("mtime 一致时正常写入")
    func savesWhenMtimeMatches() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("markable-\(UUID().uuidString).md")
        try "# A\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileDocumentStore()
        let doc = Document(openedAt: url, content: "# 新版\n", modifiedAt: nil)
        let current = FileDocumentStore.mtimeMs(of: url)

        let outcome = try store.save(doc, to: url, expectedMtimeMs: current)
        if case .saved = outcome {} else { Issue.record("应 saved") }
        #expect(try String(contentsOf: url, encoding: .utf8) == "# 新版\n")
    }
}
