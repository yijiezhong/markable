import Foundation

/// 查找选项。
struct SearchOptions: Equatable {
    var caseSensitive = false
    var isRegex = false
    var wholeWord = false
}

/// 文档内查找的一条命中。
struct SearchMatch: Equatable {
    var line: Int          // 1-based
    var text: String       // 命中文本
    var preview: String    // 所在行（用于列表展示）
}

/// 文档内查找：支持大小写、整词、正则；返回逐条命中（供结果列表与跳转）。
enum DocumentSearch {
    /// ⌘G / ⇧⌘G 的循环索引（count 为 0 时返回 0）。
    static func nextIndex(current: Int, count: Int, direction: Int) -> Int {
        guard count > 0 else { return 0 }
        return (current + direction + count) % count
    }

    static func matches(in text: String, query: String, options: SearchOptions = SearchOptions()) -> [SearchMatch] {
        guard !query.isEmpty else { return [] }

        let pattern: String
        if options.isRegex {
            pattern = options.wholeWord ? "\\b(?:\(query))\\b" : query
        } else {
            let escaped = NSRegularExpression.escapedPattern(for: query)
            pattern = options.wholeWord ? "\\b\(escaped)\\b" : escaped
        }

        var regexOptions: NSRegularExpression.Options = []
        if !options.caseSensitive { regexOptions.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: regexOptions) else { return [] }

        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var result: [SearchMatch] = []

        for match in regex.matches(in: text, range: full) {
            let lineRange = ns.lineRange(for: NSRange(location: match.range.location, length: 0))
            let preview = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            let line = ns.substring(to: match.range.location).components(separatedBy: "\n").count
            result.append(SearchMatch(
                line: line,
                text: ns.substring(with: match.range),
                preview: preview
            ))
            if result.count >= 500 { break }
        }
        return result
    }
}
