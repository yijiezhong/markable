import Foundation

/// 块级语法识别：标题、引用、代码块、列表、任务列表、表格、Front Matter、脚注。
/// 纯函数；先识别可能跨行的块（Front Matter、代码块），再识别逐行结构。
enum BlockSyntax {
    /// 识别文本中的块级语法片段。
    static func ranges(in text: String) -> [StyledRange] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var result: [StyledRange] = []

        // 跨行块：Front Matter（**仅限文件开头**）与围栏代码块。
        //
        // 注意：不能用行首锚点 `^---` 匹配——那会把文档中间的 `---`（水平分隔线）
        // 与后面的另一个 `---` 配对，把中间整段正文误判成 front matter 而隐藏
        // （曾导致「摘要」整段变成灰条 + 大片空白）。
        if text.hasPrefix("---") {
            result += matches(in: text, range: full, pattern: #"\A---\n[\s\S]*?\n---\n"#, kind: .frontMatter)
        }
        // 一次收集所有行的信息（行范围 + 字符数组 + 每行的块级判断），
        // 供下面所有状态机与逐行规则共用：不再为每行创建 String，也不再跑 7 条全文正则。
        let (lines, chars) = collectLines(in: text, range: full)
        let topLevelCodeBlocks = codeBlockMatches(lines: lines, text: text)
        result += topLevelCodeBlocks
        let indentedBlocks = indentedCodeMatches(lines: lines)
        result += indentedBlocks

        // 逐行规则：标题 / 任务列表 / 引用 / 列表项 / 脚注定义 / 引用式链接定义（一次行扫描）。
        result += lineRuleMatches(lines: lines, chars: chars)
        // Setext 标题：文字行 + 下一行 ===/---（不再用正则，复用已算好的 setextLevel）。
        result += setextHeadingMatches(
            lines: lines,
            codeRanges: topLevelCodeBlocks.map(\.range) + indentedBlocks.map(\.range),
            frontMatterRange: frontMatterRange(in: text)
        )
        // 引用内的围栏代码块（`> ``` ` … `> ``` `）：顶层围栏扫描只看行首，识别不到这类行。
        // 排除顶层代码块内部的行，避免把代码示例里的 `> ``` ` 当成引用围栏。
        result += quotedFenceMatches(
            lines: lines, text: text,
            excluding: topLevelCodeBlocks.map(\.range)
        )
        result += tableMatches(lines: lines)
        result += calloutMatches(in: text, range: full)
        result += aiMarkMatches(in: text, range: full)
        // HTML 注释：整块隐藏（跨行匹配，保留正则）
        if text.contains("<!--") {
            result += matches(in: text, range: full, pattern: #"<!--[\s\S]*?-->"#, kind: .comment)
        }

        return result.sorted { $0.range.location < $1.range.location }
    }

    /// 是否为代码围栏行（` ``` `、`~~~`、`'''`；一个/两个撇号是普通文字，不算围栏）。
    static func isFence(_ line: String) -> Bool {
        if line.hasPrefix("```") || line.hasPrefix("~~~") { return true }
        return line.hasPrefix("'''")
    }

    /// 引用内的围栏代码块（`> ``` ` … `> ``` `）。
    ///
    /// 顶层围栏扫描只看行首，`> ``` ` 这类行会被当成引用正文显示成字面量。这里剥离引用前缀后
    /// 再识别围栏，产出两类片段：
    /// - **围栏行**：`.comment`，且范围只覆盖**前缀之后的围栏字符**——引用竖线与整块灰底保留；
    /// - **内容行**：`.code`（等宽 + 灰底），前缀仍由 `.blockquote` 隐藏。
    ///
    /// 未闭合的围栏不处理（保持原来的引用正文渲染），避免把后续正文整段吞成代码。
    /// - Parameter excluding: 顶层代码块的范围；落在其中的行跳过（代码示例里的 `> ``` ` 不是围栏）。
    /// 剥离一层或多层引用前缀（`[ \t]*` + 若干 `>`），返回 (前缀 UTF-16 长度, 剩余正文)。
    /// 没有引用前缀时返回 (0, 原行)。
    private static func splitQuotePrefix(_ line: String) -> (prefixLength: Int, body: String) {
        let ns = line as NSString
        var index = 0
        while index < ns.length, isHorizontalSpace(ns.character(at: index)) { index += 1 }
        var hasQuote = false
        while index < ns.length, ns.character(at: index) == 0x3E {   // '>'
            hasQuote = true
            index += 1
            while index < ns.length, isHorizontalSpace(ns.character(at: index)) { index += 1 }
        }
        guard hasQuote else { return (0, line) }
        return (index, ns.substring(from: index))
    }

    private static func isHorizontalSpace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09
    }

    /// 围栏行识别：剥掉引用前缀后，整行必须是围栏 + 可选语言标识（其它内容不算围栏）。
    private static func fenceInfo(_ trimmed: String) -> (marker: String, language: String)? {
        guard let first = trimmed.first, first == "`" || first == "~" || first == "'" else { return nil }
        let markerLength = trimmed.prefix { $0 == first }.count
        guard markerLength >= 3 else { return nil }
        let rest = trimmed.dropFirst(markerLength)
        let allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_+.#-"
        guard rest.allSatisfy({ allowed.contains($0) }) else { return nil }
        return (String(repeating: String(first), count: markerLength), String(rest))
    }


    /// 一行预解析出来的共享信息。所有字段都是「字符级」判断结果，不持有字符串，
    /// 因此 `collectLines` 可以只做一次 `getCharacters`，不为每行创建 `String`。
    private struct Line {
        var range: NSRange        // 含行尾换行
        var contentEnd: Int       // 行内容结束（不含换行）
        var isFence: Bool
        var isIndented: Bool
        var looksLikeList: Bool
        var isBlank: Bool
        var isTableRow: Bool
        var prefixLength: Int     // 引用前缀的 UTF-16 长度（无前缀为 0）
        var setextLevel: Int?     // 1 = `===`，2 = `---`
    }

    /// 一次 `getCharacters` + 一次行遍历，把所有状态机需要的判断都算好。
    private static func collectLines(in text: String, range: NSRange) -> (lines: [Line], chars: [unichar]) {
        let ns = text as NSString
        let length = ns.length
        guard length > 0 else { return ([], []) }
        var chars = [unichar](repeating: 0, count: length)
        ns.getCharacters(&chars, range: NSRange(location: 0, length: length))

        var lines: [Line] = []
        lines.reserveCapacity(max(1, range.length / 40))
        var index = range.location
        let limit = range.location + range.length
        while index < limit {
            var lineEnd = index
            while lineEnd < limit, chars[lineEnd] != 0x0A { lineEnd += 1 }
            var contentEnd = lineEnd
            if contentEnd > index, chars[contentEnd - 1] == 0x0D { contentEnd -= 1 }
            let lineRange = NSRange(location: index, length: (lineEnd < limit ? lineEnd + 1 : lineEnd) - index)

            var trimmedStart = index
            while trimmedStart < contentEnd, isHorizontalSpace(chars[trimmedStart]) { trimmedStart += 1 }
            var trimmedEnd = contentEnd
            while trimmedEnd > trimmedStart, isHorizontalSpace(chars[trimmedEnd - 1]) { trimmedEnd -= 1 }
            let isBlank = trimmedStart >= trimmedEnd

            let isFence = !isBlank && isFenceChars(chars, start: trimmedStart, end: trimmedEnd)
            let setextLevel = isBlank ? nil : setextUnderlineLevel(chars, start: trimmedStart, end: trimmedEnd)

            var isIndented = false
            if contentEnd > index {
                if chars[index] == 0x09 {
                    isIndented = true
                } else if contentEnd - index >= 4 {
                    isIndented = chars[index] == 0x20 && chars[index + 1] == 0x20
                        && chars[index + 2] == 0x20 && chars[index + 3] == 0x20
                }
            }

            var looksLikeList = false
            if !isBlank {
                let first = chars[trimmedStart]
                if first == 0x2D || first == 0x2A || first == 0x2B {
                    looksLikeList = trimmedStart + 1 < trimmedEnd && chars[trimmedStart + 1] == 0x20
                } else if first == 0x3E {
                    looksLikeList = true
                } else if first >= 0x30, first <= 0x39 {
                    var cursor = trimmedStart
                    while cursor < trimmedEnd, chars[cursor] >= 0x30, chars[cursor] <= 0x39 { cursor += 1 }
                    looksLikeList = cursor > trimmedStart && cursor + 1 < trimmedEnd
                        && chars[cursor] == 0x2E && chars[cursor + 1] == 0x20
                }
            }

            lines.append(Line(
                range: lineRange,
                contentEnd: contentEnd,
                isFence: isFence,
                isIndented: isIndented,
                looksLikeList: looksLikeList,
                isBlank: isBlank,
                isTableRow: !isBlank && chars[trimmedStart] == 0x7C,
                prefixLength: quotePrefixLength(chars, start: index, end: contentEnd),
                setextLevel: setextLevel
            ))
            index = lineEnd < limit ? lineEnd + 1 : limit
        }
        return (lines, chars)
    }

    /// 行首是否为围栏（至少 3 个同字符的 反引号 / 波浪号 / 撇号）。
    private static func isFenceChars(_ chars: [unichar], start: Int, end: Int) -> Bool {
        guard end - start >= 3 else { return false }
        let first = chars[start]
        guard first == 0x60 || first == 0x7E || first == 0x27 else { return false }
        return chars[start + 1] == first && chars[start + 2] == first
    }

    /// Setext 下划线行：整行只有 `=` 或只有 `-`（>=2 个）。返回 1 / 2，否则 nil。
    private static func setextUnderlineLevel(_ chars: [unichar], start: Int, end: Int) -> Int? {
        guard end - start >= 2 else { return nil }
        let first = chars[start]
        guard first == 0x3D || first == 0x2D else { return nil }
        var index = start
        while index < end, chars[index] == first { index += 1 }
        guard index == end else { return nil }
        return first == 0x3D ? 1 : 2
    }

    /// 引用前缀长度：行首空白 + 若干 `>`（每层后可跟空白），无 `>` 返回 0。
    private static func quotePrefixLength(_ chars: [unichar], start: Int, end: Int) -> Int {
        var index = start
        while index < end, isHorizontalSpace(chars[index]) { index += 1 }
        var hasQuote = false
        while index < end, chars[index] == 0x3E {
            hasQuote = true
            index += 1
            while index < end, isHorizontalSpace(chars[index]) { index += 1 }
        }
        return hasQuote ? index - start : 0
    }

    /// 代码块（行扫描）：内容为两条围栏之间的文本，围栏本身在渲染时隐藏；payload = 语言标识。
    private static func codeBlockMatches(lines: [Line], text: String) -> [StyledRange] {
        let ns = text as NSString
        var result: [StyledRange] = []
        var fenceStart: Int?
        var contentStart = 0
        var language = ""
        for line in lines where line.isFence {
            if let start = fenceStart {
                let end = line.range.location + line.range.length
                result.append(StyledRange(
                    range: NSRange(location: start, length: end - start),
                    kind: .codeBlock,
                    content: NSRange(location: contentStart, length: max(0, line.range.location - contentStart)),
                    payload: language
                ))
                fenceStart = nil
                language = ""
            } else {
                fenceStart = line.range.location
                contentStart = line.range.location + line.range.length
                language = fenceLanguage(ns.substring(with: line.range))
            }
        }
        return result
    }

    /// 缩进代码块（iA 方言）：连续 >=2 行以 tab 或四空格开头，且去掉缩进后不是列表/引用。
    private static func indentedCodeMatches(lines: [Line]) -> [StyledRange] {
        var result: [StyledRange] = []
        var blockStart: Int?
        var blockEnd = 0
        var blockLines = 0

        func flush() {
            if let start = blockStart, blockLines >= 2 {
                result.append(StyledRange(range: NSRange(location: start, length: blockEnd - start), kind: .codeBlock))
            }
            blockStart = nil
            blockLines = 0
        }

        for line in lines {
            if line.isFence {
                flush()
                continue
            }
            if line.isIndented, !line.isBlank, !line.looksLikeList {
                if blockStart == nil { blockStart = line.range.location }
                blockEnd = line.range.location + line.range.length
                blockLines += 1
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    /// 表格（行扫描）：连续以 `|` 开头的行组成一个表格块。
    private static func tableMatches(lines: [Line]) -> [StyledRange] {
        var result: [StyledRange] = []
        var blockStart: Int?
        var blockEnd = 0

        func flush() {
            if let start = blockStart {
                result.append(StyledRange(range: NSRange(location: start, length: blockEnd - start), kind: .table))
            }
            blockStart = nil
        }

        for line in lines {
            if line.isTableRow {
                if blockStart == nil { blockStart = line.range.location }
                blockEnd = line.range.location + line.range.length
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    /// 引用内围栏：剥离引用前缀后配对识别，围栏行只隐藏前缀之后的字符。
    private static func quotedFenceMatches(lines: [Line], text: String, excluding excluded: [NSRange]) -> [StyledRange] {
        let ns = text as NSString
        struct Pair { var open: Int; var close: Int; var language: String }
        var pairs: [Pair] = []
        var pending: (index: Int, language: String)?

        func bodyTrimmed(_ line: Line) -> String? {
            let start = line.range.location + line.prefixLength
            let length = line.range.length - line.prefixLength
            guard length > 0 else { return nil }
            return ns.substring(with: NSRange(location: start, length: length))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for (lineIndex, line) in lines.enumerated() {
            if excluded.contains(where: { NSLocationInRange(line.range.location, $0) }) { continue }
            guard let trimmedBody = bodyTrimmed(line), let fence = fenceInfo(trimmedBody) else { continue }
            if let opened = pending {
                pairs.append(Pair(open: opened.index, close: lineIndex, language: opened.language))
                pending = nil
            } else {
                pending = (lineIndex, fence.language)
            }
        }

        var result: [StyledRange] = []
        for pair in pairs {
            for lineIndex in pair.open...pair.close {
                let line = lines[lineIndex]
                let start = line.range.location + line.prefixLength
                let length = line.range.length - line.prefixLength
                guard length > 0 else { continue }
                let segment = NSRange(location: start, length: length)
                if lineIndex == pair.open || lineIndex == pair.close {
                    result.append(StyledRange(range: segment, kind: .comment, content: segment))
                } else {
                    result.append(StyledRange(range: segment, kind: .code, content: segment, payload: pair.language))
                }
            }
        }
        return result
    }

    /// 逐行规则（一次行扫描，替代原来的 7 条全文正则）：
    /// 标题 / 任务列表 / 引用 / 列表项 / 脚注定义 / 引用式链接定义。
    private static func lineRuleMatches(lines: [Line], chars: [unichar]) -> [StyledRange] {
        var result: [StyledRange] = []
        for line in lines where !line.isBlank {
            let start = line.range.location
            let end = line.contentEnd
            if let heading = headingMatch(chars, start: start, end: end) {
                result.append(heading)
            }
            if let quote = blockquoteMatch(chars, start: start, end: end) {
                result.append(quote)
            }
            var indent = start
            while indent < end, isHorizontalSpace(chars[indent]) { indent += 1 }
            if let task = taskListMatch(chars, start: indent, end: end) {
                result.append(task)
            }
            if let item = listItemMatch(chars, start: indent, end: end) {
                result.append(item)
            }
            if let footnote = footnoteMatch(chars, start: start, end: end) {
                result.append(footnote)
            } else if let ref = linkRefMatch(chars, start: start, end: end) {
                result.append(ref)
            }
        }
        return result
    }

    /// `^#{1,6} `（行首，不允许缩进），并剥离末尾交叉引用标签。
    private static func headingMatch(_ chars: [unichar], start: Int, end: Int) -> StyledRange? {
        var cursor = start
        while cursor < end, chars[cursor] == 0x23 { cursor += 1 }
        let level = cursor - start
        guard level >= 1, level <= 6, cursor < end, chars[cursor] == 0x20 else { return nil }
        let contentStart = cursor + 1
        var contentEnd = end
        if contentEnd - contentStart > 2, chars[contentEnd - 1] == 0x5D {
            var open = contentEnd - 2
            var found = false
            while open >= contentStart {
                let character = chars[open]
                if character == 0x5B { found = true; break }
                if character == 0x20 || character == 0x09 || character == 0x5D { break }
                open -= 1
            }
            if found, open > contentStart {
                var trimmed = open
                while trimmed > contentStart, isHorizontalSpace(chars[trimmed - 1]) { trimmed -= 1 }
                contentEnd = trimmed
            }
        }
        return StyledRange(
            range: NSRange(location: start, length: end - start),
            kind: .heading(level),
            content: NSRange(location: contentStart, length: contentEnd - contentStart)
        )
    }

    /// `^[ \t]*(?:>[ \t]*)+`，content 为前缀之后。
    private static func blockquoteMatch(_ chars: [unichar], start: Int, end: Int) -> StyledRange? {
        var cursor = start
        while cursor < end, isHorizontalSpace(chars[cursor]) { cursor += 1 }
        var hasQuote = false
        while cursor < end, chars[cursor] == 0x3E {
            hasQuote = true
            cursor += 1
            while cursor < end, isHorizontalSpace(chars[cursor]) { cursor += 1 }
        }
        guard hasQuote else { return nil }
        return StyledRange(
            range: NSRange(location: start, length: end - start),
            kind: .blockquote,
            content: NSRange(location: cursor, length: end - cursor)
        )
    }

    private static func taskListMatch(_ chars: [unichar], start: Int, end: Int) -> StyledRange? {
        guard start + 5 < end else { return nil }
        let marker = chars[start]
        guard marker == 0x2D || marker == 0x2A || marker == 0x2B,
              chars[start + 1] == 0x20,
              chars[start + 2] == 0x5B,
              chars[start + 4] == 0x5D,
              chars[start + 5] == 0x20 else { return nil }
        let check = chars[start + 3]
        guard check == 0x20 || check == 0x78 || check == 0x58 else { return nil }
        return StyledRange(range: NSRange(location: start, length: end - start), kind: .taskList)
    }

    private static func listItemMatch(_ chars: [unichar], start: Int, end: Int) -> StyledRange? {
        guard start < end else { return nil }
        let first = chars[start]
        if first == 0x2D || first == 0x2A || first == 0x2B {
            guard start + 1 < end, chars[start + 1] == 0x20 else { return nil }
        } else if first >= 0x30, first <= 0x39 {
            var cursor = start
            while cursor < end, chars[cursor] >= 0x30, chars[cursor] <= 0x39 { cursor += 1 }
            guard cursor + 1 < end, chars[cursor] == 0x2E, chars[cursor + 1] == 0x20 else { return nil }
        } else {
            return nil
        }
        return StyledRange(range: NSRange(location: start, length: end - start), kind: .listItem)
    }

    private static func footnoteMatch(_ chars: [unichar], start: Int, end: Int) -> StyledRange? {
        guard start + 3 < end, chars[start] == 0x5B, chars[start + 1] == 0x5E else { return nil }
        var cursor = start + 2
        while cursor < end, chars[cursor] != 0x5D { cursor += 1 }
        guard cursor > start + 2, cursor < end, chars[cursor] == 0x5D,
              cursor + 1 < end, chars[cursor + 1] == 0x3A else { return nil }
        return StyledRange(range: NSRange(location: start, length: end - start), kind: .footnote)
    }

    private static func linkRefMatch(_ chars: [unichar], start: Int, end: Int) -> StyledRange? {
        guard start + 3 < end, chars[start] == 0x5B else { return nil }
        var cursor = start + 1
        while cursor < end, chars[cursor] != 0x5D, chars[cursor] != 0x0A { cursor += 1 }
        guard cursor > start + 1, cursor < end, chars[cursor] == 0x5D,
              cursor + 1 < end, chars[cursor + 1] == 0x3A else { return nil }
        var after = cursor + 2
        var sawSpace = false
        while after < end, isHorizontalSpace(chars[after]) {
            after += 1
            sawSpace = true
        }
        guard sawSpace, after < end else { return nil }
        return StyledRange(range: NSRange(location: start, length: end - start), kind: .linkRef)
    }

    /// Setext 标题：文字行 + 下一行 `===`（h1）或 `---`（h2）。
    private static func setextHeadingMatches(
        lines: [Line],
        codeRanges: [NSRange],
        frontMatterRange: NSRange?
    ) -> [StyledRange] {
        guard lines.count >= 2 else { return [] }
        var result: [StyledRange] = []
        for index in 1..<lines.count {
            guard let level = lines[index].setextLevel else { continue }
            let previous = lines[index - 1]
            guard !previous.isBlank else { continue }
            if let frontMatterRange, NSLocationInRange(previous.range.location, frontMatterRange) { continue }
            if codeRanges.contains(where: { NSLocationInRange(previous.range.location, $0) }) { continue }
            let start = previous.range.location
            let end = lines[index].contentEnd
            guard end > start else { continue }
            result.append(StyledRange(
                range: NSRange(location: start, length: end - start),
                kind: .heading(level),
                content: NSRange(location: start, length: previous.contentEnd - start)
            ))
        }
        return result
    }

    /// front matter 区间（仅文件开头 `---` … `---`），供 setext 排除。
    private static func frontMatterRange(in text: String) -> NSRange? {
        guard text.hasPrefix("---") else { return nil }
        let start = text.index(text.startIndex, offsetBy: 3)
        guard let close = text.range(of: "\n---", range: start..<text.endIndex) else { return nil }
        let closeRange = NSRange(close, in: text)
        return NSRange(location: 0, length: closeRange.location + closeRange.length)
    }

    static func fenceLanguage(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["```", "~~~", "'''"] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
            break
        }
        return s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "{" }).first.map(String.init) ?? ""
    }

    /// Callout / GitHub Alerts：以 `> [!TYPE]` 起始的连续引用行组成一个块（payload = 类型）。
    private static func calloutMatches(in text: String, range: NSRange) -> [StyledRange] {
        let ns = text as NSString
        let pattern = #"^>\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*.*$"#
        guard let header = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return []
        }
        var result: [StyledRange] = []
        for match in header.matches(in: text, range: range) {
            let type = ns.substring(with: match.range(at: 1))
            var end = match.range.location + match.range.length
            // 向下吞并连续的 "> " 行
            while end < ns.length {
                let lineRange = ns.lineRange(for: NSRange(location: end, length: 0))
                let line = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
                if line.hasPrefix(">") {
                    end = lineRange.location + lineRange.length
                } else {
                    break
                }
            }
            result.append(StyledRange(
                range: NSRange(location: match.range.location, length: end - match.range.location),
                kind: .callout,
                payload: type
            ))
        }
        return result
    }

    /// AI 生成内容标注：独占一行的 `<!-- ai: gen|mix|human -->`，作用于紧随的一个块（到空行）。
    private static func aiMarkMatches(in text: String, range: NSRange) -> [StyledRange] {
        let ns = text as NSString
        guard let header = try? NSRegularExpression(
            pattern: #"^<!--\s*ai:\s*(gen|mix|human)\s*-->[ \t]*$"#,
            options: [.anchorsMatchLines]
        ) else { return [] }

        var result: [StyledRange] = []
        for match in header.matches(in: text, range: range) {
            let type = ns.substring(with: match.range(at: 1)).lowercased()
            var end = match.range.location + match.range.length
            // 吞并紧随的块到空行为止
            while end < ns.length {
                let lineRange = ns.lineRange(for: NSRange(location: end, length: 0))
                let line = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { break }
                end = lineRange.location + lineRange.length
            }
            result.append(StyledRange(
                range: NSRange(location: match.range.location, length: end - match.range.location),
                kind: .aiMark,
                payload: type
            ))
        }
        return result
    }

    private static func matches(
        in text: String,
        range: NSRange,
        pattern: String,
        kind: MarkdownTokenKind,
        contentGroup: Int? = nil,
        options: NSRegularExpression.Options = []
    ) -> [StyledRange] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: range).map { match in
            var content = match.range
            if let group = contentGroup {
                let captured = match.range(at: group)
                if captured.location != NSNotFound { content = captured }
            }
            _ = ns
            return StyledRange(range: match.range, kind: kind, content: content)
        }
    }
}
