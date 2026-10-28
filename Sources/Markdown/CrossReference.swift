import Foundation

/// 交叉引用：标题末尾的 `[标签]` 作为锚点，正文里的 `[文字][标签]` 可跳转到该标题。
enum CrossReference {
    /// 收集"标题锚点"：返回 `标签 → 标题文本`。
    /// 仅认 `#… [标签]` 形式（标签在标题行末尾），标签不进标题文本。
    static func targets(in text: String) -> [String: String] {
        var result: [String: String] = [:]
        guard let regex = try? NSRegularExpression(
            pattern: #"^#{1,6}\s+(.*?)\s*\[([^\[\]\n]+)\]\s*$"#,
            options: [.anchorsMatchLines]
        ) else { return [:] }

        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let title = cleanTitle(ns.substring(with: match.range(at: 1)))
            let label = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, !title.isEmpty else { continue }
            result[label.lowercased()] = title
        }
        return result
    }

    /// 是否存在引用式链接定义 `[标签]: …`（此类由引用式链接处理，不再当交叉引用）。
    static func hasDefinition(_ label: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: label)
        guard let regex = try? NSRegularExpression(
            pattern: #"^\[\#(escaped)\]:\s*\S"#,
            options: [.anchorsMatchLines]
        ) else { return false }
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// 去掉标题里可能残留的行内标记（粗体/高亮等），用于跳转时按纯文本查找。
    private static func cleanTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespaces)
        for token in ["**", "__", "*", "_", "==", "`"] {
            title = title.replacingOccurrences(of: token, with: "")
        }
        return title.trimmingCharacters(in: .whitespaces)
    }
}
