import AppKit
import CoreText
import PDFKit

/// 页眉 / 页脚配置。文本支持占位符：`{title}`、`{page}`、`{total}`。
struct PDFStamp: Equatable {
    var header: String = ""
    var footer: String = ""
    var isEnabled: Bool { !header.isEmpty || !footer.isEmpty }

    /// 用实际值替换占位符。
    func render(_ template: String, title: String, page: Int, total: Int) -> String {
        template
            .replacingOccurrences(of: "{title}", with: title)
            .replacingOccurrences(of: "{page}", with: String(page))
            .replacingOccurrences(of: "{total}", with: String(total))
    }
}

/// 给已生成的 PDF 逐页加上页眉 / 页脚。
///
/// 做法：把每一页用 Core Graphics 重画进一个新的 PDF 上下文，再在页边距区域用 Core Text
/// 绘制页眉/页脚文字。这样文字是"烧进"PDF 的（不依赖批注显示），并保留原页面的文本层。
enum PDFStamper {
    static func stamp(
        _ document: PDFDocument,
        header: String,
        footer: String,
        title: String,
        pageSetup: PageSetup
    ) -> PDFDocument? {
        let total = document.pageCount
        guard total > 0 else { return nil }

        let marginPt = CGFloat(pageSetup.marginMM) * 72.0 / 25.4
        let fontSize: CGFloat = 9
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let color = NSColor.secondaryLabelColor.cgColor

        let data = NSMutableData()
        var defaultBox = document.page(at: 0)?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &defaultBox, nil) else {
            return nil
        }

        for index in 0..<total {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .mediaBox)
            let pageInfo: [CFString: Any] = [kCGPDFContextMediaBox: Self.mediaBoxData(box)]
            context.beginPDFPage(pageInfo as CFDictionary)

            page.draw(with: .mediaBox, to: context)

            context.saveGState()
            if !header.isEmpty {
                let text = PDFStamp(header: header).render(header, title: title, page: index + 1, total: total)
                drawCentered(text, in: context, box: box,
                             baselineY: box.height - max(fontSize, marginPt * 0.5) - 2,
                             font: font, color: color)
            }
            if !footer.isEmpty {
                let text = PDFStamp(footer: footer).render(footer, title: title, page: index + 1, total: total)
                drawCentered(text, in: context, box: box,
                             baselineY: max(4, marginPt * 0.5),
                             font: font, color: color)
            }
            context.restoreGState()

            context.endPDFPage()
        }
        context.closePDF()

        return PDFDocument(data: data as Data)
    }

    /// 在页面水平居中位置绘制一行文字（Core Text，y 轴向上）。
    private static func drawCentered(
        _ text: String,
        in context: CGContext,
        box: CGRect,
        baselineY: CGFloat,
        font: CTFont,
        color: CGColor
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(x: box.midX - CGFloat(width) / 2, y: baselineY)
        CTLineDraw(line, context)
    }

    /// CGRect → CFData（作为 `kCGPDFContextMediaBox` 的值）。
    private static func mediaBoxData(_ rect: CGRect) -> CFData {
        var value = rect
        return withUnsafeBytes(of: &value) { buffer in
            CFDataCreate(nil, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)!
        }
    }
}
