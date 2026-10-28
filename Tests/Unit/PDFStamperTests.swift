import Testing
import Foundation
import AppKit
import PDFKit
@testable import Markable

/// 页眉 / 页脚：占位符替换 + 盖章后文字可提取（说明确实写进了 PDF）。
@Suite("PDFStamper")
struct PDFStamperTests {
    @Test("占位符替换")
    func placeholders() {
        let stamp = PDFStamp(header: "{title}", footer: "第 {page} / {total} 页")
        #expect(stamp.isEnabled)
        #expect(stamp.render(stamp.header, title: "年报", page: 1, total: 3) == "年报")
        #expect(stamp.render(stamp.footer, title: "年报", page: 2, total: 3) == "第 2 / 3 页")
    }

    @Test("空模板不算启用")
    func disabled() {
        #expect(!PDFStamp().isEnabled)
        #expect(!PDFStamp(header: "", footer: "").isEnabled)
    }

    @Test("盖章后页数不变且页眉文字可提取")
    func stamping() throws {
        let source = try Self.makeOnePagePDF()
        let stamped = PDFStamper.stamp(
            source,
            header: "REPORT",
            footer: "PAGE {page}/{total}",
            title: "t",
            pageSetup: PageSetup(paper: .a4, marginMM: 20)
        )
        let doc = try #require(stamped)
        #expect(doc.pageCount == 1)
        let text = doc.page(at: 0)?.string ?? ""
        #expect(text.contains("REPORT"))
        #expect(text.contains("PAGE 1/1"))
    }

    /// 生成一份单页空白 PDF（不依赖 WKWebView）。
    private static func makeOnePagePDF() throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(box)
        context.endPDFPage()
        context.closePDF()
        return try #require(PDFDocument(data: data as Data))
    }
}
