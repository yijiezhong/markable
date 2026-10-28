import Foundation

/// 任务聚合：从正文里收集全部任务项（GFM `- [ ]` / `- [x]` 与 Craft 行首 `[]` / `[x]`），
/// 供侧栏"任务"面板汇总进度、点击跳转。跳过代码围栏内的内容。
enum TaskAggregator {
    struct Task: Equatable {
        var text: String
        var done: Bool
        var line: Int          // 1-based
    }

    static func tasks(in text: String) -> [Task] {
        var result: [Task] = []
        var inFence = false

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") || trimmed.hasPrefix("'''") {
                inFence.toggle()
                continue
            }
            if inFence { continue }

            if let task = parseGFM(trimmed) ?? parseCraft(trimmed) {
                result.append(Task(text: task.text, done: task.done, line: index + 1))
            }
        }
        return result
    }

    /// GFM：`- [ ] 文本` / `* [x] 文本` / `+ [X] 文本`
    private static func parseGFM(_ line: String) -> (text: String, done: Bool)? {
        guard let first = line.first, "-*+".contains(first) else { return nil }
        var rest = line.dropFirst().trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("[") , rest.count >= 3 else { return nil }
        let marker = rest[rest.index(rest.startIndex, offsetBy: 1)]
        let closeIndex = rest.index(rest.startIndex, offsetBy: 2)
        guard rest[closeIndex] == "]" else { return nil }
        let done = (marker == "x" || marker == "X")
        guard marker == " " || done else { return nil }
        rest = String(rest.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        return (rest, done)
    }

    /// Craft 方言：行首 `[] 文本` / `[x] 文本`
    private static func parseCraft(_ line: String) -> (text: String, done: Bool)? {
        guard line.hasPrefix("[") else { return nil }
        guard let close = line.firstIndex(of: "]") else { return nil }
        let marker = line[line.index(after: line.startIndex)..<close]
        guard marker.isEmpty || marker == " " || marker == "x" || marker == "X" else { return nil }
        let done = (marker == "x" || marker == "X")
        let text = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        return (text, done)
    }
}
