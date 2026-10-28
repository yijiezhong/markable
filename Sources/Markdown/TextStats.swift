import Foundation

/// 文本统计：字符数 / 字数（中文按字 + 英文按词）/ 句数 / 预估阅读时长。
enum TextStats {
    struct Result: Equatable {
        var characters: Int
        var words: Int
        var sentences: Int
        var readingMinutes: Int
    }

    static func compute(_ text: String) -> Result {
        let characters = text.count

        // 字数：CJK 字符逐个计 + 拉丁词按空白分词
        var words = 0
        for scalar in text.unicodeScalars where isCJK(scalar) { words += 1 }
        if let latin = try? NSRegularExpression(pattern: #"[A-Za-z0-9]+"#) {
            words += latin.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        }

        // 句数：按 。！？.!? 结尾切分，非空计数
        var sentences = 0
        if let regex = try? NSRegularExpression(pattern: #"[^。！？.!?\n]+[。！？.!?]"#) {
            sentences = regex.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        } else {
            sentences = text.isEmpty ? 0 : 1
        }

        // 阅读时长：按 300 字/分钟
        let minutes = words == 0 ? 0 : max(1, Int((Double(words) / 300.0).rounded()))
        return Result(characters: characters, words: words, sentences: sentences, readingMinutes: minutes)
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF:
            return true
        default:
            return false
        }
    }
}
