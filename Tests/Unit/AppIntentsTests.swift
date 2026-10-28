import Testing
import AppIntents
import Foundation
@testable import Markable

/// App Intents：定义完整性（意图本体）+ 服务层可执行性。
@Suite("AppIntents")
struct AppIntentsTests {
    @Test("注册了预期的快捷指令")
    func shortcuts() {
        #expect(MarkableShortcuts.appShortcuts.count == 3)
    }

    @Test("意图标题/描述与运行方式")
    func metadata() {
        #expect(!String(localized: OpenDocumentIntent.title).isEmpty)
        #expect(!String(localized: ExportDocumentIntent.title).isEmpty)
        #expect(!String(localized: DocumentStatsIntent.title).isEmpty)
        #expect(OpenDocumentIntent.openAppWhenRun == true)     // 打开需要界面
        #expect(ExportDocumentIntent.openAppWhenRun == false)   // 导出无需界面
    }

    @Test("导出格式与默认输出路径")
    func formatAndDestination() {
        let source = URL(fileURLWithPath: "/tmp/a/b.md")
        #expect(ExportFormatOption.pdf.pathExtension == "pdf")
        #expect(DocumentExportService.defaultDestination(for: source, format: .html).lastPathComponent == "b.html")
        #expect(DocumentExportService.defaultDestination(for: source, format: .pdf).lastPathComponent == "b.pdf")
    }

    @Test("导出服务写出 HTML")
    func exportServiceHTML() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("svc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("doc.md")
        try "# 标题\n\n正文 **粗体**。\n".write(to: source, atomically: true, encoding: .utf8)
        let destination = dir.appendingPathComponent("out.html")

        let written = try await DocumentExportService.export(markdownAt: source, to: destination, format: .html)
        #expect(written.lastPathComponent == "out.html")
        let html = try String(contentsOf: destination, encoding: .utf8)
        #expect(html.contains("<h1>标题</h1>"))
        #expect(html.contains("<strong>粗体</strong>"))
    }

    @Test("统计服务返回一行描述")
    func statsService() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("svc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("doc.md")
        try "一二三四五\n".write(to: source, atomically: true, encoding: .utf8)
        let line = try DocumentExportService.statsLine(markdownAt: source)
        #expect(line.contains("字数"))
        #expect(line.contains("字符"))
    }
}
