import AppKit
import Testing
@testable import Markable

/// 行内代码保护与引用块样式：
/// - 反引号内的 `<br>` 保持字面（不被替换为行分隔符）；
/// - 引用块必须有灰底（`backgroundColor`），而不是只把文字变灰。
@MainActor
@Suite("InlineCodeAndQuote")
struct InlineCodeAndQuoteTests {
    private func render(_ source: String, width: CGFloat = 760) -> NSTextStorage {
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        LivePreviewController().apply(to: textView, source: source, baseDirectory: nil,
                                      readOnly: true, fontSize: 14, typography: Typography())
        return textView.textStorage!
    }

    @Test("行内代码里的 <br> 保持字面，只有普通 <br> 变成换行")
    func inlineCodeBrStaysLiteral() {
        let storage = render("行内 `<br>` 代码与普通 <br> 换行。")
        let text = storage.string
        let literalCount = text.components(separatedBy: "<br>").count - 1
        #expect(literalCount == 1, "反引号内的 <br> 应字面保留，实际出现 \(literalCount) 次")
        #expect(text.contains("\u{2028}"), "普通 <br> 应替换为行分隔符")
    }

    @Test("行内代码里的 <br> 仍按行内代码样式渲染")
    func inlineCodeBrKeepsCodeStyle() {
        let storage = render("行内 `<br>` 代码。")
        let ns = storage.string as NSString
        let br = ns.range(of: "<br>")
        #expect(br.location != NSNotFound)
        if br.location != NSNotFound {
            let attributes = storage.attributes(at: br.location, effectiveRange: nil)
            let font = attributes[.font] as? NSFont
            #expect(font?.fontName == "SFMono-Regular", "代码内 <br> 实际字体：\(font?.fontName ?? "nil")")
            #expect(attributes[.backgroundColor] != nil, "行内代码应有灰底")
        }
    }

    @Test("引用块有整块背景（NSTextBlock），且文字为次要灰色")
    func blockquoteHasTextBlockBackground() {
        let storage = render("> 一级引用。")
        let ns = storage.string as NSString
        let range = ns.range(of: "一级引用。")
        #expect(range.location != NSNotFound)
        if range.location != NSNotFound {
            let attributes = storage.attributes(at: range.location, effectiveRange: nil)
            let style = attributes[.paragraphStyle] as? NSParagraphStyle
            #expect((style?.textBlocks.count ?? 0) > 0, "引用块应设置 NSTextBlock 整块背景")
            #expect(attributes[.foregroundColor] as? NSColor == NSColor.secondaryLabelColor,
                    "引用文字应为 secondaryLabelColor")
        }
    }

    @Test("嵌套引用同样有整块背景，且 > 前缀被隐藏")
    func nestedBlockquote() {
        let storage = render("> 外层\n>\n> > 内层\n")
        let ns = storage.string as NSString
        // 隐藏标记不删字符，而是 0.1pt 字体 + 透明色（见 HANDOVER 的测试约定）
        let firstGt = ns.range(of: ">")
        #expect(firstGt.location != NSNotFound)
        if firstGt.location != NSNotFound {
            let font = storage.attributes(at: firstGt.location, effectiveRange: nil)[.font] as? NSFont
            #expect((font?.pointSize ?? 99) < 1, "> 前缀应隐藏（0.1pt），实际 \(font?.pointSize ?? -1)")
        }
        let inner = ns.range(of: "内层")
        #expect(inner.location != NSNotFound)
        if inner.location != NSNotFound {
            let attributes = storage.attributes(at: inner.location, effectiveRange: nil)
            let style = attributes[.paragraphStyle] as? NSParagraphStyle
            #expect((style?.textBlocks.count ?? 0) > 0, "嵌套引用也应设置 NSTextBlock 背景")
        }
    }

}
