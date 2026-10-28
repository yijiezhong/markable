import Testing
import Foundation
import AppKit
import CoreText
import PDFKit
@testable import Markable

/// PDF 文本层归一化：康熙部首 / CJK 兼容字符 → 统一汉字，以及按归一化文本查找标题。
///
/// 覆盖两类问题：
/// 1. `normalize` 的映射正确性与「长度不变」不变量（保证命中范围能映射回原文）；
/// 2. `findSelection` / `PDFTOC` 对「文本层被 WebKit 换成部首」的中文标题仍能定位。
@Suite("PDFTextNormalizer")
struct PDFTextNormalizerTests {
    // MARK: - 归一化

    @Test("简化部首映射为统一汉字")
    func mapsSimplifiedRadicals() {
        #expect(PDFTextNormalizer.normalize("⻚⼀⻓") == "页一长")
        #expect(PDFTextNormalizer.normalize("⻘⻔⻢⻥⻦⻰") == "青门马鱼鸟龙")
        #expect(PDFTextNormalizer.normalize("⻣⻤⻧⻨⻩⻮⻳") == "骨鬼卤麦黄齿龟")
        #expect(PDFTextNormalizer.normalize("⺟⻪") == "母黾")
    }

    @Test("康熙部首（传统字形）映射为传统汉字")
    func mapsKangxiRadicals() {
        #expect(PDFTextNormalizer.normalize("⾴⾺⿂") == "頁馬魚")
        #expect(PDFTextNormalizer.normalize("⼀⼆⼗") == "一二十")
    }

    @Test("CJK 兼容表意文字映射为统一汉字")
    func mapsCompatibilityIdeographs() {
        #expect(PDFTextNormalizer.normalize("\u{F900}") == "豈")   // U+F900 → U+8C48
        #expect(PDFTextNormalizer.normalize("\u{F901}") == "更")   // U+F901 → U+66F4
        #expect(PDFTextNormalizer.normalize("\u{F902}") == "車")   // U+F902 → U+8ECA
    }

    @Test("其余字符原样保留")
    func preservesOtherText() {
        let text = "Chapter 1：中文标题 🚀 頁/页"
        #expect(PDFTextNormalizer.normalize(text) == text)
    }

    @Test("归一化保持字符数与 UTF-16 长度不变")
    func lengthInvariant() {
        let samples = [
            "⻚⼀⻓",
            "第一章 ⻚⻘⻓：引言（2024）",
            "⺟⻳豈𠀀🚀",
            "\u{F900}\u{F901}\u{FA0C}",
            "",
        ]
        for sample in samples {
            let normalized = PDFTextNormalizer.normalize(sample)
            #expect(normalized.count == sample.count, "字符数变了：\(sample)")
            #expect(normalized.utf16.count == sample.utf16.count, "UTF-16 长度变了：\(sample)")
            #expect(PDFTextNormalizer.normalize(normalized) == normalized, "归一化应当幂等：\(sample)")
        }
    }

    // MARK: - 查找（纯文本）

    @Test("命中范围映射回原文本")
    func mapsRangeBackToOriginal() throws {
        let pageText = "前言 ⻚⼀⻓ 后记"
        let range = try #require(PDFTextNormalizer.matchRange(of: "页一长", in: pageText))
        #expect((pageText as NSString).substring(with: range) == "⻚⼀⻓")
    }

    @Test("忽略空白差异")
    func ignoresWhitespace() {
        #expect(PDFTextNormalizer.matchRange(of: "页一长", in: "⻚ ⼀\n⻓") != nil)
        #expect(PDFTextNormalizer.matchRange(of: "页 一\n长", in: "⻚⼀⻓") != nil)
    }

    @Test("ASCII 标题不区分大小写")
    func ignoresCase() {
        #expect(PDFTextNormalizer.matchRange(of: "chapter 1", in: "Chapter 1") != nil)
        #expect(PDFTextNormalizer.matchRange(of: "ABC", in: "abc") != nil)
    }

    @Test("命中范围按 UTF-16 计算（emoji 占两个单元）")
    func rangeUsesUTF16Offsets() throws {
        let pageText = "🚀⻚⼀⻓"
        let range = try #require(PDFTextNormalizer.matchRange(of: "页一长", in: pageText))
        #expect(range.location == 2)
        #expect(range.length == 3)
    }

    @Test("查不到时返回 nil")
    func returnsNilWhenMissing() {
        #expect(PDFTextNormalizer.matchRange(of: "页一长", in: "无关内容") == nil)
        #expect(PDFTextNormalizer.matchRange(of: "   ", in: "无关内容") == nil)
    }

    // MARK: - 查找（PDF）

    @Test("按归一化文本命中中文标题")
    func findsNormalizedTitle() throws {
        let document = try #require(Self.makePDF(pages: ["⻚⼀⻓ 正文内容", "第二页内容"]))
        // 字面查找（旧实现的做法）在部首文本层上查不到，正是本工具要解决的场景。
        #expect(document.findString("页一长", withOptions: []).isEmpty,
                "字面查找应当查不到（说明测试夹具确实复现了兼容问题）")

        let selection = try #require(PDFTextNormalizer.findSelection(of: "页一长", in: document))
        #expect(selection.pages.first === document.page(at: 0))
        #expect(selection.string?.contains("⻚") == true)
        // 任务要求的最小用例：标题「页一」也要能在文本层「⻚⼀」上命中。
        #expect(PDFTextNormalizer.findSelection(of: "页一", in: document) != nil)
    }

    @Test("PDF 查找忽略换行与 ASCII 大小写")
    func findsAcrossLineBreaks() throws {
        let document = try #require(Self.makePDF(pages: ["⻚\n⼀\n⻓ ABC"]))
        let selection = try #require(PDFTextNormalizer.findSelection(of: "页一长 abc", in: document))
        #expect(selection.pages.first === document.page(at: 0))
    }

    @Test("PDF 中查不到时返回 nil")
    func missingInPDF() throws {
        let document = try #require(Self.makePDF(pages: ["无关内容"]))
        #expect(PDFTextNormalizer.findSelection(of: "页一长", in: document) == nil)
    }

    // MARK: - 目录页接线

    @Test("目录页对部首文本层的标题给出正确页码")
    func tocUsesNormalizedLookup() throws {
        let document = try #require(Self.makePDF(pages: ["⻚⼀⻓", "第⼆章 ⽅法", "结论"]))
        let page = try #require(PDFTOC.makePage(
            outline: [
                OutlineItem(title: "页一长", level: 1),
                OutlineItem(title: "第二章 方法", level: 2),
            ],
            title: "报告",
            pageSetup: PageSetup(paper: .a4, marginMM: 20),
            existing: document
        ))
        let text = page.string ?? ""
        #expect(text.contains("页一长"))
        #expect(text.contains("第二章 方法"))
        // 标题在第 1、2 页 → 加上目录页后分别为第 2、3 页；归一化失效时不会出现任何页码。
        #expect(text.contains("2"), "目录页码缺失：\(text)")
        #expect(text.contains("3"), "目录页码缺失：\(text)")
    }

    // MARK: - 测试夹具

    /// 生成多页 PDF：每页按 `\n` 分行绘制给定文本，使用覆盖部首字形的中文字体。
    private static func makePDF(pages: [String]) -> PDFDocument? {
        guard let font = hanFont(size: 14) else { return nil }

        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }

        for text in pages {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(box)
            var y: CGFloat = 720
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let attributed = NSAttributedString(string: String(line), attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                ])
                context.textPosition = CGPoint(x: 60, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
                y -= 26
            }
            context.endPDFPage()
        }
        context.closePDF()
        return PDFDocument(data: data as Data)
    }

    /// 选一个覆盖测试字符（部首 / 兼容汉字）的系统字体；都不可用时返回 nil。
    private static func hanFont(size: CGFloat) -> CTFont? {
        let probe = Array("⻚⼀⻓⾴母".utf16)
        for name in ["PingFang SC", "Heiti SC", "Hiragino Sans GB"] {
            let font = CTFontCreateWithName(name as CFString, size, nil)
            var glyphs = [CGGlyph](repeating: 0, count: probe.count)
            if CTFontGetGlyphsForCharacters(font, probe, &glyphs, probe.count), !glyphs.contains(0) {
                return font
            }
        }
        return nil
    }
}
