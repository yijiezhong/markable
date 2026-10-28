import AppKit
import CoreText
import PDFKit

/// 目录页：在 PDF 最前插入一页目录（标题 + 页码）。
///
/// 页码来自"在正文页文本中查找标题"的近似定位——不需要源/视图分页映射，
/// 对本工具"文本层齐全"的 PDF 足够可用。查不到的条目只列标题、不显示页码。
enum PDFTOC {
    /// 生成一页目录页（尺寸与 `reference` 相同）。
    static func makePage(
        outline: [OutlineItem],
        title: String,
        pageSetup: PageSetup,
        existing: PDFDocument,
        pageIndexByHeading: [String: Int]? = nil
    ) -> PDFPage? {
        guard !outline.isEmpty else { return nil }

        let box = existing.page(at: 0)?.bounds(for: .mediaBox)
            ?? CGRect(origin: .zero, size: pageSetup.paper.pointSize)
        let data = NSMutableData()
        var mediaBox = box
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        context.beginPDFPage(nil)

        // 白色背景
        context.setFillColor(NSColor.white.cgColor)
        context.fill(box)

        let margin = CGFloat(pageSetup.marginMM) * 72.0 / 25.4
        let left = margin
        let right = box.width - margin
        var y = box.height - margin - 24

        // 标题
        if !title.isEmpty {
            draw(title, in: context, at: CGPoint(x: left, y: y),
                 font: CTFontCreateWithName("Helvetica-Bold" as CFString, 18, nil),
                 color: NSColor.labelColor.cgColor)
            y -= 34
        } else {
            y -= 6
        }

        // 分隔线
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: left, y: y + 6))
        context.addLine(to: CGPoint(x: right, y: y + 6))
        context.strokePath()
        y -= 14

        let entryFont = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        let boldFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 11.5, nil)
        let lineHeight: CGFloat = 22

        for item in outline {
            guard y > margin else { break }
            let indent = CGFloat(max(0, item.level - 1)) * 16
            let font = item.level == 1 ? boldFont : entryFont
            let color = (item.level == 1 ? NSColor.labelColor : NSColor.secondaryLabelColor).cgColor

            draw(item.title, in: context, at: CGPoint(x: left + indent, y: y), font: font, color: color)

            if let page = pageNumber(of: item.title, in: existing, pageIndexByHeading: pageIndexByHeading) {
                let label = String(page)
                let width = textWidth(label, font: entryFont)
                draw(label, in: context, at: CGPoint(x: right - width, y: y), font: entryFont,
                     color: NSColor.secondaryLabelColor.cgColor)
            }
            y -= lineHeight
        }

        context.endPDFPage()
        context.closePDF()

        let pdfData = data as Data
        return PDFDocument(data: pdfData)?.page(at: 0)
    }

    /// 在正文页文本里查找标题所在页（返回含目录页的 1-based 页码）。
    ///
    /// 查找走 `PDFTextNormalizer`：WebKit 写出的中文文本层会把汉字映射成
    /// 康熙部首 / CJK 兼容字符（`页` → `⻚`、`一` → `⼀`），按字面 `contains`
    /// 查不到中文标题；归一化后再比，并忽略大小写与空白差异。
    /// 查不到时返回 `nil`，调用方只列标题、不写页码（保持原有回退行为）。
    private static func pageNumber(of heading: String, in document: PDFDocument,
                                   pageIndexByHeading: [String: Int]? = nil) -> Int? {
        // 优先用分页器采集的标题锚点（精确、且不依赖 PDF 文本层的中文兼容问题）
        if let pageIndexByHeading {
            let key = PDFTextNormalizer.headingKey(heading)
            if let index = pageIndexByHeading[key] {
                return index + 2      // +1 转 1-based，+1 目录页
            }
        }
        let needle = heading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty,
              let selection = PDFTextNormalizer.findSelection(of: needle, in: document),
              let page = selection.pages.first else { return nil }
        let index = document.index(for: page)
        guard index >= 0, index < document.pageCount else { return nil }
        return index + 2      // +1 转 1-based，+1 因为目录页插在最前
    }

    // MARK: - 绘制辅助

    private static func draw(_ string: String, in context: CGContext, at point: CGPoint, font: CTFont, color: CGColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }

    private static func textWidth(_ string: String, font: CTFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}
