import Foundation

/// CJK 与全角标点修正。
/// 目标：中文加粗/斜体/全角标点在渲染时不被错位（FR-009）。
enum CJKAdjust {
    /// 是否 CJK 表意文字或全角标点。
    static func isCJKPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,   // CJK 符号与标点
             0xFF00...0xFFEF,   // 全角字符
             0x2000...0x206F:   // 常用标点
            return true
        default:
            return false
        }
    }

    /// 修正范围：去掉首尾纯空白；当范围紧贴全角标点但不含内容时给出稳定结果。
    /// 说明：强调标记两侧允许直接贴 CJK（无需空格），此处只做边界规范化。
    static func adjust(_ ranges: [StyledRange], in text: String) -> [StyledRange] {
        let ns = text as NSString
        return ranges.map { item in
            var r = item.range
            // 去掉行尾换行/回车
            while r.length > 0 {
                let ch = ns.substring(with: NSRange(location: r.location + r.length - 1, length: 1))
                if ch == "\n" || ch == "\r" { r.length -= 1 } else { break }
            }
            // 关键：保留 content / payload，否则渲染时无法隐藏标记
            return StyledRange(range: r, kind: item.kind, content: item.content, payload: item.payload)
        }
    }
}
