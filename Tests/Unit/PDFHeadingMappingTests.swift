import AppKit
import PDFKit
import Testing
@testable import Markable

/// 标题锚点 → 目录页码 / 书签：中文标题也必须有页码与目标页。
@MainActor
@Suite("PDFHeadingMapping", .serialized)
struct PDFHeadingMappingTests {
    private func html() -> String {
        var body = ""
        for index in 0..<6 {
            body += "<p>正文段落 \(index)：用于撑开内容，验证分页与标题定位。</p>\n"
        }
        return """
        <html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system; font-size: 16px; margin: 0; }
        h1 { font-size: 28px; } h2 { font-size: 20px; }
        p { margin: 12px 0; }
        </style></head><body>
        <h1>总标题</h1>
        \(body)
        <h2>第一章 概述</h2>
        \(body)
        <h2>第二章 细节</h2>
        \(body)
        </body></html>
        """
    }

    private func outline() -> [OutlineItem] {
        [
            OutlineItem(title: "总标题", level: 1),
            OutlineItem(title: "第一章 概述", level: 2),
            OutlineItem(title: "第二章 细节", level: 2),
        ]
    }

    @Test("中文标题经锚点映射到目录页码与书签")
    func chineseHeadingsMapToPages() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("markable-heading-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        let report = try await PDFExporter().export(
            html: html(), outline: outline(), to: url,
            pageSetup: PageSetup(), stamp: nil, title: "标题映射测试", includeTOC: true
        )
        #expect(report.hasOutline)

        guard let document = PDFDocument(url: url) else {
            Issue.record("PDF 读取失败：\(url.lastPathComponent)")
            return
        }
        #expect(document.pageCount >= 2, "应有内容页 + 目录页，实际 \(document.pageCount) 页")

        // 目录页在索引 0，包含三个标题与页码数字
        // 目录页由 CoreText 绘制，文本层同样可能带康熙部首（第⼀章），断言前先归一化
        let tocText = PDFTextNormalizer.normalize(document.page(at: 0)?.string ?? "")
        #expect(tocText.contains("总标题"))
        #expect(tocText.contains("第一章"))
        #expect(tocText.contains("第二章"))
        #expect(tocText.rangeOfCharacter(from: .decimalDigits) != nil, "目录页应写出页码")

        // 书签：3 个节点，目标页都在目录页之后（索引 >= 1）
        guard let root = document.outlineRoot else {
            Issue.record("导出结果缺少书签")
            return
        }
        #expect(root.numberOfChildren == 3)
        for index in 0..<root.numberOfChildren {
            guard let node = root.child(at: index), let page = node.destination?.page else {
                Issue.record("书签 \(index) 缺少目标页")
                continue
            }
            let pageIndex = document.index(for: page)
            #expect(pageIndex >= 1, "书签 \(index) 应指向内容页，实际索引 \(pageIndex)")
        }
    }

    @Test("headingKey 归一化空白与大小写")
    func headingKeyNormalizes() {
        #expect(PDFTextNormalizer.headingKey(" 第一章   概述 ") == PDFTextNormalizer.headingKey("第一章概述"))
        #expect(PDFTextNormalizer.headingKey("Chapter One") == PDFTextNormalizer.headingKey("chapterone"))
        #expect(PDFTextNormalizer.headingKey("⻚⼀") == "页一")
    }
}
