import Testing
import Foundation
@testable import Markable

/// Wiki 链接索引：出链解析、别名、反链。
@Suite("WikiLinkIndex")
struct WikiLinkIndexTests {
    @Test("解析出链（含别名、去重）")
    func outgoing() {
        let text = """
        见 [[阿尔法]] 与 [[贝塔|第二个]]。
        又提到 [[阿尔法]]。
        """
        let links = WikiLinkIndex.outgoingLinks(in: text)
        #expect(links.map(\.target) == ["阿尔法", "贝塔"])
        #expect(links[0].line == 1)
    }

    @Test("单行多目标")
    func multiplePerLine() {
        #expect(WikiLinkIndex.targets(in: "[[A]] 和 [[B|乙]]") == ["A", "B"])
    }

    @Test("反链：其它文件指向当前文档")
    func backlinks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("目标.md")
        let source = dir.appendingPathComponent("来源.md")
        let other = dir.appendingPathComponent("无关.md")
        try "# 目标\n".write(to: target, atomically: true, encoding: .utf8)
        try "参考 [[目标]] 的内容\n".write(to: source, atomically: true, encoding: .utf8)
        try "什么都不链接\n".write(to: other, atomically: true, encoding: .utf8)

        let links = WikiLinkIndex.backlinks(for: "目标", files: [target, source, other], currentFile: target)
        #expect(links.count == 1)
        #expect(links[0].file.lastPathComponent == "来源.md")
        #expect(links[0].line == 1)
    }

    @Test("按名字解析同目录文件（忽略扩展名与大小写）")
    func resolve() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-res-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Notes.md")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        #expect(WikiLinkIndex.resolve(target: "notes", in: dir)?.lastPathComponent == "Notes.md")
        #expect(WikiLinkIndex.resolve(target: "missing", in: dir) == nil)
    }
}
