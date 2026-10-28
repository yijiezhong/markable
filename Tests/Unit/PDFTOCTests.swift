import Testing
import Foundation
import AppKit
import CoreText
import PDFKit
@testable import Markable

/// 目录页：生成单页目录，标题与页码可提取。
@Suite("PDFTOC")
struct PDFTOCTests {
    @Test("目录页列出标题与页码")
    func tocPage() throws {
        let source = try Self.makeTextPDF(pages: ["第一章 引言", "第二章 方法", "第三章 结论"])
        let page = try #require(PDFTOC.makePage(
            outline: [
                OutlineItem(title: "第一章 引言", level: 1),
                OutlineItem(title: "第二章 方法", level: 1),
            ],
            title: "我的报告",
            pageSetup: PageSetup(paper: .a4, marginMM: 20),
            existing: source
        ))
        let text = page.string ?? ""
        #expect(text.contains("我的报告"))
        #expect(text.contains("第一章 引言"))
        #expect(text.contains("第二章 方法"))
        // 第一章在正文第 1 页 → 含目录页后为第 2 页；第二章为第 3 页
        #expect(text.contains("2"))
        #expect(text.contains("3"))
    }

    @Test("空大纲返回 nil")
    func emptyOutline() throws {
        let source = try Self.makeTextPDF(pages: ["正文"])
        #expect(PDFTOC.makePage(outline: [], title: "t", pageSetup: PageSetup(), existing: source) == nil)
    }

    /// 生成一份多页 PDF，每页含一行给定文字。
    private static func makeTextPDF(pages: [String]) throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        for text in pages {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(box)
            context.textPosition = CGPoint(x: 60, y: 700)
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ])
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            context.endPDFPage()
        }
        context.closePDF()
        return try #require(PDFDocument(data: data as Data))
    }
}
