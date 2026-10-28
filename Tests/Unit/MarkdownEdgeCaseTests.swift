import AppKit
import Testing
@testable import Markable

/// Markdown 边界语法：转义、HTML 实体、引用块、表格竖线转义、Setext 标题、水平线区分。
@MainActor
@Suite("MarkdownEdgeCase")
struct MarkdownEdgeCaseTests {
    private func render(_ source: String, width: CGFloat = 760) -> NSTextStorage {
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        LivePreviewController().apply(to: textView, source: source, baseDirectory: nil,
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

    /// 隐藏字符 = 0.1pt 字体（Markdown 标记的隐藏手段）。
    private func isHidden(_ storage: NSTextStorage, at location: Int) -> Bool {
        guard location >= 0, location < storage.length,
              let font = storage.attributes(at: location, effectiveRange: nil)[.font] as? NSFont
        else { return false }
        return font.pointSize < 1
    }

    private func isItalic(_ storage: NSTextStorage, at location: Int) -> Bool {
        guard let font = storage.attributes(at: location, effectiveRange: nil)[.font] as? NSFont else { return false }
        return NSFontManager.shared.traits(of: font).contains(.italicFontMask)
    }

    @Test("转义字符：去掉反斜杠、不触发强调")
    func escapesAreLiteral() {
        let storage = render(#"转义：\*不是斜体\*、\_不是下划线\_、\`不是代码\`、\\ 反斜杠"#)
        #expect(storage.string.contains("*不是斜体*"))
        #expect(!storage.string.contains("\\*"))
        if let range = storage.string.range(of: "*不是斜体*") {
            let location = storage.string.distance(from: storage.string.startIndex, to: range.lowerBound)
            #expect(!isItalic(storage, at: location), "转义后的 * 不应触发斜体")
        } else {
            Issue.record("渲染文本中找不到 *不是斜体*")
        }
    }

    @Test("HTML 实体：命名与数字实体均解码")
    func entitiesDecode() {
        let storage = render("实体：&amp; &lt; &gt; &quot; &copy; &#169; &#x2F; &nbsp;空格")
        #expect(storage.string.contains("实体：& < > \" © © /"))
        #expect(!storage.string.contains("&amp;"))
        #expect(!storage.string.contains("&#x2F;"))
    }

    @Test("引用块：空行与嵌套的 > 前缀被隐藏")
    func blockquoteMarkersHidden() {
        let storage = render("""
        > 一级引用。
        >
        > > 嵌套引用。
        > > > 三级引用。
        """)
        #expect(storage.string.contains("一级引用。"))
        #expect(storage.string.contains("嵌套引用。"))
        // 行首 > 已被替换为竖线（每行一个），剩余嵌套 > 仍隐藏
        let bars = storage.string.filter { $0 == "│" }.count
        #expect(bars == 4, "4 个引用行应各有一个竖线，实际 \(bars)")
        let ns = storage.string as NSString
        var location = 0
        var checked = 0
        while location < ns.length, checked < 3 {
            let range = ns.range(of: ">", options: [], range: NSRange(location: location, length: ns.length - location))
            if range.location == NSNotFound { break }
            #expect(isHidden(storage, at: range.location), "位置 \(range.location) 的 > 应隐藏")
            location = range.location + 1
            checked += 1
        }
        #expect(checked == 3, "剩余 3 个嵌套 > 应隐藏，实际 \(checked)")
    }

    @Test("嵌套引用：行首 > 替换为竖线，内层 > 隐藏")
    func nestedBlockquoteBar() {
        let storage = render("> > 嵌套引用。\n")
        #expect(storage.string.contains("嵌套引用。"))
        // 行首第一个 > 已变竖线，第二个 > 仍隐藏
        #expect(storage.string.contains("│"))
        let ns = storage.string as NSString
        let inner = ns.range(of: ">")
        #expect(inner.location != NSNotFound, "内层 > 应保留在文本中（只是隐藏）")
        if inner.location != NSNotFound {
            #expect(isHidden(storage, at: inner.location), "内层 > 应隐藏")
        }
    }

    @Test("列表内引用：行首 > 同样替换为竖线")
    func blockquoteInsideList() {
        let storage = render("- 列表项\n  > 列表里的引用\n")
        #expect(storage.string.contains("列表里的引用"))
        #expect(storage.string.contains("│"), "列表内引用行首应有竖线")
    }

    @Test("表格：单元格内竖线转义是字面字符，不产生多余列")
    func tableEscapedPipe() {
        let storage = render("""
        | 列一 | 列二 |
        |---|---|
        | 管道转义 \\| 竖线 | 正常 |
        """)
        #expect(storage.string.contains("管道转义 | 竖线"))
        let lines = storage.string.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 4, "应只有 2 列 × 2 行 = 4 个单元格行，实际：\(lines)")
    }

    @Test("Setext 标题：=== 与 --- 下划线行被隐藏")
    func setextHeadings() {
        let storage = render("""
        Setext 标题
        ====

        正文
        """)
        #expect(storage.string.contains("Setext 标题"))
        #expect(!storage.string.contains("===="), "=== 下划线应被隐藏或替换")

        let storage2 = render("""
        二级标题
        ----

        正文
        """)
        #expect(storage2.string.contains("二级标题"))
        let ns = storage2.string as NSString
        let dash = ns.range(of: "----")
        #expect(dash.location != NSNotFound)
        if dash.location != NSNotFound {
            #expect(isHidden(storage2, at: dash.location), "---- 下划线应隐藏")
        }
    }

    @Test("水平线：单独 --- 画线；Setext 下划线不画线")
    func thematicBreakVersusSetext() {
        let rule = render("正文\n\n---\n\n正文")
        #expect(attachmentCount(rule) == 1)
        let setext = render("标题文字\n---\n\n正文")
        #expect(attachmentCount(setext) == 0)
    }

    @Test("粗斜体：***x*** 隐藏星号，同时加粗与倾斜")
    func boldItalic() {
        let storage = render("***粗斜体***")
        let ns = storage.string as NSString
        let content = ns.range(of: "粗斜体")
        #expect(content.location != NSNotFound)
        let star = ns.range(of: "*")
        #expect(star.location != NSNotFound)
        if star.location != NSNotFound {
            #expect(isHidden(storage, at: star.location), "星号应隐藏")
        }
        if content.location != NSNotFound {
            let attrs = storage.attributes(at: content.location, effectiveRange: nil)
            #expect((attrs[.obliqueness] as? Double ?? 0) > 0, "应有倾斜样式")
            if let font = attrs[.font] as? NSFont {
                #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask), "应加粗")
            }
        }
    }

    @Test("自动链接：尖括号去掉，URL 带 link 属性")
    func autolink() {
        let storage = render("链接：<https://example.com>")
        #expect(storage.string.contains("https://example.com"))
        #expect(!storage.string.contains("<https://example.com>"))
        if let range = storage.string.range(of: "https://example.com") {
            let location = storage.string.distance(from: storage.string.startIndex, to: range.lowerBound)
            let attrs = storage.attributes(at: location, effectiveRange: nil)
            #expect(attrs[.link] != nil, "应带 link 属性")
        }
    }

    @Test("引用式链接定义行不进入正文")
    func linkRefHidden() {
        let storage = render("正文 [链接][ref]\n\n[ref]: https://example.com")
        #expect(storage.string.contains("正文"))
        let ns = storage.string as NSString
        let defRange = ns.range(of: "[ref]:")
        #expect(defRange.location != NSNotFound)
        if defRange.location != NSNotFound {
            #expect(isHidden(storage, at: defRange.location), "定义行应隐藏")
        }
    }

}
