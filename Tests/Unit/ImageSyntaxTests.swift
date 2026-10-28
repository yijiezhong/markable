import AppKit
import Testing
@testable import Markable

/// 图片语法：带标题、空 alt、引用式、远程/缺失占位；裸 URL 自动链接。
@MainActor
@Suite("ImageSyntax")
struct ImageSyntaxTests {
    private var samplesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Unit
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("samples")
    }

    private func render(_ source: String) -> NSTextStorage {
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.textContainer?.containerSize = NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        LivePreviewController().apply(to: textView, source: source, baseDirectory: samplesDirectory,
                                      readOnly: true, fontSize: 14, typography: Typography())
        return textView.textStorage!
    }

    private func attachmentCount(_ storage: NSTextStorage) -> Int {
        var count = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if value != nil { count += 1 }
        }
        return count
    }

    /// 只拼接"可见"字符（隐藏标记为 0.1pt 字体，不计入）。
    private func visibleText(_ storage: NSTextStorage) -> String {
        var result = ""
        let ns = storage.string as NSString
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length), options: []) { attrs, range, _ in
            let pointSize = (attrs[.font] as? NSFont)?.pointSize ?? 1
            guard pointSize >= 1 else { return }
            var chunk = ns.substring(with: range)
            chunk = chunk.replacingOccurrences(of: "\u{FFFC}", with: "")
            result += chunk
        }
        return result
    }

    @Test("带标题的图片：title 不进入路径，图片正常显示")
    func imageWithTitle() {
        let storage = render(#"![带标题](demo.jpg "图片标题")"#)
        #expect(attachmentCount(storage) == 1)
        let visible = visibleText(storage)
        #expect(!visible.contains("图片标题"))
        #expect(!visible.contains("demo.jpg"))
    }

    @Test("空 alt 图片：仍能显示")
    func imageEmptyAlt() {
        let storage = render(#"![](demo.jpg)"#)
        #expect(attachmentCount(storage) == 1)
        #expect(!visibleText(storage).contains("demo.jpg"))
    }

    @Test("引用式图片：按定义解析并显示")
    func imageReferenceStyle() {
        let storage = render("""
        ![引用式图片][imgref]

        [imgref]: demo.jpg "引用式图片"
        """)
        #expect(attachmentCount(storage) == 1)
        #expect(!storage.string.contains("![引用式图片][imgref]"))
    }

    @Test("远程图片显示占位（不联网）")
    func remoteImagePlaceholder() {
        let storage = render("![远程](https://example.com/demo.png)")
        #expect(attachmentCount(storage) == 1)
    }

    @Test("缺失图片显示占位")
    func missingImagePlaceholder() {
        let storage = render("![缺失](images/not-found.png)")
        #expect(attachmentCount(storage) == 1)
    }

    @Test("裸 URL 自动变成链接")
    func bareURLAutolink() {
        let storage = render("访问 https://www.deepseek.com/ 了解详情。")
        let ns = storage.string as NSString
        let range = ns.range(of: "https://www.deepseek.com/")
        #expect(range.location != NSNotFound)
        if range.location != NSNotFound {
            let attrs = storage.attributes(at: range.location, effectiveRange: nil)
            #expect(attrs[.link] != nil, "裸 URL 应带 link 属性")
        }
    }
}
