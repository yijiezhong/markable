import Foundation

/// 文档体检：确定性规则（不做模型调用、不发网络）。
/// 覆盖 movable「已知失败模式」里可机械判定的一批，共 14 类。
/// 所有位置检查都在**屏蔽代码围栏后**的等长文本上进行，保证行号/偏移与原文一致。
enum Lint {
    struct Issue: Equatable {
        var line: Int
        var message: String
        var preview: String        // 命中所在行（供点击跳转）
    }

    static func check(_ text: String) -> [Issue] {
        var issues: [Issue] = []
        let lines = text.components(separatedBy: "\n")
        let masked = maskFences(lines)

        func preview(at index: Int) -> String {
            guard index >= 0, index < lines.count else { return "" }
            return lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // ── 逐行规则 ──
        var blankRun = 0
        var blankStart = 0
        var lastHeadingLevel = 0
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let fenceLine = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") || trimmed.hasPrefix("'''")
            if fenceLine { continue }

            // ① 行尾恰好一个空格（≥2 个是硬换行标记）
            if line.hasSuffix(" ") && !line.hasSuffix("  ") && !trimmed.isEmpty {
                issues.append(Issue(line: index + 1, message: "行尾多了一个空格", preview: preview(at: index)))
            }
            // ② 连续空行 ≥3
            if trimmed.isEmpty {
                if blankRun == 0 { blankStart = index + 1 }
                blankRun += 1
            } else {
                if blankRun >= 3 {
                    issues.append(Issue(line: blankStart, message: "连续 \(blankRun) 个空行（段落间一个即可）", preview: ""))
                }
                blankRun = 0
            }
            // ⑫ 标题级别跳跃
            if let hashes = headingLevel(trimmed) {
                if lastHeadingLevel > 0, hashes > lastHeadingLevel + 1 {
                    issues.append(Issue(line: index + 1, message: "标题层级跳跃（h\(lastHeadingLevel) → h\(hashes)）", preview: trimmed))
                }
                lastHeadingLevel = hashes
            }
        }
        if blankRun >= 3 {
            issues.append(Issue(line: blankStart, message: "连续 \(blankRun) 个空行", preview: ""))
        }

        // ⑥ 代码围栏未闭合
        if masked.fenceCount % 2 != 0 {
            issues.append(Issue(line: 1, message: "代码围栏（``` / ~~~ / '''）数量为奇数，可能有未闭合的代码块", preview: ""))
        }

        // ── 基于屏蔽文本的规则 ──
        issues.append(contentsOf: mathDelimiterIssues(masked.text, masked: masked))
        issues.append(contentsOf: inlineCodeIssues(masked.text, masked: masked))
        issues.append(contentsOf: longSentenceIssues(masked.text, mask: masked, preview: preview))
        issues.append(contentsOf: linkIssues(masked.text, mask: masked, preview: preview))
        issues.append(contentsOf: footnoteIssues(masked.text, mask: masked, preview: preview))

        return issues.sorted { $0.line < $1.line }
    }

    // MARK: - 规则实现

    /// ④ 行内 `$` 数量为奇数；⑤ 块级 `\[` / `\]` 不配对。
    private static func mathDelimiterIssues(_ text: String, masked: Mask) -> [Issue] {
        var issues: [Issue] = []
        let ns = text as NSString
        let dollarCount = occurrences(of: #"(?<!\\|\$)\$(?!\$)"#, in: text)
        if dollarCount % 2 != 0 {
            let offset = ns.range(of: "$").location
            let line = offset == NSNotFound ? 1 : masked.lineNumber(atUTF16Offset: offset, in: text)
            issues.append(Issue(line: line, message: "行内数学定界符 `$` 数量为奇数", preview: ""))
        }
        let openBracket = occurrences(of: #"(?<!\\)\\\["#, in: text)
        let closeBracket = occurrences(of: #"(?<!\\)\\\]"#, in: text)
        if openBracket != closeBracket {
            issues.append(Issue(line: 1, message: "块级数学定界符 \\(\\[ … \\]\\) 不配对", preview: ""))
        }
        return issues
    }

    /// ⑦ 行内代码反引号数量为奇数。
    private static func inlineCodeIssues(_ text: String, masked: Mask) -> [Issue] {
        let count = occurrences(of: #"(?<!`)(`)(?!`)"#, in: text)
        guard count % 2 != 0 else { return [] }
        return [Issue(line: 1, message: "行内代码反引号 `` ` `` 数量为奇数，可能有未闭合的行内代码", preview: "")]
    }

    /// ③ 超长句（可见字符 > 300）。
    private static func longSentenceIssues(_ text: String, mask: Mask, preview: (Int) -> String) -> [Issue] {
        guard let regex = try? NSRegularExpression(pattern: #"[^。！？.!?\n]{301,}"#) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            let line = mask.lineNumber(atUTF16Offset: match.range.location, in: text)
            return Issue(line: line, message: "超长句（>300 字）", preview: preview(line - 1))
        }
    }

    /// ⑩⑪⑬⑭ 链接相关。
    private static func linkIssues(_ text: String, mask: Mask, preview: (Int) -> String) -> [Issue] {
        var issues: [Issue] = []
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        // ⑭ 图片缺少替代文本
        appendMatches(#"!\[\]\("#, text: text, into: &issues, mask: mask, preview: preview,
                      message: "图片缺少替代文本（alt）")
        // ⑬ 空链接/图片目标
        appendMatches(#"\]\(\s*\)"#, text: text, into: &issues, mask: mask, preview: preview,
                      message: "链接或图片的目标为空")

        // 引用式链接定义 `[ref]: url`（排除脚注定义 `[^x]:`）
        var definitions = Set<String>()
        if let defRegex = try? NSRegularExpression(pattern: #"^\[([^\]\n^][^\]\n]*)\]:\s*\S"#, options: [.anchorsMatchLines]) {
            for match in defRegex.matches(in: text, range: full) {
                definitions.insert(ns.substring(with: match.range(at: 1)).lowercased())
            }
        }
        // 交叉引用标签（`标题 [标签]`）不是链接定义，不应判为"未定义链接"
        let crossRefTargets = Set(CrossReference.targets(in: text).keys)
        // 引用式链接使用 `[text][ref]`
        var used = Set<String>()
        if let useRegex = try? NSRegularExpression(pattern: #"\[[^\[\]\n]+\]\[([^\[\]\n]+)\]"#) {
            for match in useRegex.matches(in: text, range: full) {
                let ref = ns.substring(with: match.range(at: 1)).lowercased()
                if crossRefTargets.contains(ref) { continue }   // 交叉引用，交由交叉引用机制处理
                used.insert(ref)
                if !definitions.contains(ref) {
                    let line = mask.lineNumber(atUTF16Offset: match.range.location, in: text)
                    issues.append(Issue(line: line, message: "引用了未定义的链接 `[\(ref)]`", preview: preview(line - 1)))
                }
            }
        }
        // ⑪ 未使用的链接定义
        for ref in definitions where !used.contains(ref) {
            let pattern = #"^\[\#(NSRegularExpression.escapedPattern(for: ref))\]:\s*\S"#
            if let defRegex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines, .caseInsensitive]),
               let match = defRegex.firstMatch(in: text, range: full) {
                let line = mask.lineNumber(atUTF16Offset: match.range.location, in: text)
                issues.append(Issue(line: line, message: "链接定义 `[\(ref)]` 未被引用", preview: preview(line - 1)))
            }
        }
        return issues
    }

    /// ⑧⑨ 脚注引用/定义配对。
    private static func footnoteIssues(_ text: String, mask: Mask, preview: (Int) -> String) -> [Issue] {
        var issues: [Issue] = []
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        var definitions = Set<String>()
        if let defRegex = try? NSRegularExpression(pattern: #"^\[\^([^\]\n]+)\]:[ \t]*"#, options: [.anchorsMatchLines]) {
            for match in defRegex.matches(in: text, range: full) {
                definitions.insert(ns.substring(with: match.range(at: 1)).lowercased())
            }
        }
        var used = Set<String>()
        if let refRegex = try? NSRegularExpression(pattern: #"\[\^([^\]\n]+)\](?!:)"#) {
            for match in refRegex.matches(in: text, range: full) {
                let label = ns.substring(with: match.range(at: 1)).lowercased()
                used.insert(label)
                if !definitions.contains(label) {
                    let line = mask.lineNumber(atUTF16Offset: match.range.location, in: text)
                    issues.append(Issue(line: line, message: "引用了未定义的脚注 `[^\(label)]`", preview: preview(line - 1)))
                }
            }
        }
        for label in definitions where !used.contains(label) {
            let line = mask.lineNumber(atUTF16Offset: 0, in: text)
            issues.append(Issue(line: line, message: "脚注定义 `[^\(label)]` 未被引用", preview: ""))
        }
        return issues
    }

    // MARK: - 辅助

    private static func appendMatches(
        _ pattern: String, text: String, into issues: inout [Issue], mask: Mask,
        preview: (Int) -> String, message: String
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let line = mask.lineNumber(atUTF16Offset: match.range.location, in: text)
            issues.append(Issue(line: line, message: message, preview: preview(line - 1)))
        }
    }

    private static func occurrences(of pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static func headingLevel(_ trimmed: String) -> Int? {
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }
        guard hashes.count <= 6, trimmed.dropFirst(hashes.count).hasPrefix(" ") else { return nil }
        return hashes.count
    }

    /// 屏蔽代码围栏后的文本（等长；围栏内容替换为空格，保留换行）。
    private struct Mask {
        var text: String
        var fenceCount: Int

        func lineNumber(atUTF16Offset offset: Int, in original: String) -> Int {
            let ns = original as NSString
            let safe = min(max(0, offset), ns.length)
            let prefix = ns.substring(to: safe)
            return prefix.components(separatedBy: "\n").count
        }
    }

    /// 把围栏代码块内容替换为等长空格（围栏行保留，便于计数）。
    private static func maskFences(_ lines: [String]) -> Mask {
        var fenceCount = 0
        var inFence = false
        var out: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isFence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") || trimmed.hasPrefix("'''")
            if isFence {
                fenceCount += 1
                inFence.toggle()
                out.append(line)
            } else if inFence {
                out.append(String(repeating: " ", count: line.count))
            } else {
                out.append(line)
            }
        }
        return Mask(text: out.joined(separator: "\n"), fenceCount: fenceCount)
    }
}
