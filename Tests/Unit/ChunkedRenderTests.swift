import AppKit
import Testing
@testable import Markable

/// 大文档「分块让出式」渲染：文本不丢、标题样式生效、重复渲染走缓存。
@MainActor
@Suite("ChunkedRender")
struct ChunkedRenderTests {
    private func makeView() -> NSTextView {
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.textContainer?.containerSize = NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        return textView
    }

    /// 约 600KB（超过 256KB 分块阈值），且不含附件/表格 → 渲染后文本长度不变。
    private func largeSource() -> String {
        let block = "# 标题\n\n段落中的 **粗体** 与 `code`，以及普通文本。\n\n"
        let count = max(1, 600_000 / block.utf8.count)
        return String(repeating: block, count: count)
    }

    @Test("大文档分块渲染：文本长度不变、标题有样式、耗时可接受")
    func chunkedRenderKeepsTextAndStyles() {
        let source = largeSource()
        #expect(source.utf8.count >= 500_000)
        let textView = makeView()

        let start = Date()
        LivePreviewController().apply(to: textView, source: source, baseDirectory: nil, readOnly: true)
        let elapsed = Date().timeIntervalSince(start)

        #expect(textView.textStorage?.length == (source as NSString).length, "分块渲染不应丢失字符")
        #expect(elapsed < 10, "大文档渲染耗时 \(String(format: "%.2f", elapsed))s")

        let ns = (textView.textStorage?.string ?? "") as NSString
        let title = ns.range(of: "标题")
        #expect(title.location != NSNotFound)
        if title.location != NSNotFound {
            let font = textView.textStorage?.attributes(at: title.location, effectiveRange: nil)[.font] as? NSFont
            #expect((font?.pointSize ?? 0) > 14, "标题字号应大于正文（实际 \(font?.pointSize ?? -1)）")
        }
    }

    @Test("重复 apply 命中缓存，重入保护不泄漏")
    func repeatedApplyUsesCache() {
        let source = "# 标题\n\n正文内容。\n"
        let textView = makeView()
        let controller = LivePreviewController()

        controller.apply(to: textView, source: source, baseDirectory: nil, readOnly: true)
        let first = textView.textStorage?.string
        controller.apply(to: textView, source: source, baseDirectory: nil, readOnly: true)
        #expect(textView.textStorage?.string == first)

        // 缓存命中后仍能正常渲染新内容（isApplying 已复位）
        controller.apply(to: textView, source: "# 新标题\n\n新正文。\n", baseDirectory: nil, readOnly: true)
        #expect(textView.textStorage?.string.contains("新标题") == true)
    }
}
