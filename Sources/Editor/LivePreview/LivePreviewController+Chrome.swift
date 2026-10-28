import AppKit

/// `LivePreviewController` 的排版装饰：标记隐藏、引用竖线、水平线、
/// 代码块行号、软换行接排、标题编号。
/// （自 `LivePreviewController.swift` 机械拆分，逻辑未改。）
extension LivePreviewController {
    /// 引用块左侧竖线：把行首的 `>` 标记**原地替换**为竖线字符（长度不变），
    /// 位置与行高由文本行自然决定——不插入附件/额外字符，不动布局与绘制。
    ///
    /// 引用块内的软换行按既有行为接排（`SoftWrap` 测试锁定），因此只需处理
    /// 每段引用的首行；接排后不会再有第二个可见的 `>`。
    func collectQuoteBarReplacements(
        in storage: NSMutableAttributedString,
        into list: inout [(range: NSRange, text: NSAttributedString)]
    ) {
        let text = storage.string
        let ns = text as NSString
        let codeBlockRanges = cachedBlockRanges.filter { $0.kind == .codeBlock }.map(\.range)
        for item in cachedBlockRanges where item.kind == .blockquote {
            if codeBlockRanges.contains(where: { NSLocationInRange(item.range.location, $0) }) { continue }
            let lineRange = ns.lineRange(for: NSRange(location: item.range.location, length: 0))
            guard lineRange.length > 0 else { continue }
            let line = ns.substring(with: lineRange) as NSString
            let gt = line.range(of: ">").location
            guard gt != NSNotFound else { continue }
            let location = lineRange.location + gt
            guard location < ns.length, ns.character(at: location) == 0x3E else { continue }
            // `>` 之后紧跟的空格也一起替换：那些空格属于引用前缀，渲染时随 `>` 一起被隐藏，
            // 若只替换 `>` 本身，复制删掉隐藏字符后空格会消失（`>引用` 而不是 `> 引用`）。
            var end = location + 1
            let lineEnd = lineRange.location + lineRange.length
            while end < lineEnd, ns.character(at: end) == 0x20 || ns.character(at: end) == 0x09 {
                end += 1
            }
            let replacement = "│" + String(repeating: " ", count: end - location - 1)
            // 原始行首前缀（含每层 `>` 与其后空格，如 `> > `）：嵌套引用渲染只画一条竖线，
            // 复制时据此整段还原，避免 `> > 内层` 退化成 `> 内层`。
            let sourcePrefix = referencePrefix(in: ns, lineRange: lineRange)
            list.append((NSRange(location: location, length: end - location),
                         NSAttributedString(string: replacement, attributes: [
                             .font: NSFont.systemFont(ofSize: baseSize),
                             .foregroundColor: NSColor.tertiaryLabelColor,
                             .paragraphStyle: makeBlockquoteStyle(),
                             // 复制时据此把渲染竖线还原成源码 `>`；正文原生 `│` 不带标记。
                             .markableQuoteBar: true,
                             .markableQuoteSourcePrefix: sourcePrefix,
                         ])))
        }
    }

    /// 行首引用前缀（`>` 与空格的连续序列），如 `"> "` / `"> > "` / `">> "`。
    private func referencePrefix(in ns: NSString, lineRange: NSRange) -> String {
        var cursor = lineRange.location
        let lineEnd = lineRange.location + lineRange.length
        while cursor < lineEnd {
            let character = ns.character(at: cursor)
            if character == 0x3E || character == 0x20 || character == 0x09 {
                cursor += 1
                continue
            }
            break
        }
        return ns.substring(with: NSRange(location: lineRange.location, length: cursor - lineRange.location))
    }

    /// 竖线附件：3pt 宽、随正文字号变化；每行一个。
    private func quoteBarAttachment() -> NSTextAttachment {
        let height = max(14, baseSize * 1.3)
        let image = NSImage(size: NSSize(width: 3, height: height))
        image.lockFocus()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: 3, height: height).fill()
        image.unlockFocus()
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: -2, width: 3, height: height)
        return attachment
    }

    /// 水平分隔线（thematic break）：单独一行 `---` / `***` / `___` → 一条横贯内容宽度的灰线。
    ///
    /// 排除两类误判：
    /// - 文件开头的 YAML front matter（`---` … `---`）由 frontMatter 块处理，不画线；
    /// - 围栏代码块内部的 `---` 是代码内容，不画线。
    func collectHorizontalRuleReplacements(
        in storage: NSMutableAttributedString,
        into list: inout [(range: NSRange, text: NSAttributedString)]
    ) {
        let text = storage.string
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(
            pattern: #"^(?:[ \t]*-[ \t]*){3,}$|^(?:[ \t]*\*[ \t]*){3,}$|^(?:[ \t]*_[ \t]*){3,}$"#,
            options: [.anchorsMatchLines]
        ) else { return }

        // 文件开头的 front matter 区间（含两端 `---` 行）
        var frontMatterRange: NSRange?
        if text.hasPrefix("---") {
            let start = text.index(text.startIndex, offsetBy: 3)
            if let close = text.range(of: "\n---", range: start..<text.endIndex) {
                let closeRange = NSRange(close, in: text)
                frontMatterRange = NSRange(location: 0, length: closeRange.location + closeRange.length)
            }
        }
        let codeRanges = cachedBlockRanges
            .filter { $0.kind == .codeBlock }
            .map(\.range)

        let width = max(120, min(containerWidth, 1400) - 8)
        let image = Self.horizontalRuleImage(width: width)
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: 0, width: width, height: image.size.height)

        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if let frontMatterRange, NSLocationInRange(match.range.location, frontMatterRange) { continue }
            if codeRanges.contains(where: { NSLocationInRange(match.range.location, $0) }) { continue }
            // Setext 标题的下划线（上一行非空）不画线，交给 setext 标题处理
            let currentLine = ns.lineRange(for: NSRange(location: match.range.location, length: 0))
            if currentLine.location > 0 {
                let previousLine = ns.lineRange(for: NSRange(location: currentLine.location - 1, length: 0))
                let previousContent = ns.substring(with: previousLine).trimmingCharacters(in: .whitespacesAndNewlines)
                if !previousContent.isEmpty { continue }
            }
            list.append((match.range, NSAttributedString(attachment: attachment)))
        }
    }

    /// 生成一条水平线图片（灰色细线，宽度按内容区）。
    private static func horizontalRuleImage(width: CGFloat) -> NSImage {
        let height: CGFloat = 2
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return image
    }

    /// 代码块行号：在每行行首插入右对齐的序号（可开关）。
    ///
    /// 行号是排版辅助、不属于内容：插入的字符带 `.markableCopySkip`，复制时剔除
    /// （见 `CopyFormatted`），因此开启行号也不会把序号抄进剪贴板。
    func collectCodeLineNumberReplacements(
        in storage: NSMutableAttributedString,
        into list: inout [(range: NSRange, text: NSAttributedString)]
    ) {
        guard typography.codeLineNumbers else { return }
        let text = storage.string
        let ns = text as NSString
        let blocks = cachedBlockRanges.filter { $0.kind == .codeBlock }
        var scheduled = Set<Int>()   // 去重：同一行起点只插一次

        for block in blocks {
            let content = block.content
            guard content.length > 0, content.location + content.length <= storage.length else { continue }
            // 计算行起点与行数
            var lineStarts: [Int] = []
            var index = content.location
            let contentEnd = content.location + content.length
            while index < contentEnd {
                lineStarts.append(index)
                let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
                if lineRange.length == 0 { break }
                index = lineRange.location + lineRange.length
            }
            // 去掉末尾空行
            if let last = lineStarts.last, last >= contentEnd { lineStarts.removeLast() }
            guard !lineStarts.isEmpty else { continue }

            let width = String(lineStarts.count).count
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: max(8, baseSize - 3), weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
                // 行号可见，但不是文档内容：复制时整段剔除。
                .markableCopySkip: true,
            ]
            for (lineIndex, location) in lineStarts.enumerated() {
                guard scheduled.insert(location).inserted else { continue }
                let raw = String(lineIndex + 1)
                let number = String(repeating: " ", count: max(0, width - raw.count)) + raw
                list.append((NSRange(location: location, length: 0),
                             NSAttributedString(string: number + "  ", attributes: attributes)))
            }
        }
    }

    /// 软换行接排：段落内单换行 → 接排（CJK 不插空格）。
    func collectSoftWrapReplacements(
        in storage: NSMutableAttributedString,
        into list: inout [(range: NSRange, text: NSAttributedString)]
    ) {
        for join in SoftWrap.joins(in: storage.string) {
            guard join.range.location + join.range.length <= storage.length else { continue }
            list.append((join.range, NSAttributedString(string: join.replacement, attributes: baseAttributes)))
        }
    }

    /// 把一段字符设为「渲染期隐藏」：0.1pt + 透明色，并打 `.markableHidden` 标记。
    ///
    /// 隐藏而不删除，是为了让 TextKit 的排版与选区偏移稳定（字符仍在文本里）；
    /// `.markableHidden` 则让复制阶段能精确剔除这些语法标记（见 `CopyFormatted`）——
    /// 只靠 0.1pt + clear 是看不见也复制得到，正是过去复制夹带 `# ` / `**` 的原因。
    func hide(_ range: NSRange, in storage: NSMutableAttributedString) {
        guard range.location >= 0, range.length > 0,
              range.location + range.length <= storage.length else { return }
        storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        storage.addAttribute(.font, value: hiddenFont, range: range)
        storage.addAttribute(.markableHidden, value: true, range: range)
    }

    func hideInlineMarkup(_ text: NSMutableAttributedString, range: NSRange) {
        hide(range, in: text)
    }

    /// 标题编号：在标题文本前插入 `1.2 ` 之类的层级序号（跳过代码围栏）。
    ///
    /// 编号是排版辅助、不属于内容：插入的字符带 `.markableCopySkip`，复制时剔除
    /// （与代码块行号同一套机制，见 `CopyFormatted`）。
    func collectHeadingNumberReplacements(
        in storage: NSMutableAttributedString,
        into list: inout [(range: NSRange, text: NSAttributedString)]
    ) {
        guard typography.headingNumbering else { return }
        let text = storage.string
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: #"^(#{1,6}) +"#) else { return }

        var counters = [Int](repeating: 0, count: 7)   // 索引 1...6
        var inFence = false
        var index = 0

        while index < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
            let line = ns.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") || trimmed.hasPrefix("'''") {
                inFence.toggle()
            } else if !inFence,
                      let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                let hashes = (line as NSString).substring(with: match.range(at: 1))
                let level = min(6, max(1, hashes.count))
                counters[level] += 1
                if level < 6 { for deeper in (level + 1)...6 { counters[deeper] = 0 } }
                let number = (1...level).map { String(counters[$0]) }.joined(separator: ".")

                let insertLocation = lineRange.location + match.range.location + match.range.length
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: headingFont(level: level),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .paragraphStyle: baseParagraphStyle,
                    // 编号可见，但不是文档内容：复制时整段剔除。
                    .markableCopySkip: true,
                ]
                list.append((range: NSRange(location: insertLocation, length: 0),
                             text: NSAttributedString(string: number + " ", attributes: attributes)))
            }

            index = lineRange.location + lineRange.length
            if lineRange.length == 0 { break }
        }
    }

    /// 把 `range` 中除 `content` 之外的部分（即 Markdown 标记）设为透明。
    func hideMarkup(_ item: StyledRange, storage: NSMutableAttributedString) {
        let full = item.range
        let content = item.content

        let headEnd = min(content.location, full.location + full.length)
        if headEnd > full.location {
            hide(NSRange(location: full.location, length: headEnd - full.location), in: storage)
        }
        let contentEnd = content.location + content.length
        var fullEnd = full.location + full.length
        // 代码块收尾围栏独占一行：把该行行尾的换行也纳入隐藏，复制时整行一起消失。
        // 否则「围栏删除 + 换行保留」会在复制出的代码末尾多出一个空行。
        if item.kind == .codeBlock, fullEnd < storage.length,
           (storage.string as NSString).character(at: fullEnd) == 0x0A {
            fullEnd += 1
        }
        if fullEnd > contentEnd {
            hide(NSRange(location: contentEnd, length: fullEnd - contentEnd), in: storage)
        }
    }

}
