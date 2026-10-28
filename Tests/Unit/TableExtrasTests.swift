import AppKit
import Testing
@testable import Markable

/// 表格列对齐、删除线、`<br>` 行内换行。
@MainActor
@Suite("TableExtras")
struct TableExtrasTests {
    private func render(_ source: String) -> NSTextStorage {
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.textContainer?.containerSize = NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        LivePreviewController().apply(to: textView, source: source, baseDirectory: nil,
                                      readOnly: true, fontSize: 14, typography: Typography())
        return textView.textStorage!
    }

    @Test("表格列对齐：左 / 中 / 右")
    func tableColumnAlignment() {
        let storage = render("| A | B | C |\n|:---|:---:|---:|\n| 1 | 2 | 3 |")
        var alignments: [Int: NSTextAlignment] = [:]
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let style = value as? NSParagraphStyle,
                  let block = style.textBlocks.first as? NSTextTableBlock else { return }
            alignments[block.startingColumn] = style.alignment
        }
        #expect(alignments[0] == .left, "第 0 列应左对齐，实际 \(String(describing: alignments[0]))")
        #expect(alignments[1] == .center, "第 1 列应居中，实际 \(String(describing: alignments[1]))")
        #expect(alignments[2] == .right, "第 2 列应右对齐，实际 \(String(describing: alignments[2]))")
    }

    @Test("删除线：~~已废弃~~ 加删除线")
    func strikethrough() {
        let storage = render("这是 ~~已废弃~~ 的内容")
        let ns = storage.string as NSString
        let range = ns.range(of: "已废弃")
        #expect(range.location != NSNotFound)
        if range.location != NSNotFound {
            let attrs = storage.attributes(at: range.location, effectiveRange: nil)
            #expect((attrs[.strikethroughStyle] as? Int ?? 0) != 0, "应有删除线属性")
        }
    }

    @Test("<br> 行内换行")
    func brLineBreak() {
        let storage = render("第一行<br>第二行")
        #expect(storage.string.contains("第一行"))
        #expect(storage.string.contains("第二行"))
        #expect(!storage.string.contains("<br>"), "标签应被替换")
        #expect(storage.string.contains("\u{2028}"), "应换成行分隔符")
    }

    @Test("表格单元格内的 <br> 也换行")
    func brInsideTable() {
        let storage = render("| A | B |\n|---|---|\n| 第一行<br>第二行 | x |")
        #expect(storage.string.contains("第一行"))
        #expect(storage.string.contains("第二行"))
        #expect(!storage.string.contains("<br>"))
    }
}
