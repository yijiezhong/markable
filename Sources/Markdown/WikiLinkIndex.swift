import Foundation

/// Wiki 链接索引：解析 `[[目标]]`（支持 `[[目标|别名]]`），并统计反向链接。
enum WikiLinkIndex {
    /// 一条 wiki 链接（target 已去掉别名）。
    struct Link: Equatable {
        var target: String
        var line: Int
    }

    /// 提取正文中的出链（按出现顺序去重）。
    static func outgoingLinks(in text: String) -> [Link] {
        var result: [Link] = []
        var seen = Set<String>()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            for target in targets(in: String(rawLine)) {
                let key = target.lowercased()
                if seen.insert(key).inserted {
                    result.append(Link(target: target, line: index + 1))
                }
            }
        }
        return result
    }

    /// 一行里出现的全部目标（去别名、去空白）。
    static func targets(in line: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\[\[([^\[\]]+)\]\]"#) else { return [] }
        let ns = line as NSString
        return regex.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let inner = ns.substring(with: match.range(at: 1))
            let target = inner.split(separator: "|").first.map(String.init) ?? inner
            let trimmed = target.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// 反向链接：其它文件中链接到 `name` 的条目。
    struct Backlink: Equatable {
        var file: URL
        var line: Int
        var raw: String          // 匹配到的 `[[...]]` 原文
    }

    static func backlinks(for name: String, files: [URL], currentFile: URL?) -> [Backlink] {
        let key = name.lowercased()
        guard !key.isEmpty else { return [] }
        var result: [Backlink] = []
        for file in files {
            if let currentFile, file.standardizedFileURL == currentFile.standardizedFileURL { continue }
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, rawLine) in lines.enumerated() {
                let line = String(rawLine)
                if targets(in: line).contains(where: { $0.lowercased() == key }) {
                    result.append(Backlink(file: file, line: index + 1, raw: line.trimmingCharacters(in: .whitespaces)))
                }
            }
        }
        return result
    }

    /// 在同目录的 `.md` 文件中按名字（不含扩展名，忽略大小写）查找对应文件。
    static func resolve(target: String, in directory: URL?) -> URL? {
        guard let directory else { return nil }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let key = target.lowercased()
        return files.first {
            $0.pathExtension.lowercased() == "md" && $0.deletingPathExtension().lastPathComponent.lowercased() == key
        }
    }
}
