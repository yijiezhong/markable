import Foundation

/// 行内语法识别：图片、粗体、斜体、行内代码、链接。
/// 每条规则记录"内容"所在的捕获组，渲染时隐藏其余标记。
enum InlineSyntax {
    /// (正则, 语义, 内容捕获组索引)
    private static let rules: [(pattern: String, kind: MarkdownTokenKind, contentGroup: Int)] = [
        (#"\*\*([^*\n]+)\*\*"#, .bold, 1),
        (#"__([^_\n]+)__"#, .bold, 1),
        (#"(?<!\*)\*([^*\n]+)\*(?!\*)"#, .italic, 1),
        (#"(?<!_)_([^_\n]+)_(?!_)"#, .italic, 1),
        (#"`([^`\n]+)`"#, .code, 1),
        (#"==([^=\n]+)=="#, .highlight, 1),
        (#"~~([^~\n]+)~~"#, .strikethrough, 1),
        (#"\[\[([^\]\n]+)\]\]"#, .link, 1),
        (#"::(\S[^:\n]*?)::"#, .highlight, 1),
        (#"~([^~\n]+)~"#, .subscriptText, 1),
        (#"\^([^\^\n]+)\^"#, .superscriptText, 1),
        (#"<u>([^<\n]+)</u>"#, .underlineText, 1),
        (#"\[\^([^\]\n]+)\]"#, .footnoteRef, 1),
        (#"\^\[([^\]\n]+)\]"#, .footnoteRef, 1),
        (#"(?<!!)\[([^\]\n]+)\]\(([^)\n]+)\)"#, .link, 1),
        (#"(?<!!)\[([^\]\n]+)\]\[([^\]\n]*)\]"#, .link, 1),
    ]

    /// 识别文本中的行内语法片段（图片优先，带 path payload 与 alt 内容范围）。
    static func ranges(in text: String) -> [StyledRange] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var result: [StyledRange] = []

        // 行内图片：`![alt](path "title")` / `![alt](<path with space> "title")`
        // alt 可为空；路径后的 title 不进入 payload。
        if let imageRegex = try? NSRegularExpression(
            pattern: #"!\[([^\]\n]*)\]\(\s*(?:<([^>\n]*)>|([^)\s]+))(?:\s+["'][^"']*["'])?\s*\)"#
        ) {
            for match in imageRegex.matches(in: text, range: full) {
                let pathRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
                let path = ns.substring(with: pathRange)
                result.append(StyledRange(
                    range: match.range,
                    kind: .image,
                    content: match.range(at: 1),
                    payload: path
                ))
            }
        }

        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            for match in regex.matches(in: text, range: full) {
                let content = match.range(at: rule.contentGroup)
                result.append(StyledRange(
                    range: match.range,
                    kind: rule.kind,
                    content: content.location != NSNotFound ? content : match.range
                ))
            }
        }
        // 粗斜体：`***x***` → 加粗 + 斜体（并过滤 `**` / `*` 规则对同一段的重复匹配）
        var boldItalicRanges: [NSRange] = []
        if let boldItalic = try? NSRegularExpression(pattern: #"\*\*\*([^*\n]+)\*\*\*"#) {
            for match in boldItalic.matches(in: text, range: full) {
                boldItalicRanges.append(match.range)
                let content = match.range(at: 1)
                result.append(StyledRange(range: match.range, kind: .bold, content: content))
                result.append(StyledRange(range: match.range, kind: .italic, content: content))
            }
        }
        if !boldItalicRanges.isEmpty {
            result = result.filter { item in
                if boldItalicRanges.contains(item.range) { return true }
                return !boldItalicRanges.contains { NSIntersectionRange($0, item.range).length > 0 }
            }
        }

        // 转义序列（`\` + 标点）：转义字符及其标记不参与语法识别
        // 例如 `\*不是斜体\*` 不应匹配成斜体。
        var escapeRanges: [NSRange] = []
        if let escapeRegex = try? NSRegularExpression(pattern: #"\\[\\`*_{}\[\]()#+\-.!|>~^=]"#) {
            escapeRanges = escapeRegex.matches(in: text, range: full).map(\.range)
        }
        if !escapeRanges.isEmpty {
            result = result.filter { item in
                !escapeRanges.contains { NSIntersectionRange($0, item.range).length > 0 }
            }
        }

        return result.sorted { $0.range.location < $1.range.location }
    }
}
