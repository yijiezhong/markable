import Foundation

/// 标题层级编号：给定各级别序列，产出 `1` / `1.1` / `1.1.2` 形式的编号。
/// 渲染器（按行）与大纲面板（按层级）共用同一套规则。
enum HeadingNumbering {
    static func numbers(levels: [Int]) -> [String] {
        var counters = [Int](repeating: 0, count: 7)   // 索引 1...6
        return levels.map { raw in
            let level = min(6, max(1, raw))
            counters[level] += 1
            if level < 6 {
                for deeper in (level + 1)...6 { counters[deeper] = 0 }
            }
            return (1...level).map { String(counters[$0]) }.joined(separator: ".")
        }
    }
}
