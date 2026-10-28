import AppKit
import Testing
@testable import Markable

/// 引用块竖线（`│`）的收集：每一条引用行都必须有且只有一条竖线，
/// 包括**空行分隔的多段引用**。
///
/// 回归背景：`BlockSyntax` 的引用正则用了 `\s*`，而 `\s` 含换行符，
/// 于是「空行之后的引用行」的匹配 range 会从上一行的换行符开始；
/// `collectQuoteBarReplacements` 用 `lineRange(for: range.location)` 取行，
/// 落到空行上，导致该行 `>` 被隐藏却没有竖线（视觉缺左竖线）。
@MainActor
@Suite("BlockquoteBar")
struct BlockquoteBarTests {
    private func render(_ source: String, width: CGFloat = 760) -> NSTextStorage {
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        LivePreviewController().apply(to: textView, source: source, baseDirectory: nil,
                                      readOnly: true, fontSize: 14, typography: Typography())
        return textView.textStorage!
    }

    private func barCount(in storage: NSTextStorage) -> Int {
        storage.string.filter { $0 == "│" }.count
    }

    @Test("空行分隔的两段引用，每行都有竖线")
    func barsAcrossBlankLineSeparatedBlocks() {
        let storage = render("> 第一块\n\n> 第二块\n")
        let bars = barCount(in: storage)
        #expect(
            bars == 2,
            "两行引用应各有 1 条竖线，实际 \(bars) 条；渲染文本=\(storage.string.debugDescription)"
        )
    }

    @Test("三段连续引用与段间空行混合，竖线数量与引用行数一致")
    func barsAcrossMixedBlocks() {
        let source = """
        > 甲
        > 乙

        > 丙

        > 丁
        > 戊
        """
        let storage = render(source + "\n")
        let bars = barCount(in: storage)
        #expect(bars == 5, "5 行引用应有 5 条竖线，实际 \(bars) 条；渲染文本=\(storage.string.debugDescription)")
    }

    @Test("BlockSyntax 的引用 range 不含前导换行")
    func blockquoteRangesDoNotSwallowLeadingNewline() {
        let source = "> 第一块\n\n> 第二块\n"
        let ns = source as NSString
        let ranges = BlockSyntax.ranges(in: source).filter { $0.kind == .blockquote }
        #expect(ranges.count == 2, "两段引用应产出 2 个 range，实际 \(ranges.count)")

        for range in ranges {
            #expect(range.range.length > 0)
            #expect(range.range.location < ns.length)
            guard range.range.location < ns.length else { continue }
            let first = ns.character(at: range.range.location)
            #expect(
                first != 0x0A && first != 0x0D,
                "引用 range 不应从换行符开始（location=\(range.range.location)）"
            )
        }
    }

    @Test("顶层代码块里以 > 开头的行不产生竖线")
    func gtInsideCodeBlockHasNoBar() {
        let storage = render("```\n> 代码里的箭头\n```\n")
        #expect(
            !storage.string.contains("│"),
            "代码块内的 > 不应被替换为竖线：\(storage.string.debugDescription)"
        )
        #expect(
            storage.string.contains("> 代码里的箭头"),
            "代码块内容应原样保留：\(storage.string.debugDescription)"
        )
    }

}
