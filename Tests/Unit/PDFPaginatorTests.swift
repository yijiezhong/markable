import AppKit
import PDFKit
import Testing
@testable import Markable

/// A4 分页：长 HTML 切成多页、每页尺寸等于纸张、文本层保留。
///
/// 注：WebKit 生成的中文文本层会把部分常用字映射成康熙部首 / 兼容字符
/// （`页` → `⻚`、`一` → `⼀`），所以这里用 ASCII 段落编号做文本断言；
/// 该现象与分页无关，旧的 `WKWebView.pdf()` 路径同样如此。
@MainActor
@Suite("PDFPaginator", .serialized)
struct PDFPaginatorTests {
    private static let pageSetup = PageSetup(paper: .a4, marginMM: 20)

    @Test("长文档切成多页，每页是纸张尺寸且保留文本层")
    func paginatesLongHTML() async throws {
        // 无窗口进程里 WKWebView 需要 AppKit 完成初始化。
        _ = NSApplication.shared

        let paginated = try await PDFPaginator().paginate(
            html: Self.longHTML(),
            pageSetup: Self.pageSetup
        )
        let document = paginated.document

        // (a) 约 3–4 页的内容必须切成多页（而不是一张长图）。
        #expect(document.pageCount > 1, "长文档应切成多页，实际 \(document.pageCount) 页")

        // (b) 每页尺寸 = 纸张点尺寸（A4 = 595.28 × 841.89，允许 0.5pt 误差）。
        let expected = Self.pageSetup.paper.pointSize
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index), "缺少第 \(index + 1) 页")
            let bounds = page.bounds(for: .mediaBox)
            #expect(abs(bounds.width - expected.width) <= 0.5,
                    "第 \(index + 1) 页宽度 \(bounds.width) ≠ \(expected.width)")
            #expect(abs(bounds.height - expected.height) <= 0.5,
                    "第 \(index + 1) 页高度 \(bounds.height) ≠ \(expected.height)")
        }

        // (c) 每页文本层非空（WKWebView 生成的是矢量 PDF，可搜索 / 可复制）。
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index))
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(!text.isEmpty, "第 \(index + 1) 页没有文本层")
        }
    }

    /// `PDFExporter.export` 已切到分页路径：正文多页，且目录页 / 书签 / 盖章照常工作。
    @Test("导出走分页路径，目录页、书签与页脚仍可用")
    func exporterUsesPagination() async throws {
        _ = NSApplication.shared

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("markable-paginator-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        let report = try await PDFExporter().export(
            html: Self.longHTML(),
            outline: [
                OutlineItem(title: "PARA-001", level: 1),
                OutlineItem(title: "PARA-030", level: 1),
            ],
            to: url,
            pageSetup: Self.pageSetup,
            stamp: PDFStamp(header: "{title}", footer: "第 {page} / {total} 页"),
            title: "分页测试",
            includeTOC: true
        )

        let document = try #require(PDFDocument(url: url), "导出的 PDF 无法读回")
        // 多页正文 + 1 页目录。
        #expect(document.pageCount >= 3, "应包含多页正文与目录页，实际 \(document.pageCount) 页")
        #expect(report.hasOutline)

        // 目录页在最前：两条标题都列出来了。ASCII 标题的页码由 PDFTOC 在分页后的正文里
        // 回查——PARA-001 在正文第 1 页，插入目录页后是第 2 页。
        let tocText = document.page(at: 0)?.string ?? ""
        #expect(tocText.contains("PARA-001 2"), "目录页应给出 PARA-001 的页码")
        #expect(tocText.contains("PARA-030"), "目录页应列出后续标题")

        // 书签仍写入（书签节点必须带 destination 才会持久化）。
        #expect((document.outlineRoot?.numberOfChildren ?? 0) == 2, "两个标题应产生两条书签")

        // 页脚占位符按实际总页数展开并烧进第 1 页。
        let footer = "第 1 / \(document.pageCount)"
        #expect((document.page(at: 0)?.string ?? "").contains(footer), "页脚应写进第 1 页")
    }

    /// 约 3–4 页 A4 的内容：40 段带编号的中文正文，便于人工核对跨页。
    private static func longHTML() -> String {
        var body = ""
        for index in 1...40 {
            body += "<p>PARA-\(String(format: "%03d", index)) 这是一段用于验证 A4 分页的中文正文，"
            body += "长度足够换行，确保每页都有可提取的文字。段落序号 \(index)。</p>\n"
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system, "PingFang SC", sans-serif; font-size: 11pt; line-height: 1.7; color: #1f2329; margin: 0; }
        p { margin: 0 0 8px 0; }
        </style></head><body>\(body)</body></html>
        """
    }
}
