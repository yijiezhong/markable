import AppKit
import Testing
@testable import Markable

/// 水平分隔线（thematic break）渲染：`---` 不再按原文显示，而是画成一条横线。
@MainActor
@Suite("HorizontalRule")
struct HorizontalRuleTests {
    private func render(_ source: String) -> NSTextStorage {
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.textContainer?.containerSize = NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        let controller = LivePreviewController()
        controller.apply(to: textView, source: source, baseDirectory: nil, readOnly: true,
                         fontSize: 14, typography: Typography())
        return textView.textStorage!
    }

    private func attachmentCount(_ storage: NSTextStorage) -> Int {
        var count = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if value != nil { count += 1 }
        }
        return count
    }

    @Test("独立一行的 --- 渲染为水平线附件")
    func thematicBreakBecomesRule() {
        let storage = render("# 标题\n\n---\n\n正文\n")
        #expect(attachmentCount(storage) == 1)
        #expect(!storage.string.contains("---"))
    }

    @Test("front matter 的 --- 不画水平线")
    func frontMatterNotRuled() {
        let storage = render("---\ntitle: x\n---\n\n正文\n")
        #expect(attachmentCount(storage) == 0)
    }

    @Test("代码块里的 --- 不画水平线")
    func codeBlockNotRuled() {
        let storage = render("```\na\n---\nb\n```\n")
        #expect(attachmentCount(storage) == 0)
    }
}
