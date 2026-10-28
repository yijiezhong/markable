import AppKit
import Testing
@testable import Markable

/// 大纲定位跳过目录条目 + 表格列宽自适应。
@MainActor
@Suite("TOCAndTableWidth")
struct TOCAndTableWidthTests {
    private func render(_ source: String) -> NSTextStorage {
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.textContainer?.containerSize = NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        LivePreviewController().apply(to: textView, source: source, baseDirectory: nil,
                                      readOnly: true, fontSize: 14, typography: Typography())
        return textView.textStorage!
    }

    @Test("目录条目带 markableTOC 标记（供定位跳过）")
    func tocItemsMarked() {
        let storage = render("# 一\n\n## 二\n\n{{TOC}}\n\n## 三\n")
        var marked = 0
        storage.enumerateAttribute(.markableTOC, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if value != nil { marked += 1 }
        }
        #expect(marked > 0, "{{TOC}} 生成的目录应带 markableTOC 标记")
    }

    @Test("表格列宽按内容自适应（长内容列更宽）")
    func tableColumnWidthsAdapt() {
        let storage = render("| 短 | 很长的内容列 |\n|---|---|\n| a | 这是一段明显更长的内容文本 |")
        var widthColumn0: CGFloat = 0
        var widthColumn1: CGFloat = 0
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let style = value as? NSParagraphStyle,
                  let block = style.textBlocks.first as? NSTextTableBlock,
                  block.startingRow == 1 else { return }
            if block.startingColumn == 0 { widthColumn0 = block.contentWidth }
            if block.startingColumn == 1 { widthColumn1 = block.contentWidth }
        }
        #expect(widthColumn0 > 0 && widthColumn1 > 0, "应能读到两列宽度（实际 \(widthColumn0) / \(widthColumn1)）")
        #expect(widthColumn0 < widthColumn1, "长内容列应更宽：\(widthColumn0) vs \(widthColumn1)")
    }
}
