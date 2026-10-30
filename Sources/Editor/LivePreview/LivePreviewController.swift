import AppKit

extension NSAttributedString.Key {
    /// `{{TOC}}` 生成的目录条目标记：滚动定位时跳过这些行，
    /// 否则「点大纲」会命中目录里的同名标题，而不是正文标题。
    static let markableTOC = NSAttributedString.Key("markable.toc")
    /// 数学占位符标记：值为 `display|tex`，渲染完成后据此**局部替换**为公式附件。
    static let markableMathKey = NSAttributedString.Key("markable.math.key")
}

/// 只读阅读器的渲染器：从**源文本**重建视图并渲染。
/// 渲染 = 「源 → 视图」：先按源应用属性（不改变长度），再统一做**字符替换**
/// （Mermaid/数学附件、任务列表复选框等，会改变长度，故从后往前批量应用）。
@MainActor
final class LivePreviewController {
    /// 正文字号（由调用方传入）。
    var baseSize: CGFloat = 14
    /// 文本容器宽度（用于表格列宽计算）。
    var containerWidth: CGFloat = 640
    /// 排版参数（字体族 / 行距 / 段间距 / 首行缩进）。
    var typography = Typography()
    var baseFont: NSFont { typography.family.font(ofSize: baseSize, weight: .regular) }
    var boldFont: NSFont { typography.family.font(ofSize: baseSize, weight: .bold) }
    /// 代码字体风格：随正文字体族切换（衬线正文配衬线代码字体）。
    var codeStyle: CodeTypography.Style { CodeTypography.style(for: typography.family) }
    private var codeFont: NSFont { Typography.monoFont(ofSize: baseSize - 1) }
    let hiddenFont = NSFont.systemFont(ofSize: 0.1)

    /// 最近一次渲染的语法识别结果：apply 入口只扫描一次，各 collect 阶段复用
    /// （此前每个 collect 都重新全文扫描，整体约 13 次/渲染；这是大文档性能的主要浪费）。
    var cachedBlockRanges: [StyledRange] = []
    var cachedInlineRanges: [StyledRange] = []

    /// 无序列表是否渲染成项目符号（`•`）；关闭时保留 `-` / `*` / `+` 标记（默认）。
    var bulletLists = false

    /// 渲染结果缓存：同源 / 同字号 / 同宽度 / 同排版参数时直接复用，避免重复全量重建。
    struct RenderKey: Equatable {
        var source: String
        var fontSize: CGFloat
        var containerWidth: CGFloat
        var typography: Typography
        var bulletLists: Bool
        var baseDirectory: String?
        var readOnly: Bool
    }
    var lastRenderKey: RenderKey?
    var lastRenderResult: NSAttributedString?
    /// 只缓存较小文档，避免大文档的 attributed string 让内存翻倍。
    private static let renderCacheByteLimit = 256 * 1024
    /// 大文档分块让出阈值：超过 256KB 时按块让出主线程（TextKit 1 无法视口化，见 ADR 0001）。
    private static let chunkedRenderByteThreshold = 256 * 1024
    /// 每处理多少个 `StyledRange` 让出一次主线程。
    private static let renderChunkSize = 128
    /// 渲染中标志：分块让出主线程时可能被窗口 resize 重入，重入直接跳过（下一次 applyIfNeeded 会补）。
    private var isApplying = false
    /// 最近一次渲染的文本视图：数学渲染完成后据此做局部替换（不再全量重建）。
    weak var currentTextView: NSTextView?

    /// 基础段落样式（行距 / 段间距 / 首行缩进），作用于整篇。
    var baseParagraphStyle: NSParagraphStyle {
        makeParagraphStyle(headIndent: nil)
    }

    /// 构造段落样式：`headIndent` 为 nil 时只套用排版参数（正文），否则用于列表缩进。
    private func makeParagraphStyle(headIndent: CGFloat?) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = typography.lineSpacing
        paragraph.paragraphSpacing = typography.paragraphSpacing
        // 自动折行（默认开）：按容器宽度折行；关闭时不折行、超出窗口的部分被裁切。
        paragraph.lineBreakMode = typography.lineWrap ? .byWordWrapping : .byClipping
        if let headIndent {
            paragraph.headIndent = headIndent
            paragraph.firstLineHeadIndent = headIndent
        } else if typography.firstLineIndent > 0 {
            paragraph.firstLineHeadIndent = CGFloat(typography.firstLineIndent) * baseSize
        }
        return paragraph
    }

    /// 引用块段落样式：`NSTextBlock` 整块背景（100% 宽）+ 段落缩进。
    ///
    /// 注意：`NSTextBlock.contentWidth` 默认是 0（绝对宽度），不显式设成百分比会把
    /// 整个段落压成 0 宽（每个字一行）。内边距不要用 block padding，改用段落缩进，
    /// 避免 padding 把 100% 宽的块再撑出容器。
    func makeBlockquoteStyle() -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = typography.lineSpacing
        paragraph.paragraphSpacing = 0
        paragraph.lineBreakMode = typography.lineWrap ? .byWordWrapping : .byClipping
        paragraph.headIndent = 10
        paragraph.firstLineHeadIndent = 10
        let block = NSTextBlock()
        block.backgroundColor = NSColor.quaternaryLabelColor
        block.setContentWidth(100, type: .percentageValueType)
        paragraph.textBlocks = [block]
        return paragraph
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont,
         .foregroundColor: NSColor.labelColor,
         .backgroundColor: NSColor.clear,
         .paragraphStyle: baseParagraphStyle]
    }

    /// 从源文本重建视图并渲染。
    func apply(
        to textView: NSTextView, source: String, baseDirectory: URL?,
        readOnly: Bool = true, fontSize: CGFloat = 14,
        typography: Typography = Typography(), bulletLists: Bool = false
    ) {
        // 分块渲染期间让出主线程可能触发窗口 resize → 重入；重入直接返回，避免旧 range 失效。
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }

        self.bulletLists = bulletLists
        // 在独立 attributed string 上构建，最后一次性写回视图：
        // TextKit 2 对 textStorage 的每次变更都会触发内容枚举/布局，
        // 数千次直接改视图会卡死（1MB 文档实测 98% CPU 数十秒）。
        let storage = NSMutableAttributedString(string: source, attributes: baseAttributes)
        baseSize = fontSize
        self.typography = typography
        currentTextView = textView
        if let width = textView.textContainer?.containerSize.width, width.isFinite, width > 160 {
            containerWidth = min(width, 1400)
        }

        // 渲染结果缓存：同参数（源/字号/宽度/排版/项目符号/基目录/只读）直接复用
        let renderKey = RenderKey(
            source: source,
            fontSize: fontSize,
            containerWidth: containerWidth,
            typography: typography,
            bulletLists: bulletLists,
            baseDirectory: baseDirectory?.path,
            readOnly: readOnly
        )
        if let cached = lastRenderResult, lastRenderKey == renderKey {
            storage.setAttributedString(cached)
            return
        }

        // 1) 视图 = 源
        storage.setAttributedString(NSAttributedString(string: source, attributes: baseAttributes))

        // 2) 解析与样式（范围基于源，不改变文本长度）
        let profile = ProcessInfo.processInfo.environment["MARKABLE_PROFILE"] != nil
        func mark(_ label: String, _ start: CFAbsoluteTime) {
            guard profile else { return }
            FileHandle.standardError.write(Data("[apply] \(label): \(Int((CFAbsoluteTimeGetCurrent() - start) * 1000))ms\n".utf8))
        }
        let tStart = CFAbsoluteTimeGetCurrent()
        let text = source
        let cursor = textView.selectedRange()
        // 语法识别只做一次：后续 collect 阶段全部复用缓存（避免重复全文扫描）
        cachedInlineRanges = InlineSyntax.ranges(in: text)
        cachedBlockRanges = BlockSyntax.ranges(in: text)
        let merged = cachedInlineRanges + cachedBlockRanges
        let styled = CJKAdjust.adjust(merged, in: text).sorted { a, b in
            if a.range.location != b.range.location { return a.range.location < b.range.location }
            return a.range.length > b.range.length
        }
        let plan = LivePreview.plan(text: text, styled: styled, cursor: cursor, readOnly: readOnly)
        mark("语法分析+plan", tStart)

        let full = NSRange(location: 0, length: storage.length)
        storage.setAttributes(baseAttributes, range: full)
        // 注释范围内的行内语法不再单独渲染：否则代码背景/链接色等会盖在隐藏文本上，
        // 渲染出灰色小方块（HTML 注释里的 `>`、`|` 等被当成行内代码）。
        let commentRanges = plan.rendered.filter { $0.kind == .comment }.map(\.range)
        let renderable = plan.rendered.filter { item in
            guard item.kind != .comment else { return true }
            return !commentRanges.contains { NSIntersectionRange($0, item.range).length > 0 }
        }
        let chunked = false   // 实验：TextKit 2 下先禁用分块让出
        let tAttr = CFAbsoluteTimeGetCurrent()
        var processed = 0
        for item in renderable {
            hideMarkup(item, storage: storage)
            apply(kind: item.kind, range: item.content, payload: item.payload, storage: storage, baseDirectory: baseDirectory)
            if chunked {
                processed += 1
                if processed % Self.renderChunkSize == 0 {
                    // 大文档：每 128 个范围让出一次主线程，避免打开时长时间冻结 UI。
                    // TextKit 1 无法只渲染可见区（见 docs/adr/0001），这是「分块」在本项目的落地。
                    RunLoop.current.run(until: Date())
                }
            }
        }
        applyListIndent(in: storage)

        // 3) 字符替换：统一收集（基于同一份源文本），从后往前应用
        var replacements: [(range: NSRange, text: NSAttributedString)] = []
        collectImageReplacements(in: storage, baseDirectory: baseDirectory, into: &replacements)
        collectTableReplacements(in: storage, baseDirectory: baseDirectory, into: &replacements)
        collectMermaidReplacements(in: storage, into: &replacements)
        let pendingMath = collectMathReplacements(in: storage, into: &replacements)
        collectTaskMarkerReplacements(in: storage, into: &replacements)
        collectListBulletReplacements(in: storage, into: &replacements)
        collectQuoteBarReplacements(in: storage, into: &replacements)
        collectHardBreakReplacements(in: storage, into: &replacements)
        collectMetadataReplacements(in: storage, into: &replacements)
        collectPageBreakReplacements(in: storage, into: &replacements)
        collectHorizontalRuleReplacements(in: storage, into: &replacements)
        collectEscapeReplacements(in: storage, into: &replacements)
        collectAutolinkReplacements(in: storage, into: &replacements)
        collectEntityReplacements(in: storage, into: &replacements)
        collectTOCReplacements(in: storage, into: &replacements)
        collectFootnoteAreaReplacements(in: storage, into: &replacements)
        collectHeadingNumberReplacements(in: storage, into: &replacements)
        collectCodeLineNumberReplacements(in: storage, into: &replacements)
        collectSoftWrapReplacements(in: storage, into: &replacements)

        replacements.sort { a, b in
            // 从后往前应用；同一位置时长 range 先应用（插入提示类替换放在后面，
            // 其 location 不会被先应用的替换破坏）
            if a.range.location != b.range.location { return a.range.location > b.range.location }
            return a.range.length > b.range.length
        }
        mark("替换收集", tAttr)
        let tApply = CFAbsoluteTimeGetCurrent()
        // 从后往前筛出有效替换（与原「boundary」语义一致：被更靠后替换覆盖的跳过）
        var valid: [(range: NSRange, text: NSAttributedString)] = []
        var boundary = storage.length
        for item in replacements {
            if item.range.location + item.range.length > boundary { continue }
            // 替换文本若没有段落样式（附件/占位/复选框等），继承被替换位置的段落样式；
            // 否则 TextKit 会把整段的 paragraphStyle 归一化成 nil（引用块背景会丢）。
            var text = item.text
            if text.length > 0,
               text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) == nil,
               let style = paragraphStyle(at: item.range.location, in: storage) {
                let mutable = NSMutableAttributedString(attributedString: text)
                mutable.addAttribute(.paragraphStyle, value: style,
                                     range: NSRange(location: 0, length: mutable.length))
                text = mutable
            }
            valid.append((item.range, text))
            boundary = item.range.location
        }
        // 一次切片重建（O(n)）：避免数千次 replaceCharacters 在大文档上的 O(n²)
        let rebuilt = NSMutableAttributedString()
        var scan = 0
        for item in valid.reversed() {
            if item.range.location > scan {
                rebuilt.append(storage.attributedSubstring(
                    from: NSRange(location: scan, length: item.range.location - scan)))
            }
            rebuilt.append(item.text)
            scan = item.range.location + item.range.length
        }
        if scan < storage.length {
            rebuilt.append(storage.attributedSubstring(
                from: NSRange(location: scan, length: storage.length - scan)))
        }
        storage.setAttributedString(rebuilt)
        mark("替换应用(切片)", tApply)

        // 3.5) 内部跳转：脚注引用可点击（TOC 链接在收集时已加）
        attachFootnoteLinks(in: storage)
        attachCrossReferenceLinks(in: storage)
        let tLinks = CFAbsoluteTimeGetCurrent()
        attachWikiLinks(in: storage)
        mark("attach links", tLinks)

        // 一次性写回视图（TextKit 2 下这是性能关键：本地构建 → 单次 setAttributedString）
        let tWrite = CFAbsoluteTimeGetCurrent()
        textView.textStorage?.setAttributedString(storage)
        mark("写回视图", tWrite)

        // 缓存本次渲染结果（含待渲染数学占位时不缓存，避免下次命中旧占位）
        if pendingMath.isEmpty, source.utf8.count <= Self.renderCacheByteLimit {
            lastRenderKey = renderKey
            lastRenderResult = storage.copy() as? NSAttributedString
        } else {
            lastRenderKey = nil
            lastRenderResult = nil
        }

        // 4) 数学：未命中缓存的异步渲染，完成后**只替换占位符**（不触发全量重建）
        if !pendingMath.isEmpty {
            Task { @MainActor [weak self] in
                for item in pendingMath {
                    _ = await MathRenderer.shared.image(tex: item.tex, display: item.display)
                }
                self?.replaceMathPlaceholders()
            }
        }
    }

    /// 取某位置所在段落的段落样式；越界时取最后一字符。
    private func paragraphStyle(at location: Int, in storage: NSMutableAttributedString) -> NSParagraphStyle? {
        guard storage.length > 0 else { return nil }
        let index = min(max(0, location), storage.length - 1)
        return storage.attributes(at: index, effectiveRange: nil)[.paragraphStyle] as? NSParagraphStyle
    }

    /// 标题字体（按层级缩放）。
    func headingFont(level: Int) -> NSFont {
        let factors: [CGFloat] = [1.9, 1.6, 1.4, 1.25, 1.1, 1.0]
        let size = baseSize * factors[max(0, min(level - 1, factors.count - 1))]
        return typography.family.font(ofSize: size, weight: .bold)
    }

    // MARK: - 属性渲染

    /// 嵌套列表：按行首缩进宽度设置段落缩进（视觉层级）。
    private func applyListIndent(in storage: NSMutableAttributedString) {
        let text = storage.string
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: #"^(\s*)([-*+]|\d+\.)\s+"#, options: [.anchorsMatchLines]) else { return }
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let indentWidth = ns.substring(with: match.range(at: 1)).count
            guard indentWidth > 0 else { continue }
            let indent = CGFloat(indentWidth) * 7
            storage.addAttribute(.paragraphStyle, value: makeParagraphStyle(headIndent: indent), range: ns.lineRange(for: match.range))
        }
    }

    /// 代码块语法高亮：按语言分词，给 token 上色（在属性阶段、长度未变时应用）。
    private func highlightCode(in range: NSRange, language: String?, storage: NSMutableAttributedString) {
        guard let language, !language.isEmpty else { return }
        guard range.location >= 0, range.location + range.length <= storage.length else { return }
        let code = (storage.string as NSString).substring(with: range)
        for token in CodeHighlighter.tokens(in: code, language: language) {
            let r = NSRange(location: range.location + token.range.location, length: token.range.length)
            guard r.location + r.length <= storage.length else { continue }
            storage.addAttribute(.foregroundColor, value: CodeHighlighter.color(for: token.cls), range: r)
        }
    }

    private func apply(
        kind: MarkdownTokenKind,
        range: NSRange,
        payload: String?,
        storage: NSMutableAttributedString,
        baseDirectory: URL?
    ) {
        guard range.location >= 0, range.location + range.length <= storage.length else { return }
        // 按「行内样式」与「块级样式」分组，避免一个 34 分支的巨型 switch（swiftlint cyclomatic_complexity）。
        switch kind {
        case .heading, .bold, .italic, .code, .codeBlock, .link, .footnote,
             .highlight, .strikethrough, .subscriptText, .superscriptText,
             .underlineText, .footnoteRef:
            applyInlineStyle(kind: kind, range: range, payload: payload, storage: storage)
        case .blockquote, .frontMatter, .linkRef, .comment, .table, .image, .callout, .aiMark:
            applyBlockStyle(kind: kind, range: range, payload: payload, storage: storage)
        case .listItem, .taskList:
            break
        }
    }

    /// 行内样式：字体 / 颜色 / 下划线 / 上下标等。
    private func applyInlineStyle(
        kind: MarkdownTokenKind,
        range: NSRange,
        payload: String?,
        storage: NSMutableAttributedString
    ) {
        switch kind {
        case .heading(let level):
            storage.addAttribute(.font, value: headingFont(level: level), range: range)
        case .bold:
            storage.addAttribute(.font, value: boldFont, range: range)
        case .italic:
            storage.addAttribute(.obliqueness, value: 0.2, range: range)
        case .code:
            CodeTypography.applyCodeFont(to: storage, range: range, size: baseSize - 1, style: codeStyle)
            storage.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: range)
        case .codeBlock:
            CodeTypography.applyCodeFont(to: storage, range: range, size: baseSize - 1, style: codeStyle)
            storage.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: range)
            highlightCode(in: range, language: payload, storage: storage)
        case .link:
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .footnote:
            storage.addAttribute(.font, value: codeFont, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        case .highlight:
            storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: range)
        case .strikethrough:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .subscriptText:
            storage.addAttribute(.baselineOffset, value: -3.0, range: range)
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 11), range: range)
        case .superscriptText:
            storage.addAttribute(.baselineOffset, value: 3.0, range: range)
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 11), range: range)
        case .underlineText:
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .footnoteRef:
            // 脚注引用：上标
            storage.addAttribute(.baselineOffset, value: 4.0, range: range)
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 10), range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        default:
            break
        }
    }

    /// 块级样式：引用块背景、front matter / 注释隐藏、表格、图片占位、callout 与 AI 标注。
    private func applyBlockStyle(
        kind: MarkdownTokenKind,
        range: NSRange,
        payload: String?,
        storage: NSMutableAttributedString
    ) {
        switch kind {
        case .blockquote:
            // 整行块背景 + 灰字区分引用（NSTextBlock 覆盖段落矩形；竖线附件在替换阶段逐行插入）
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
            let blockLine = (storage.string as NSString).lineRange(for: NSRange(location: range.location, length: 0))
            if blockLine.length > 0 {
                storage.addAttribute(.paragraphStyle, value: makeBlockquoteStyle(), range: blockLine)
            }
        case .frontMatter:
            // front matter 不进正文（隐藏；复制时也会被剔除）
            hide(range, in: storage)
        case .linkRef:
            // 引用式链接的定义行（`[ref]: url`）不进入正文（隐藏；复制时也会被剔除）
            hide(range, in: storage)
        case .comment:
            hide(range, in: storage)
        case .table:
            renderTable(range: range, storage: storage)
        case .image:
            // 由替换阶段插入附件字符（见 collectImageReplacements）——此处标记已由 hideMarkup 隐藏。
            break
        case .callout:
            let color: NSColor
            switch (payload ?? "NOTE").uppercased() {
            case "TIP": color = .systemGreen
            case "IMPORTANT": color = .systemPurple
            case "WARNING": color = .systemOrange
            case "CAUTION": color = .systemRed
            default: color = .systemBlue
            }
            storage.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.12), range: range)
            // 隐藏 `[!TYPE]` 标记
            if let regex = try? NSRegularExpression(pattern: #"\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]"#),
               let marker = regex.firstMatch(in: storage.string, range: range) {
                hide(marker.range, in: storage)
            }
        case .aiMark:
            let color: NSColor
            switch (payload ?? "gen").lowercased() {
            case "mix": color = .systemOrange
            case "human": color = .systemGreen
            default: color = .systemPurple
            }
            storage.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.12), range: range)
            // 隐藏标记行 `<!-- ai: ... -->`
            let text = storage.string
            if let regex = try? NSRegularExpression(pattern: #"<!--\s*ai:\s*(gen|mix|human)\s*-->[ \t]*\n?"#),
               let marker = regex.firstMatch(in: text, range: range) {
                hide(marker.range, in: storage)
            }
        default:
            break
        }
    }

    /// 表格渲染（安全近似）：隐藏 `|` 与分隔行，表头行加粗，其余保留文本。
    private func renderTable(range: NSRange, storage: NSMutableAttributedString) {
        let ns = storage.string as NSString
        let end = range.location + range.length
        guard end <= ns.length else { return }

        var idx = range.location
        let pipe = unichar(UInt8(ascii: "|"))
        while idx < end {
            if ns.character(at: idx) == pipe {
                hide(NSRange(location: idx, length: 1), in: storage)
            }
            idx += 1
        }

        var lineIndex = range.location
        var isFirstContentLine = true
        while lineIndex < end {
            let lineRange = ns.lineRange(for: NSRange(location: lineIndex, length: 0))
            let line = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if isSeparatorLine(line) {
                hide(lineRange, in: storage)
            } else if isFirstContentLine {
                storage.addAttribute(.font, value: boldFont, range: lineRange)
                isFirstContentLine = false
            }
            if lineRange.length == 0 { break }
            lineIndex = lineRange.location + lineRange.length
        }
    }

}
