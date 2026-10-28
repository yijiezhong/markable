import Testing
import AppKit
@testable import Markable

/// 真网格表格：结构被重建为「每格一段 + NSTextTableBlock」。
@Suite("TableRendering")
struct TableRenderingTests {
    @Test @MainActor func tableBecomesGrid() {
        _ = NSApplication.shared
        let source = "| A | B |\n| --- | :--: |\n| 1 | 2 |\n"
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        textView.textContainer?.containerSize = NSSize(width: 560, height: 400)
        LivePreviewController().apply(to: textView, source: source, baseDirectory: nil)

        let rendered = textView.string
        // 分隔行被移除
        #expect(!rendered.contains("---"))
        // 单元格各自成段落
        for cell in ["A", "B", "1", "2"] {
            #expect(rendered.contains("\(cell)\n"))
        }
        // 单元格段落带表格块
        let style = textView.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.textBlocks.isEmpty == false)
    }

    @Test @MainActor func nonTableUntouched() {
        _ = NSApplication.shared
        let source = "普通段落\n"
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        LivePreviewController().apply(to: textView, source: source, baseDirectory: nil)
        let style = textView.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.textBlocks.isEmpty ?? true)
    }
}
