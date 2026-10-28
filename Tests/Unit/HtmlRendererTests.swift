import Testing
import Foundation
import AppKit
@testable import Markable

/// HTML 导出：带样式 / 纯内容两种形态。
@Suite("HtmlRenderer")
struct HtmlRendererTests {
    @Test("带样式包含 <style> 与正文标签")
    func styled() {
        let html = HtmlRenderer().html(from: "# 标题\n\n正文\n", title: "t")
        #expect(html.contains("<style>"))
        #expect(html.contains("<h1>标题</h1>"))
        #expect(html.contains("<p>正文</p>"))
    }

    @Test("纯内容不含 <style>，但保留语义标签")
    func plain() {
        let html = HtmlRenderer().html(from: "# 标题\n\n正文 **粗**\n", title: "t", styled: false)
        #expect(!html.contains("<style>"))
        #expect(html.contains("<h1>标题</h1>"))
        #expect(html.contains("<strong>粗</strong>"))
    }

    @Test("本地图片内联成 data URI，并带 alt 与 title")
    func localImage() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.writePNG(width: 4, height: 4, to: directory.appendingPathComponent("demo.png"))

        let html = HtmlRenderer().html(
            from: "![示意图](demo.png \"图 1\")\n",
            title: "t",
            baseDirectory: directory
        )
        #expect(html.contains("<img src=\"data:image/png;base64,"), "本地图片应内联为 data URI：\(html)")
        #expect(html.contains("alt=\"示意图\""))
        #expect(html.contains("title=\"图 1\""))
        // 不再依赖外部文件路径（WKWebView 的 about:blank 读不到 file://）。
        #expect(!html.contains("src=\"demo.png\""))
    }

    @Test("图片文件读不到时退化为 alt 文本，不产生破图")
    func missingLocalImage() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let html = HtmlRenderer().html(
            from: "![缺失图](nope.png)\n",
            title: "t",
            baseDirectory: directory
        )
        #expect(!html.contains("<img"))
        #expect(html.contains("缺失图"))
    }

    @Test("超过内联上限的图片退化为 alt 文本")
    func oversizedLocalImage() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.writePNG(width: 16, height: 16, to: directory.appendingPathComponent("big.png"))

        var renderer = HtmlRenderer()
        renderer.maxInlineImageBytes = 8
        let html = renderer.html(from: "![大图](big.png)\n", title: "t", baseDirectory: directory)
        #expect(!html.contains("<img"), "超过上限不应内联")
        #expect(html.contains("大图"))
    }

    @Test("远程图片不写入 src（阅读器不联网），保留 alt 占位")
    func remoteImageBlocked() {
        let sources = ["https://example.com/a.png", "http://example.com/a.png", "//cdn.example.com/a.png", "data:image/png;base64,AAAA"]
        for source in sources {
            let html = HtmlRenderer().html(from: "![远程图](\(source))\n", title: "t")
            #expect(!html.contains("<img"), "远程源不应输出 img：\(source)")
            #expect(html.contains("远程图"))
            #expect(!html.contains("src=\"\(source)\""))
        }
    }

    @Test("未知 scheme 不写入 src")
    func unsafeSchemeBlocked() {
        let html = HtmlRenderer().html(from: "![x](javascript:void)\n", title: "t")
        #expect(!html.contains("<img"))
        #expect(!html.contains("javascript:void"))
    }

    @Test("空源图片只保留 alt 文本")
    func emptySource() {
        let html = HtmlRenderer().html(from: "![只有文字]()\n", title: "t")
        #expect(!html.contains("<img"))
        #expect(html.contains("只有文字"))
    }

    @Test("图片带限高，不会高于一页")
    func imageMaxHeight() {
        let setup = PageSetup(paper: .a4, marginMM: 20)
        let html = HtmlRenderer().html(from: "![a](a.png)\n", title: "t", pageSetup: setup)
        // A4 内容区高 ≈ 728.5pt，限高预留 40pt 段落边距 → ≈ 688px。
        let expected = String(format: "%.0f", setup.contentSize.height - 40)
        #expect(html.contains("max-height: \(expected)px"))
        #expect(html.contains("max-width: 100%"))
    }

    @Test("表格输出真正的 table 结构（含列对齐）")
    func tableStructure() {
        let html = HtmlRenderer().html(
            from: "| 名称 | 数量 |\n|:---|--:|\n| 甲 | 1 |\n",
            title: "t"
        )
        #expect(html.contains("<table><thead><tr>"), "应输出 table/thead：\(html)")
        #expect(html.contains("<th style=\"text-align: left\">名称</th>"))
        #expect(html.contains("<th style=\"text-align: right\">数量</th>"))
        #expect(html.contains("<td style=\"text-align: left\">甲</td>"))
        #expect(html.contains("<td style=\"text-align: right\">1</td>"))
        #expect(html.contains("</tbody></table>"))
    }

    @Test("任务列表复选框保留状态")
    func taskCheckboxes() {
        let html = HtmlRenderer().html(from: "- [ ] 待办\n- [x] 完成\n", title: "t")
        #expect(html.contains("<input type=\"checkbox\" disabled>"), "未选中复选框缺失：\(html)")
        #expect(html.contains("<input type=\"checkbox\" disabled checked>"), "已选中复选框缺失：\(html)")
        #expect(html.contains("待办"))
        #expect(html.contains("完成"))
    }

    @Test("脚注渲染为上标 + 文末脚注区")
    func footnotes() {
        let html = HtmlRenderer().html(
            from: "正文[^1] 与另一个[^note]\n\n[^1]: 第一条\n[^note]: 第二条\n",
            title: "t"
        )
        #expect(html.contains("<sup><a id=\"fnref-1\" href=\"#fn-1\">1</a></sup>"), "脚注引用缺失：\(html)")
        #expect(html.contains("<sup><a id=\"fnref-note\" href=\"#fn-note\">note</a></sup>"))
        #expect(html.contains("<section class=\"footnotes\">"))
        #expect(html.contains("<li id=\"fn-1\">第一条 <a href=\"#fnref-1\">↩</a></li>"), "脚注项应有反向链接：\(html)")
        #expect(html.contains("<li id=\"fn-note\">第二条 <a href=\"#fnref-note\">↩</a></li>"))
        #expect(!html.contains("href=\"第一条\""), "定义行不应被当成链接")
    }

    @Test("代码块里的 [^1] 不被当作脚注")
    func footnoteInsideCode() {
        let html = HtmlRenderer().html(from: "```\n[^1] 字面\n```\n", title: "t")
        #expect(!html.contains("<sup>"))
        // 代码字体按全角/半角分段包 span，不能断言整串连续
        #expect(html.contains("[^1]"))
        #expect(html.contains("字面"))
    }

    @Test("危险链接 scheme 不写进 href，文字保留")
    func dangerousLinkSchemesBlocked() {
        let samples = [
            "javascript:alert(1)",
            "JavaScript:void",
            "data:text/html,<script>alert(1)</script>",
            "vbscript:msgbox",
        ]
        for sample in samples {
            let html = HtmlRenderer().html(from: "[危险](\(sample))\n", title: "t", styled: false)
            #expect(!html.contains("<a href"), "不应生成链接：\(sample) → \(html)")
            #expect(html.contains("危险"), "文字应保留：\(sample)")
            #expect(!html.contains("href=\"\(sample)\""))
        }
    }

    @Test("安全链接保留 a 标签")
    func safeLinksKeepAnchor() {
        let samples = ["https://example.com", "http://example.com", "mailto:a@b.com", "tel:123", "#anchor", "notes/a.md"]
        for sample in samples {
            let html = HtmlRenderer().html(from: "[链接](\(sample))\n", title: "t", styled: false)
            #expect(html.contains("<a href=\"\(sample)\">"), "应保留链接：\(sample) → \(html)")
        }
    }

    // MARK: - 测试素材

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("markable-html-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func writePNG(width: Int, height: Int, to url: URL) throws {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "HtmlRendererTests", code: 1)
        }
        try png.write(to: url)
    }
}
