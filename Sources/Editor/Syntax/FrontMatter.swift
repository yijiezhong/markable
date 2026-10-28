import Foundation

/// YAML front matter 的**极简**解析（仅 `key: value` 行；足够驱动元数据插值）。
enum FrontMatter {
    /// 从文档开头解析 front matter（`---` … `---`）。键统一小写。
    static func parse(_ text: String) -> [String: String] {
        guard text.hasPrefix("---") else { return [:] }
        let start = text.index(text.startIndex, offsetBy: 3)
        guard let endRange = text.range(of: "\n---", range: start..<text.endIndex) else { return [:] }
        let body = text[start..<endRange.lowerBound]

        var result: [String: String] = [:]
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}
