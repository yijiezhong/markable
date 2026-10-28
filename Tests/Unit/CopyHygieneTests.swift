import AppKit
import Testing
@testable import Markable

/// 复制卫生（Copy Hygiene）：复制只输出**读者看得见的内容**。
///
/// 渲染层为了「看起来像成品」往文本里塞了隐藏语法标记（0.1pt + 透明）、附件占位符
/// （U+FFFC）、代码行号，并把表格重建成了 `NSTextTable`。这些都不该进剪贴板：
/// - 隐藏标记（`# `、`**`、反引号、围栏、链接括号…）→ 复制时删除；
/// - 引用竖线 `│` → 还原成 `>`（正文原生 `│` 不动）；
/// - 图片占位符 → `[图片: alt]` / `[图片]`；
/// - 代码行号 → 删除；
/// - 表格 → TSV（单元格 `\t`、行 `\n`）。
///
/// 纯文本与 RTF 两条输出共用同一份净化结果。
@MainActor
@Suite("CopyHygiene")
struct CopyHygieneTests {
    /// AppKit 复制路径实际传给 `writeSelection(to:types:)` 的旧式类型名。
    private static let legacyString = NSPasteboard.PasteboardType("NSStringPboardType")
    private static let legacyRTF =
        NSPasteboard.PasteboardType("NeXT Rich Text Format v1.0 pasteboard type")

    /// 构造一个真实渲染过的只读文本视图（与阅读器同一套渲染管线）。
    private func makeView(_ source: String, typography: Typography = Typography()) -> ReaderTextView {
        let textView = ReaderTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.frame = NSRect(x: 0, y: 0, width: 760, height: 480)
        textView.textContainer?.containerSize = NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        LivePreviewController().apply(to: textView, source: source, baseDirectory: nil,
                                      readOnly: true, fontSize: 14, typography: typography)
        return textView
    }

    /// 独立命名剪贴板：测试不碰用户剪贴板。
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("CopyHygieneTests-\(UUID().uuidString)"))
    }

    private func cleanUp(_ pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.releaseGlobally()
    }

    /// 模拟 AppKit 的复制调用（⌘C / 拖拽最终都走多类型写入）。
    @discardableResult
    private func copy(_ view: ReaderTextView, range: NSRange, to pasteboard: NSPasteboard) -> Bool {
        view.setSelectedRange(range)
        return view.writeSelection(to: pasteboard, types: [Self.legacyRTF, Self.legacyString])
    }

    /// 模拟服务菜单 / 旧式文本系统的单类型写入：调用前类型已由系统声明。
    @discardableResult
    private func copySingleType(
        _ view: ReaderTextView,
        range: NSRange,
        to pasteboard: NSPasteboard,
        type: NSPasteboard.PasteboardType
    ) -> Bool {
        view.setSelectedRange(range)
        pasteboard.clearContents()
        pasteboard.declareTypes([type], owner: nil)
        return view.writeSelection(to: pasteboard, type: type)
    }

    private func fullRange(of view: ReaderTextView) -> NSRange {
        NSRange(location: 0, length: (view.string as NSString).length)
    }

    /// 复制整个文档并取纯文本。
    private func copiedText(_ source: String, typography: Typography = Typography()) -> String {
        let view = makeView(source, typography: typography)
        let pasteboard = makePasteboard()
        defer { cleanUp(pasteboard) }
        _ = copy(view, range: fullRange(of: view), to: pasteboard)
        return pasteboard.string(forType: .string) ?? "<nil>"
    }

    // MARK: - 1) 块级标记：标题

    @Test("标题复制后去掉 # 前缀")
    func headingHasNoHashPrefix() {
        let view = makeView("# 标题\n")
        // 前提：渲染确实保留了（隐藏的）# 前缀——否则删不删都无所谓，测试就没意义。
        #expect(view.string.contains("# 标题"), "渲染文本实际：\(view.string.debugDescription)")

        let text = copiedText("# 标题\n")
        #expect(text == "标题\n", "复制结果实际：\(text.debugDescription)")
        #expect(!text.contains("#"))
    }

    // MARK: - 2) 行内标记：粗体

    @Test("行内粗体标记不进复制")
    func inlineBoldMarkersAreStripped() {
        let view = makeView("**粗体**\n")
        #expect(view.string.contains("**粗体**"), "渲染文本实际：\(view.string.debugDescription)")

        let text = copiedText("**粗体**\n")
        #expect(text == "粗体\n", "复制结果实际：\(text.debugDescription)")
        #expect(!text.contains("**"))
    }

    // MARK: - 3) 代码块围栏

    @Test("代码块围栏不进复制，代码内容完整")
    func codeFenceIsStripped() {
        let source = "```swift\nlet a = 1\n```\n"
        let view = makeView(source)
        #expect(view.string.contains("```swift"), "渲染文本实际：\(view.string.debugDescription)")

        let text = copiedText(source)
        #expect(!text.contains("```"), "复制结果不应含围栏：\(text.debugDescription)")
        #expect(!text.contains("swift"), "复制结果不应含语言标记：\(text.debugDescription)")
        #expect(text == "let a = 1\n", "复制结果实际：\(text.debugDescription)")
    }

    // MARK: - 4) 引用块

    @Test("引用块复制为 > 前缀（竖线还原且不重复前缀）")
    func blockquoteCopiesAsGreaterThan() {
        let view = makeView("> 引用一行\n")
        #expect(view.string == "│ 引用一行\n", "渲染文本实际：\(view.string.debugDescription)")

        let text = copiedText("> 引用一行\n")
        #expect(text == "> 引用一行\n", "复制结果实际：\(text.debugDescription)")
        #expect(!text.hasPrefix("> >"), "前缀不应重复")
        #expect(!text.contains("│"), "不应残留渲染竖线")
    }

    // MARK: - 5) 图片附件

    @Test("图片占位符不进复制，alt 转成 [图片: alt]")
    func imagePlaceholderBecomesAltText() {
        let source = "![示意图](pic.png)\n"
        let view = makeView(source)
        #expect(view.string.contains("\u{FFFC}"), "渲染文本实际：\(view.string.debugDescription)")

        let text = copiedText(source)
        #expect(!text.contains("\u{FFFC}"), "复制结果不应含附件占位符：\(text.debugDescription)")
        #expect(text == "[图片: 示意图]\n", "复制结果实际：\(text.debugDescription)")
    }

    @Test("alt 为空的图片退化成 [图片]")
    func imagePlaceholderWithoutAlt() {
        let text = copiedText("![](pic.png)\n")
        #expect(!text.contains("\u{FFFC}"), "复制结果实际：\(text.debugDescription)")
        #expect(text == "[图片]\n", "复制结果实际：\(text.debugDescription)")
    }

    // MARK: - 6) 代码行号

    @Test("开启代码行号时，行号不进入复制")
    func codeLineNumbersAreNotCopied() {
        let source = "```swift\nlet a = 1\nlet b = 2\n```\n"
        let view = makeView(source, typography: Typography(codeLineNumbers: true))
        // 前提：行号确实渲染进了文本（否则测试无意义）。
        #expect(view.string.contains("1  let a = 1"), "渲染文本实际：\(view.string.debugDescription)")

        let text = copiedText(source, typography: Typography(codeLineNumbers: true))
        #expect(text == "let a = 1\nlet b = 2\n", "复制结果实际：\(text.debugDescription)")
        #expect(!text.contains("1  "), "行号不应进入复制")
    }

    // MARK: - 7) 表格 → TSV

    @Test("表格复制为 TSV（单元格 \\t、行 \\n、无首尾空行）")
    func tableCopiesAsTSV() {
        let source = "| A | B |\n| --- | --- |\n| 1 | 2 |\n"
        let view = makeView(source)
        // 前提：渲染文本被拆成「每格一行」——这正是过去复制不能粘回表格的原因。
        #expect(view.string.contains("A\nB\n1\n2"), "渲染文本实际：\(view.string.debugDescription)")

        let text = copiedText(source)
        #expect(text == "A\tB\n1\t2", "复制结果实际：\(text.debugDescription)")
        #expect(!text.contains("|"), "复制结果不应含 Markdown 竖线：\(text.debugDescription)")
    }

    @Test("表格与相邻正文之间留一个空行")
    func tableIsSeparatedByBlankLine() {
        let source = "# 标题\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n正文\n"
        let text = copiedText(source)
        #expect(text == "标题\n\nA\tB\n1\t2\n\n正文\n", "复制结果实际：\(text.debugDescription)")
    }

    @Test("选区只覆盖表格一部分时，只输出涉及的行列")
    func partialTableSelectionOutputsCoveredCells() {
        let view = makeView("| A | B |\n| --- | --- |\n| 1 | 2 |\n")
        let ns = view.string as NSString
        // 渲染文本：A\nB\n1\n2\n\n ——只选第二行两个单元格（"1\n2" 之外不含空行）。
        let one = ns.range(of: "1")
        let two = ns.range(of: "2")
        #expect(one.location != NSNotFound && two.location != NSNotFound)
        guard one.location != NSNotFound, two.location != NSNotFound else { return }
        let selection = NSRange(location: one.location, length: two.location + two.length - one.location)

        let pasteboard = makePasteboard()
        defer { cleanUp(pasteboard) }
        _ = copy(view, range: selection, to: pasteboard)
        let text = pasteboard.string(forType: .string) ?? "<nil>"
        #expect(text == "1\t2", "复制结果实际：\(text.debugDescription)")
    }

    @Test("表头与数据行一视同仁，两行都输出")
    func tableHeaderAndBodyBothOutput() {
        let text = copiedText("| 名称 | 数量 |\n| --- | --- |\n| 苹果 | 3 |\n")
        #expect(text == "名称\t数量\n苹果\t3", "复制结果实际：\(text.debugDescription)")
    }

    @Test("表格单元格内的行内标记同样剔除")
    func tableCellsDropInlineMarkup() {
        let text = copiedText("| **A** | `B` |\n| --- | --- |\n| 1 | 2 |\n")
        #expect(text == "A\tB\n1\t2", "复制结果实际：\(text.debugDescription)")
    }

    // MARK: - 整段隐藏：front matter / HTML 注释 / 链接定义行

    @Test("front matter 整段隐藏，不进入复制，也不留前导空行")
    func frontMatterIsStripped() {
        let source = "---\ntitle: 测试\n---\n\n正文\n"
        let view = makeView(source)
        #expect(view.string.contains("title: 测试"), "渲染文本实际：\(view.string.debugDescription)")

        let text = copiedText(source)
        #expect(!text.contains("title:"), "复制结果实际：\(text.debugDescription)")
        #expect(!text.contains("---"), "复制结果实际：\(text.debugDescription)")
        #expect(text.contains("正文"), "复制结果实际：\(text.debugDescription)")
        // 整行删除要连行尾换行一起删：结果既没有 front matter，也不以空行开头。
        #expect(text == "正文\n", "复制结果实际：\(text.debugDescription)")
    }

    @Test("引用式链接定义行删除后不留前导空行")
    func linkReferenceDefinitionLeavesNoBlankLine() {
        let source = "[ref]: https://x.com\n\n[链接][ref]\n"
        let view = makeView(source)
        #expect(view.string.contains("[ref]: https://x.com"), "渲染文本实际：\(view.string.debugDescription)")

        let text = copiedText(source)
        #expect(!text.contains("[ref]:"), "复制结果实际：\(text.debugDescription)")
        // 引用式链接在渲染时只显示链接文本（括号与 ref 是隐藏标记）。
        #expect(text == "链接\n", "复制结果实际：\(text.debugDescription)")
    }

    @Test("正文中间的定义行删除后，前后空行合并成一个")
    func middleLinkReferenceDefinitionKeepsSingleSeparator() {
        let text = copiedText("正文A\n\n[ref]: https://x.com\n\n正文B\n")
        #expect(text == "正文A\n\n正文B\n", "复制结果实际：\(text.debugDescription)")
    }

    @Test("HTML 注释不进入复制")
    func htmlCommentIsStripped() {
        let text = copiedText("正文 <!-- 注释 --> 结尾\n")
        #expect(!text.contains("注释"), "复制结果实际：\(text.debugDescription)")
        #expect(text.contains("正文"), "复制结果实际：\(text.debugDescription)")
        #expect(text.contains("结尾"), "复制结果实际：\(text.debugDescription)")
    }

    // MARK: - 代码块内的空行绝不能被压缩

    @Test("代码块内的空行原样保留")
    func blankLinesInsideCodeBlockSurvive() {
        let text = copiedText("```swift\nlet a = 1\n\nlet b = 2\n```\n")
        #expect(text == "let a = 1\n\nlet b = 2\n", "复制结果实际：\(text.debugDescription)")
    }

    @Test("代码块后的空行不被整行删除规则吞掉")
    func blankLineAfterCodeBlockSurvives() {
        let text = copiedText("```swift\nlet a = 1\n```\n\n正文\n")
        #expect(text == "let a = 1\n\n正文\n", "复制结果实际：\(text.debugDescription)")
    }

    // MARK: - 标题编号

    @Test("标题编号不进入复制")
    func headingNumberIsNotCopied() {
        let source = "# 标题\n"
        let typography = Typography(headingNumbering: true)
        let view = makeView(source, typography: typography)
        // 前提：编号确实渲染进了文本（可见的 "1 标题"）。
        #expect(view.string.contains("1 标题"), "渲染文本实际：\(view.string.debugDescription)")

        let text = copiedText(source, typography: typography)
        #expect(text == "标题\n", "复制结果实际：\(text.debugDescription)")
        #expect(!text.contains("1 标题"))
    }

    // MARK: - Mermaid / 数学附件

    @Test("Mermaid 图复制为 [Mermaid: 源码摘要]（前 3 个非空行）")
    func mermaidBecomesPlaceholder() {
        let source = "```mermaid\nflowchart TD\nA-->B\nB-->C\n```\n\n正文\n"
        let view = makeView(source)
        #expect(view.string.contains("\u{FFFC}"), "渲染文本实际：\(view.string.debugDescription)")

        let text = copiedText(source)
        #expect(!text.contains("\u{FFFC}"), "复制结果不应含附件占位符：\(text.debugDescription)")
        #expect(text.contains("[Mermaid: flowchart TD / A-->B / B-->C]"),
                "复制结果实际：\(text.debugDescription)")
        #expect(!text.contains("```"), "复制结果实际：\(text.debugDescription)")
        #expect(text.contains("正文"), "复制结果实际：\(text.debugDescription)")
    }

    @Test("Mermaid 摘要超长时截断到 80 字符并以 … 结尾")
    func mermaidSummaryTruncates() {
        let longLabel = String(repeating: "很长的节点标签", count: 8)
        let text = copiedText("```mermaid\nflowchart TD\nA[\(longLabel)]-->B\nB-->C\n```\n")
        let marker = "[Mermaid: "
        guard text.hasPrefix(marker), text.hasSuffix("]") else {
            Issue.record("复制结果里没有 Mermaid 占位：\(text.debugDescription)")
            return
        }
        let summary = String(text.dropFirst(marker.count).dropLast())
        #expect(summary.count <= 80, "摘要长度实际 \(summary.count)：\(summary.debugDescription)")
        #expect(summary.hasSuffix("…"), "超长摘要应以 … 结尾：\(summary.debugDescription)")
    }

    @Test("数学公式复制为 [公式]")
    func mathBecomesPlaceholder() {
        let inline = copiedText("行内 $x^2$ 公式\n")
        #expect(!inline.contains("\u{FFFC}"), "行内公式复制结果：\(inline.debugDescription)")
        #expect(!inline.contains("$"), "行内公式复制结果：\(inline.debugDescription)")
        #expect(inline.contains("[公式]"), "行内公式复制结果：\(inline.debugDescription)")

        let display = copiedText("$$\nx^2\n$$\n")
        #expect(!display.contains("\u{FFFC}"), "块级公式复制结果：\(display.debugDescription)")
        #expect(display.contains("[公式]"), "块级公式复制结果：\(display.debugDescription)")
    }

    // MARK: - 连续空行压缩（只吸收删除隐藏行后相邻的空行）

    @Test("删除定义行后，前后连续空行压成一个")
    func consecutiveBlankLinesCollapseAfterDeletion() {
        let text = copiedText("正文A\n\n[ref]: url\n\n\n正文B\n")
        #expect(text == "正文A\n\n正文B\n", "复制结果实际：\(text.debugDescription)")
    }

    @Test("代码块内的多个连续空行原样保留")
    func multipleBlankLinesInsideCodeBlockSurvive() {
        let text = copiedText("```swift\nlet a = 1\n\n\n\nlet b = 2\n```\n")
        #expect(text == "let a = 1\n\n\n\nlet b = 2\n", "复制结果实际：\(text.debugDescription)")
    }

    @Test("代码块后的段落空行不被压缩")
    func paragraphBlankLineAfterCodeBlockSurvives() {
        let text = copiedText("```swift\nlet a = 1\n```\n\n\n正文\n")
        #expect(text == "let a = 1\n\n\n正文\n", "复制结果实际：\(text.debugDescription)")
    }

    // MARK: - 嵌套引用前缀还原

    @Test("嵌套引用复制保留完整前缀")
    func nestedQuoteKeepsFullPrefix() {
        #expect(copiedText("> 单层\n") == "> 单层\n")
        #expect(copiedText("> > 内层\n") == "> > 内层\n")
        #expect(copiedText("> > > 三层\n") == "> > > 三层\n")
    }

    @Test("多层引用混排时逐行还原前缀")
    func mixedNestedQuoteKeepsPrefixes() {
        let text = copiedText("> 外层\n>\n> > 内层\n")
        #expect(text == "> 外层\n>\n> > 内层\n", "复制结果实际：\(text.debugDescription)")
    }

    @Test("嵌套引用的续行同样还原前缀")
    func nestedQuoteContinuationKeepsPrefix() {
        let text = copiedText("> > 内层\n> 续行\n")
        #expect(text == "> > 内层\n> 续行\n", "复制结果实际：\(text.debugDescription)")
    }

    // MARK: - 组合：引用块内的围栏代码块

    @Test("引用块内围栏：围栏行整行消失，代码内容完整，前缀还原为 >")
    func quotedFenceCopiesCleanly() {
        let source = "> 说明\n> ```\n> let a = 1\n> ```\n"
        let text = copiedText(source)
        #expect(!text.contains("```"), "围栏不应进入复制：\(text.debugDescription)")
        #expect(!text.contains("│"), "不应残留渲染竖线：\(text.debugDescription)")
        #expect(text == "> 说明\n> let a = 1\n", "复制结果实际：\(text.debugDescription)")
    }

    // MARK: - 8) 正文原生竖线不误伤

    @Test("正文里原生的 │ 仍保留")
    func nativeBarSurvives() {
        let source = "正文里的竖线 │ 保持不变。\n"
        let view = makeView(source)
        #expect(view.string == source)
        let text = copiedText(source)
        #expect(text == source, "复制结果实际：\(text.debugDescription)")
    }

    // MARK: - 富文本 / 单类型写入同样干净

    @Test("RTF 输出同样干净：无隐藏标记、无占位符、表格为 tab")
    func richTextOutputIsCleanToo() {
        let source = "# 标题\n\n**粗体**\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n![示意图](pic.png)\n"
        let view = makeView(source)
        let pasteboard = makePasteboard()
        defer { cleanUp(pasteboard) }
        #expect(copy(view, range: fullRange(of: view), to: pasteboard))

        guard let data = pasteboard.data(forType: .rtf) else {
            Issue.record("剪贴板缺少 RTF 数据")
            return
        }
        guard let decoded = NSAttributedString(rtf: data, documentAttributes: nil) else {
            Issue.record("RTF 解码失败")
            return
        }
        let text = decoded.string
        #expect(!text.contains("\u{FFFC}"), "RTF 不应含附件占位符：\(text.debugDescription)")
        #expect(!text.contains("│"), "RTF 不应残留渲染竖线")
        #expect(!text.contains("**"), "RTF 不应含行内标记：\(text.debugDescription)")
        #expect(!text.contains("# 标题"), "RTF 不应含标题标记：\(text.debugDescription)")
        #expect(text.contains("A\tB"), "RTF 表格应保持 TSV：\(text.debugDescription)")
        #expect(text.contains("[图片: 示意图]"), "RTF 图片应保留 alt：\(text.debugDescription)")
        #expect(decoded.attribute(.markableTableCell, at: 0, effectiveRange: nil) == nil,
                "RTF 不应带内部自定义属性")
    }

    @Test("单类型写入（服务菜单路径）同样净化")
    func singleTypeWriteIsCleanToo() {
        let view = makeView("# 标题\n\n**粗体**\n")
        let pasteboard = makePasteboard()
        defer { cleanUp(pasteboard) }

        #expect(copySingleType(view, range: fullRange(of: view), to: pasteboard,
                               type: Self.legacyString))
        let text = pasteboard.string(forType: .string) ?? "<nil>"
        #expect(text == "标题\n\n粗体\n", "复制结果实际：\(text.debugDescription)")
    }

    @Test("拖拽数据源与 ⌘C 共用同一净化管线")
    func dragSourceSharesCleanupPipeline() {
        // AppKit 拖拽在 `NSTextView` 内部就是调用 `writeSelection(to:types:)` 把数据写进
        // 拖拽用的 pasteboard（与 ⌘C 同一个方法）。真实拖拽会话需要鼠标按键事件、会进入
        // AppKit 自己的事件循环，在单元测试里会挂死；这里直接按拖拽的调用方式写一遍，
        // 断言拖拽粘贴板与 ⌘C 一样只含可见文本。
        let textView = makeView("# 拖拽标题\n\n**粗体**与 [链接](https://example.com)\n")
        // 拖拽时 AppKit 传入的是被拖的选区；这里等价地先选中全文。
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))

        let pasteboard = NSPasteboard(name: .init("markable.test.drag.\(UUID().uuidString)"))
        pasteboard.clearContents()
        textView.writeSelection(to: pasteboard, types: [.string, .rtf])

        let text = pasteboard.string(forType: .string) ?? ""
        #expect(text.contains("拖拽标题"))
        #expect(!text.contains("# "), "拖拽粘贴板不应带标题标记：\(text)")
        #expect(!text.contains("**"), "拖拽粘贴板不应带粗体标记：\(text)")
        #expect(!text.contains("](https://"), "拖拽粘贴板不应带链接语法：\(text)")

        // 单类型写入（服务菜单 / 旧式拖拽路径）同样干净。
        let single = NSPasteboard(name: .init("markable.test.drag.single.\(UUID().uuidString)"))
        single.clearContents()
        textView.writeSelection(to: single, type: .string)
        let singleText = single.string(forType: .string) ?? ""
        #expect(!singleText.contains("# ") && !singleText.contains("**"))
    }
}
