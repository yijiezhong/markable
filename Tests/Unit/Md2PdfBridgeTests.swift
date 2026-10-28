import Foundation
import PDFKit
import Testing
@testable import Markable

@Suite("Md2PdfBridge", .serialized)
struct Md2PdfBridgeTests {
    @Test("工具探测：优先返回最新 Rust 版 md2pdf")
    func toolProbeIsConsistent() {
        if let url = Md2PdfBridge.toolURL() {
            #expect(FileManager.default.isExecutableFile(atPath: url.path))
            #expect(["md2pdf", "md2pdf-cn"].contains(url.lastPathComponent))
            #expect(
                Md2PdfBridge.isRustPipeline(atPath: url.path),
                "探测到的工具必须是 Rust 版且版本 ≥ \(Md2PdfBridge.minimumVersion)"
            )
        }
        #expect(Md2PdfBridge.isAvailable == (Md2PdfBridge.toolURL() != nil))
    }

    @Test("版本解析：只认 Rust 版输出，且门槛为 1.3.0")
    func versionParsing() {
        if let v = Md2PdfBridge.parseVersion("md2pdf 1.3.0") {
            #expect(v == (1, 3, 0))
        } else {
            Issue.record("md2pdf 1.3.0 应能解析出版本")
        }
        if let v = Md2PdfBridge.parseVersion("md2pdf 1.2.1\n") {
            #expect(v == (1, 2, 1))
        } else {
            Issue.record("md2pdf 1.2.1 应能解析出版本")
        }
        #expect(Md2PdfBridge.parseVersion("md2pdf-cn 1.3.0") == nil)
        #expect(Md2PdfBridge.parseVersion("Python 3.9.6") == nil)
        #expect(Md2PdfBridge.isValidVersion((1, 3, 0)))
        #expect(!Md2PdfBridge.isValidVersion((1, 2, 1)))
        #expect(!Md2PdfBridge.isValidVersion((1, 0, 0)))
    }

    @Test("工具存在时把 Markdown 导出为 A4 PDF")
    func bridgeExportsWhenAvailable() async throws {
        // 本机未安装 Rust 版 md2pdf 时不适用（桥接会自动回退内置导出）
        guard Md2PdfBridge.isAvailable else { return }

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("markable-md2pdf-\(UUID().uuidString)")
        let markdown = base.appendingPathExtension("md")
        let pdf = base.appendingPathExtension("pdf")
        defer {
            try? FileManager.default.removeItem(at: markdown)
            try? FileManager.default.removeItem(at: pdf)
        }

        try """
        # 桥接测试

        第一段。

        ## 第二节

        第二段。
        """.write(to: markdown, atomically: true, encoding: .utf8)

        _ = try await Md2PdfBridge.export(markdown: markdown, to: pdf, title: "桥接测试")

        #expect(FileManager.default.fileExists(atPath: pdf.path))
        let document = PDFDocument(url: pdf)
        #expect((document?.pageCount ?? 0) >= 1)
        // md2pdf 走 A4 纸张（约 595×842pt），与内置导出的单页长纸可区分
        if let page = document?.page(at: 0) {
            let box = page.bounds(for: .mediaBox)
            #expect(abs(box.width - 595.2) < 2, "页面宽度应为 A4：\(box.width)")
        }
    }

    /// 设置里的「强制内置导出」必须真的绕开 md2pdf，否则纸张/页眉页脚设置仍然是空转。
    @MainActor
    @Test("preferBuiltin 强制走内置通道")
    func preferBuiltinForcesBuiltinChannel() async throws {
        _ = NSApplication.shared

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("markable-prefer-builtin-\(UUID().uuidString)")
        let markdown = base.appendingPathExtension("md")
        let pdf = base.appendingPathExtension("pdf")
        defer {
            try? FileManager.default.removeItem(at: markdown)
            try? FileManager.default.removeItem(at: pdf)
        }

        try """
        # 强制内置

        > 引用一段

        正文。
        """.write(to: markdown, atomically: true, encoding: .utf8)

        let result = try await PDFDelivery.export(
            markdownURL: markdown, to: pdf, title: "强制内置",
            pageSetup: PageSetup(), preferBuiltin: true
        )

        #expect(result.channel == .builtin, "preferBuiltin 时应走内置通道，实际 \(result.channel)")
        #expect(FileManager.default.fileExists(atPath: pdf.path))
        let document = PDFDocument(url: pdf)
        #expect((document?.pageCount ?? 0) >= 1)
        // 内置通道按 A4 点尺寸出页。
        if let page = document?.page(at: 0) {
            let box = page.bounds(for: .mediaBox)
            #expect(abs(box.width - 595.2) < 2, "内置通道应为 A4：\(box.width)")
        }
    }
}
