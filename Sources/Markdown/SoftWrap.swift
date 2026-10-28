import Foundation

/// 软换行接排：Markdown 里段落内的单个换行是"软换行"，渲染时应接排
/// （CJK 之间不插空格，其余用单个空格）。硬换行（行尾两空格或 `\`）保留。
///
/// 这里是**纯逻辑**：返回需要把「换行 + 下一行前导缩进」替换成什么；
/// 由 `LivePreviewController` 在替换阶段套用。
enum SoftWrap {
    struct Join: Equatable {
        var range: NSRange
        var replacement: String
    }

    static func joins(in text: String) -> [Join] {
        let lines = LineScanner(text)
        let protected = protectedRanges(in: text)
        var joins: [Join] = []
        var inFence = false

        for index in 0..<lines.count {
            let line = lines[index]
            if isFence(line.trimmed) { inFence.toggle(); continue }
            guard !inFence, index + 1 < lines.count else { continue }

            let next = lines[index + 1]
            let prevEff = effective(line)
            let nextEff = effective(next)

            guard !prevEff.text.isEmpty, !nextEff.text.isEmpty else { continue }
            guard !isBlockStart(prevEff.text) else { continue }        // 上一行是块级起点 → 段落已结束
            guard !isBlockStart(nextEff.text) else { continue }        // 下一行是块级起点 → 新块
            guard prevEff.isQuote == nextEff.isQuote else { continue } // 引用与非引用不混接
            guard !endsWithHardBreak(line.content) else { continue }   // 硬换行

            // 替换范围：上一行内容末尾的换行 + 下一行前导（引用标记 +）空白
            let start = NSMaxRange(line.range) - line.trailingNewlineLength
            let end = next.range.location + nextEff.prefixLength
            guard end >= start else { continue }
            // 跳过被隐藏/整体替换的多行结构（front matter / HTML 注释 / 块级数学）
            guard !protected.contains(where: { NSLocationInRange(start, $0) || NSLocationInRange(end, $0) }) else { continue }

            let replacement = joinSeparator(previous: prevEff.text, next: nextEff.text)
            joins.append(Join(range: NSRange(location: start, length: end - start), replacement: replacement))
        }
        return joins
    }

    /// 去掉行首的引用标记（可嵌套）后的有效内容。
    private struct Effective {
        var isQuote: Bool
        var prefixLength: Int      // 行内标记前缀长度（含前导空白与 `>`）
        var text: String           // 有效内容（去标记、去首尾空白）
    }

    private static let quotePrefixRegex = try? NSRegularExpression(pattern: #"^\s*(?:>\s*)+"#)

    private static func effective(_ line: Line) -> Effective {
        let content = line.content
        let ns = content as NSString
        var prefixLength = line.leadingWhitespaceLength
        var isQuote = false
        if let regex = quotePrefixRegex,
           let match = regex.firstMatch(in: content, range: NSRange(location: 0, length: ns.length)) {
            prefixLength = match.range.length
            isQuote = true
        }
        let rest = ns.substring(from: min(prefixLength, ns.length))
        return Effective(
            isQuote: isQuote,
            prefixLength: prefixLength,
            text: rest.trimmingCharacters(in: .whitespaces)
        )
    }

    /// 不能接排的结构：YAML front matter、HTML 注释、块级数学 `$$…$$`。
    private static func protectedRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        func add(_ pattern: String) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            for match in regex.matches(in: text, range: full) {
                var range = match.range
                // 把紧随其后的换行也纳入保护区，避免"结构结束行与下一行"被接排
                if range.location + range.length < ns.length, ns.character(at: range.location + range.length) == 10 {
                    range.length += 1
                }
                ranges.append(range)
            }
        }
        add(#"\A---\r?\n[\s\S]*?\r?\n---"#)          // front matter（仅文档开头）
        add(#"<!--[\s\S]*?-->"#)                     // HTML 注释
        add(#"\$\$[\s\S]*?\$\$"#)                    // 块级数学
        return ranges
    }

    // MARK: - 判定

    private static func joinSeparator(previous: String, next: String) -> String {
        guard let last = previous.last, let first = next.first else { return " " }
        return isCJK(last) && isCJK(first) ? "" : " "
    }

    private static func endsWithHardBreak(_ content: String) -> Bool {
        if content.hasSuffix("\\") { return true }
        return content.hasSuffix("  ")
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    private static func isFence(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") || trimmed.hasPrefix("'''")
    }

    static func isBlockStart(_ trimmed: String) -> Bool {
        if trimmed.isEmpty { return true }
        // 标题
        if trimmed.hasPrefix("#") {
            let hashes = trimmed.prefix { $0 == "#" }
            if hashes.count <= 6, trimmed.dropFirst(hashes.count).hasPrefix(" ") { return true }
        }
        // 围栏
        if isFence(trimmed) { return true }
        // 列表 / 引用
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") { return true }
        if isOrderedList(trimmed) { return true }
        if trimmed.hasPrefix(">") { return true }
        // 表格
        if trimmed.hasPrefix("|") { return true }
        // 分隔线 / 分页
        if isThematicOrPageBreak(trimmed) { return true }
        // 定义行
        if startsWithDefinition(trimmed) { return true }
        // HTML
        if trimmed.hasPrefix("<!--") || trimmed.hasPrefix("<") { return true }
        return false
    }

    private static func isOrderedList(_ trimmed: String) -> Bool {
        var i = trimmed.startIndex
        while i < trimmed.endIndex, trimmed[i].isNumber { i = trimmed.index(after: i) }
        return i > trimmed.startIndex && trimmed[i...].hasPrefix(". ")
    }

    private static func isThematicOrPageBreak(_ trimmed: String) -> Bool {
        for marker in ["-", "*", "_", "=", "+"] {
            let stripped = trimmed.replacingOccurrences(of: " ", with: "")
            if stripped.count >= 3, stripped.allSatisfy({ String($0) == marker }) { return true }
        }
        return false
    }

    private static func startsWithDefinition(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("[") else { return false }
        // `[^x]: …` 或 `[ref]: url`
        return trimmed.range(of: #"^\[[^\]\n]+\]:(\s|$)"#, options: .regularExpression) != nil
    }

    // MARK: - 行扫描

    private struct Line {
        var range: NSRange            // 含尾随换行
        var content: String           // 不含尾随换行
        var trimmed: String
        var leadingWhitespaceLength: Int
        var trailingNewlineLength: Int
    }

    private struct LineScanner {
        var lines: [Line] = []
        init(_ text: String) {
            let ns = text as NSString
            var index = 0
            while index < ns.length {
                let range = ns.lineRange(for: NSRange(location: index, length: 0))
                var content = ns.substring(with: range)
                var trailingNewline = 0
                if content.hasSuffix("\n") { content.removeLast(); trailingNewline = 1 }
                if content.hasSuffix("\r") { content.removeLast(); trailingNewline += 1 }
                let leading = content.prefix { $0 == " " || $0 == "\t" }.count
                lines.append(Line(
                    range: range,
                    content: content,
                    trimmed: content.trimmingCharacters(in: .whitespaces),
                    leadingWhitespaceLength: leading,
                    trailingNewlineLength: trailingNewline
                ))
                index = range.location + range.length
                if range.length == 0 { break }
            }
        }
        var count: Int { lines.count }
        subscript(_ i: Int) -> Line { lines[i] }
    }
}
