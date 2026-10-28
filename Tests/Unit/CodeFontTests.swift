import AppKit
import Testing
@testable import Markable

/// 代码字体方案：苹果官方字体 + 字距补偿（中文 = 2 × 西文）。
@MainActor
@Suite("CodeFont")
struct CodeFontTests {
    private func render(_ source: String, family: Typography.Family = .sans) -> NSTextStorage {
        var typography = Typography()
        typography.family = family
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.textContainer?.containerSize = NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        LivePreviewController().apply(to: textView, source: source, baseDirectory: nil,
                                      readOnly: true, fontSize: 14, typography: typography)
        return textView.textStorage!
    }

    @Test("代码块西文用 SF Mono、中文用苹方")
    func codeBlockFonts() {
        let storage = render("```\nlet a = 中文\n```")
        let ns = storage.string as NSString
        let latinRange = ns.range(of: "let")
        let chineseRange = ns.range(of: "中文")
        #expect(latinRange.location != NSNotFound)
        #expect(chineseRange.location != NSNotFound)
        if latinRange.location != NSNotFound {
            let font = storage.attributes(at: latinRange.location, effectiveRange: nil)[.font] as? NSFont
            #expect(font?.fontName == "SFMono-Regular", "西文实际：\(font?.fontName ?? "nil")")
        }
        if chineseRange.location != NSNotFound {
            let font = storage.attributes(at: chineseRange.location, effectiveRange: nil)[.font] as? NSFont
            #expect(font?.fontName == "PingFangSC-Regular", "中文实际：\(font?.fontName ?? "nil")")
            let kern = storage.attributes(at: chineseRange.location, effectiveRange: nil)[.kern] as? CGFloat
            #expect((kern ?? 0) > 0, "中文应带字距补偿")
        }
    }

    @Test("代码块中英混排 = 2:1（14pt 字号 → 13pt 代码字体）")
    func mixedWidthRatio() {
        let storage = render("```\n中文ab\n```")
        let ns = storage.string as NSString
        let range = ns.range(of: "中文ab")
        #expect(range.location != NSNotFound)
        guard range.location != NSNotFound else { return }
        let measured = storage.attributedSubstring(from: range).size().width
        let half = ("a" as NSString).size(withAttributes: [.font: CodeTypography.latinFont(size: 13, style: .sans)]).width
        let expected = 6 * half   // 2 中文（各 2 半角）+ 2 西文（各 1 半角）
        #expect(abs(measured - expected) < 0.1, "实测 \(measured)，期望 \(expected)")
    }

    @Test("衬线场景：Courier New + 宋体")
    func serifPair() {
        let storage = render("```\nlet a = 中文\n```", family: .serif)
        let ns = storage.string as NSString
        let latinRange = ns.range(of: "let")
        let chineseRange = ns.range(of: "中文")
        if latinRange.location != NSNotFound {
            let font = storage.attributes(at: latinRange.location, effectiveRange: nil)[.font] as? NSFont
            #expect(font?.fontName == "CourierNewPSMT", "西文实际：\(font?.fontName ?? "nil")")
        }
        if chineseRange.location != NSNotFound {
            let font = storage.attributes(at: chineseRange.location, effectiveRange: nil)[.font] as? NSFont
            #expect(font?.fontName == "STSongti-SC-Regular", "中文实际：\(font?.fontName ?? "nil")")
        }
    }

    @Test("HTML 导出：中文代码段带 code-cjk 与 letter-spacing")
    func htmlCodeCJK() {
        let html = HtmlRenderer().html(from: "```\n中文 code\n```", title: "t")
        #expect(html.contains("code-cjk"))
        #expect(html.contains("letter-spacing: 0.2363em"))
        #expect(html.contains(#"font-family: "SF Mono", Menlo, monospace"#))
    }

    @Test("HTML 导出（衬线）：Courier New + 宋体 + 0.2002em")
    func htmlSerifCode() {
        var renderer = HtmlRenderer()
        renderer.codeStyle = .serif
        let html = renderer.html(from: "```\n中文 code\n```", title: "t")
        #expect(html.contains("letter-spacing: 0.2002em"))
        #expect(html.contains(#""Courier New", Courier, monospace"#))
    }
}
