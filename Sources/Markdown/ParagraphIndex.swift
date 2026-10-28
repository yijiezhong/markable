import Foundation

/// 段落索引：按空行切分，给出每个段落的**起始字符位置**。
/// 供 ⌥↑ / ⌥↓「上一段 / 下一段」跳转使用（阅读器里按段浏览比按行更顺手）。
enum ParagraphIndex {
    static func starts(in text: String) -> [Int] {
        let ns = text as NSString
        var starts: [Int] = []
        var index = 0
        var inParagraph = false

        while index < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
            let line = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                inParagraph = false
            } else if !inParagraph {
                starts.append(lineRange.location)
                inParagraph = true
            }
            if lineRange.length == 0 { break }
            index = lineRange.location + lineRange.length
        }
        return starts
    }

    /// 依据当前可见位置，取上一段（direction < 0）/ 下一段（direction > 0）的起点。
    static func target(in text: String, from anchor: Int, direction: Int) -> Int? {
        let starts = starts(in: text)
        guard !starts.isEmpty else { return nil }
        if direction > 0 {
            return starts.first { $0 > anchor + 1 }
        }
        return starts.last { $0 < anchor - 1 }
    }
}
