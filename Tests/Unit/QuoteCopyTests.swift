import AppKit
import Testing
@testable import Markable

/// 引用块竖线的复制还原：
/// - 渲染阶段插入的 `│` 带 `.markableQuoteBar` 标记，复制时还原为源码 `>`；
/// - 用户正文里原生的 `│` 不带标记，复制时保持不变；
/// - 纯文本与 RTF 两条输出都必须是还原后的内容。
@MainActor
@Suite("QuoteCopy")
struct QuoteCopyTests {
    /// AppKit 复制路径实际传给 `writeSelection(to:types:)` 的旧式类型名。
    private static let legacyString = NSPasteboard.PasteboardType("NSStringPboardType")
    private static let legacyRTF =
        NSPasteboard.PasteboardType("NeXT Rich Text Format v1.0 pasteboard type")

    /// 构造一个真实渲染过的只读文本视图（与阅读器同一套渲染管线）。
    private func makeView(_ source: String) -> ReaderTextView {
        let textView = ReaderTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.frame = NSRect(x: 0, y: 0, width: 760, height: 480)
        textView.textContainer?.containerSize = NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        LivePreviewController().apply(to: textView, source: source, baseDirectory: nil,
                                      readOnly: true, fontSize: 14, typography: Typography())
        return textView
    }

    /// 独立命名剪贴板：测试不碰用户剪贴板。
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("QuoteCopyTests-\(UUID().uuidString)"))
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

    @Test("渲染插入的竖线复制后变成 >（纯文本）")
    func markedBarCopiesAsGt() {
        let view = makeView("> 引用内容\n")
        #expect(view.string == "│ 引用内容\n", "渲染文本实际：\(view.string.debugDescription)")

        let bar = (view.string as NSString).range(of: "│")
        #expect(bar.location != NSNotFound)
        if bar.location != NSNotFound {
            let marked = view.textStorage?.attribute(.markableQuoteBar, at: bar.location,
                                                     effectiveRange: nil) as? Bool
            #expect(marked == true, "渲染竖线应带 .markableQuoteBar 标记")
        }

        let pasteboard = makePasteboard()
        defer { cleanUp(pasteboard) }
        #expect(copy(view, range: fullRange(of: view), to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "> 引用内容\n",
                "纯文本实际：\(pasteboard.string(forType: .string) ?? "nil")")
        #expect(pasteboard.string(forType: Self.legacyString) == "> 引用内容\n")
    }

    @Test("用户正文里原生的竖线保持 │（防误伤）")
    func nativeBarStaysUntouched() {
        let source = "正文里的竖线 │ 保持不变。\n"
        let view = makeView(source)
        #expect(view.string == source)
        let bar = (view.string as NSString).range(of: "│")
        #expect(bar.location != NSNotFound)
        if bar.location != NSNotFound {
            let marked = view.textStorage?.attribute(.markableQuoteBar, at: bar.location,
                                                     effectiveRange: nil) as? Bool
            #expect(marked != true, "正文原生竖线不应带渲染标记")
        }

        let pasteboard = makePasteboard()
        defer { cleanUp(pasteboard) }
        #expect(copy(view, range: fullRange(of: view), to: pasteboard))
        #expect(pasteboard.string(forType: .string) == source,
                "纯文本实际：\(pasteboard.string(forType: .string) ?? "nil")")
    }

    @Test("同一行里只还原带标记的竖线，原生 │ 原样保留")
    func onlyRenderedBarIsRestored() {
        let view = makeView("> 引用里有 │ 原生竖线\n")
        #expect(view.string == "│ 引用里有 │ 原生竖线\n")

        let pasteboard = makePasteboard()
        defer { cleanUp(pasteboard) }
        #expect(copy(view, range: fullRange(of: view), to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "> 引用里有 │ 原生竖线\n",
                "纯文本实际：\(pasteboard.string(forType: .string) ?? "nil")")
    }

    @Test("RTF 输出同样是 >，且不含渲染竖线")
    func rtfUsesRestoredMarker() {
        let view = makeView("> 引用内容\n")
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
        #expect(decoded.string == "> 引用内容\n", "RTF 文本实际：\(decoded.string.debugDescription)")
        #expect(!decoded.string.contains("│"), "RTF 里不应残留渲染竖线")
        #expect(decoded.attribute(.markableQuoteBar, at: 0, effectiveRange: nil) == nil,
                "RTF 不应带内部自定义属性")
    }

    @Test("部分选区只还原选区内的竖线")
    func partialSelectionRestoresOnlySelectedBars() {
        let view = makeView("> 引用内容\n")
        let text = view.string as NSString
        #expect(view.string == "│ 引用内容\n", "渲染文本实际：\(view.string.debugDescription)")

        let pasteboard = makePasteboard()
        defer { cleanUp(pasteboard) }

        // 只选中渲染竖线本身：只还原选中的这一个字符，不把后文带出。
        #expect(copy(view, range: NSRange(location: 0, length: 1), to: pasteboard))
        #expect(pasteboard.string(forType: .string) == ">",
                "纯文本实际：\(pasteboard.string(forType: .string) ?? "nil")")

        // 选区只覆盖行内正文（竖线在选区外）：保持原样，不凭空补 `>`。
        let content = text.range(of: "引用内容")
        #expect(content.location != NSNotFound)
        #expect(copy(view, range: content, to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "引用内容",
                "纯文本实际：\(pasteboard.string(forType: .string) ?? "nil")")

        // 整行选区：竖线在选区内，正常还原。
        #expect(copy(view, range: fullRange(of: view), to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "> 引用内容\n",
                "纯文本实际：\(pasteboard.string(forType: .string) ?? "nil")")
    }

    @Test("单类型写入（服务/旧式路径）也把渲染竖线还原为 >")
    func singleTypeWriteRestoresMarkedBar() {
        let view = makeView("> 引用内容\n")
        let pasteboard = makePasteboard()
        defer { cleanUp(pasteboard) }

        #expect(copySingleType(view, range: fullRange(of: view), to: pasteboard, type: .string))
        #expect(pasteboard.string(forType: .string) == "> 引用内容\n",
                "纯文本实际：\(pasteboard.string(forType: .string) ?? "nil")")
        #expect(!(pasteboard.string(forType: .string) ?? "").contains("│"))
    }

    @Test("单类型写入未标记选区时走 super，内容不被改写")
    func singleTypeWriteLeavesUnmarkedSelectionUntouched() {
        let source = "正文里的竖线 │ 保持不变。\n"
        let view = makeView(source)
        let pasteboard = makePasteboard()
        defer { cleanUp(pasteboard) }

        // 旧式类型名是 AppKit 单类型写入实际可用的 flavor；现代 public.utf8-plain-text
        // 的单类型 super 路径在 TextKit 下返回 false（既有行为），故用旧式名验证透传。
        #expect(copySingleType(view, range: fullRange(of: view), to: pasteboard,
                               type: Self.legacyString))
        #expect(pasteboard.string(forType: .string) == source,
                "纯文本实际：\(pasteboard.string(forType: .string) ?? "nil")")
        #expect(pasteboard.string(forType: Self.legacyString) == source)
    }
}
