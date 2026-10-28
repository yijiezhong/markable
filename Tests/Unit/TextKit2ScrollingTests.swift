import AppKit
import Testing
@testable import Markable

/// TextKit 2 下的滚动定位：字符定位与可见区顶部字符查询。
@MainActor
@Suite("TextKit2Scrolling")
struct TextKit2ScrollingTests {
    private func makeView(text: String) -> (ScrollViewBox, NSScrollView, ReaderTextView) {
        let textView = ReaderTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        let width: CGFloat = 640
        textView.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        if let container = textView.textContainer {
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor,
        ]))

        let scrollView = NSScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        scrollView.layoutSubtreeIfNeeded()

        let box = ScrollViewBox()
        box.scrollView = scrollView
        return (box, scrollView, textView)
    }

    @Test("TextKit 2：滚动到指定字符位置")
    func scrollsToCharacter() {
        let lines = (0..<120).map { "第 \($0) 行内容，用于验证滚动定位。" }.joined(separator: "\n")
        let (box, scrollView, textView) = makeView(text: lines)

        // 目标：第 80 行附近（靠文档后部）
        let target = (lines as NSString).range(of: "第 80 行").location
        box.scrollToCharacter(target)
        scrollView.layoutSubtreeIfNeeded()

        let offset = scrollView.contentView.bounds.origin.y
        #expect(offset > 0, "应滚动到文档后部，实际 offset=\(offset)")

        // 滚动后目标行应落在可见区（至少目标字符所在 fragment 与可见区相交）
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let start = contentManager.location(contentManager.documentRange.location, offsetBy: target) else {
            Issue.record("TextKit 2 无法定位目标字符")
            return
        }
        layoutManager.ensureLayout(for: NSTextRange(location: start))
        guard let fragment = layoutManager.textLayoutFragment(for: start) else {
            Issue.record("目标位置没有布局片段")
            return
        }
        let frame = fragment.layoutFragmentFrame
        let y = frame.minY + textView.textContainerOrigin.y
        #expect(abs(y - offset) < 200, "目标片段应在滚动后可见：fragment y=\(y), offset=\(offset)")
    }

    @Test("TextKit 2：可见区顶部字符索引")
    func visibleTopCharacter() {
        let lines = (0..<120).map { "第 \($0) 行内容，用于验证可见区定位。" }.joined(separator: "\n")
        let (box, scrollView, _) = makeView(text: lines)

        let top = box.visibleTopCharacterIndex()
        #expect(top != nil, "应能返回可见区顶部字符索引")
        if let top {
            #expect(top >= 0 && top < (lines as NSString).length)
        }

        // 滚到中部后，顶部字符索引应明显增大
        let target = (lines as NSString).range(of: "第 60 行").location
        box.scrollToCharacter(target)
        scrollView.layoutSubtreeIfNeeded()
        let later = box.visibleTopCharacterIndex()
        if let top, let later {
            #expect(later > top, "滚动后可见区顶部字符索引应增大：before=\(top), after=\(later)")
        }
    }
}
