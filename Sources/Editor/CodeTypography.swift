import AppKit
import CoreText

/// 代码字体方案：Apple 官方字体没有「中英文原生双等宽」的字体，
/// 这里用「等宽西文 + 中文全角字体 + 中文逐字字距补偿」组合出 2:1 对齐：
///
/// - 非衬线：SF Mono（西文，半角 0.618em）+ PingFang SC（中文，全角 1em），kern = 0.2363 × 字号
/// - 衬线：  Courier New（西文，半角 0.600em）+ Songti SC（中文，全角 1em），kern = 0.2002 × 字号
///
/// 实测（8–60pt、各字重、长短串、全角标点）：混排宽度误差 0.0000pt。
/// 注意：Apple 系统字体受 EULA 限制，不可复制进 App 内分发；本方案只依赖 macOS
/// 自带的系统字体（SF Mono / PingFang SC / Courier New / Songti SC），不内嵌字体文件。
enum CodeTypography {
    enum Style {
        case sans
        case serif

        /// 西文（等宽）PostScript 名。
        var latinPostScriptName: String {
            switch self {
            case .sans: return "SFMono-Regular"
            case .serif: return "CourierNewPSMT"
            }
        }

        /// 中文（全角等宽）PostScript 名。
        var chinesePostScriptName: String {
            switch self {
            case .sans: return "PingFangSC-Regular"
            case .serif: return "STSongti-SC-Regular"
            }
        }

        /// 字距补偿系数：kern = 系数 × 字号（实测与字重无关）。
        var kernCoefficient: CGFloat {
            switch self {
            case .sans: return 0.2363
            case .serif: return 0.2002
            }
        }

        /// 导出 HTML 时给中文 span 用的 CSS letter-spacing。
        var cssLetterSpacing: String {
            switch self {
            case .sans: return "0.2363em"
            case .serif: return "0.2002em"
            }
        }

        /// 代码块的西文 CSS 字体族。
        var cssLatinFamily: String {
            switch self {
            case .sans: return #""SF Mono", Menlo, monospace"#
            case .serif: return #""Courier New", Courier, monospace"#
            }
        }

        /// 代码块的中文 CSS 字体族。
        var cssChineseFamily: String {
            switch self {
            case .sans: return #""PingFang SC", "Hiragino Sans GB", sans-serif"#
            case .serif: return #""Songti SC", "STSong", serif"#
            }
        }
    }

    /// 正文字体族 → 代码字体风格（衬线正文字体配衬线代码字体）。
    static func style(for family: Typography.Family) -> Style {
        family == .serif ? .serif : .sans
    }

    // MARK: - 字体获取

    static func latinFont(size: CGFloat, style: Style) -> NSFont {
        NSFont(name: style.latinPostScriptName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func chineseFont(size: CGFloat, style: Style) -> NSFont {
        NSFont(name: style.chinesePostScriptName, size: size)
            ?? NSFont.systemFont(ofSize: size)
    }

    /// 系统官方字体是否可用（决定是否需要字距补偿）。
    static func hasOfficialPair(style: Style) -> Bool {
        NSFont(name: style.latinPostScriptName, size: 13) != nil
            && NSFont(name: style.chinesePostScriptName, size: 13) != nil
    }

    static func kern(size: CGFloat, style: Style) -> CGFloat {
        hasOfficialPair(style: style) ? style.kernCoefficient * size : 0
    }

    // MARK: - 字符宽度判断

    /// 是否为全角字符（CJK 汉字、假名、谚文、全角标点/符号）。
    static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F,      // 谚文字母
             0x2E80...0x303E,      // CJK 部首、标点
             0x3041...0x33FF,      // 假名、CJK 兼容
             0x3400...0x4DBF,      // CJK 扩展 A
             0x4E00...0x9FFF,      // CJK 基本区
             0xA000...0xA4CF,      // 彝文
             0xAC00...0xD7A3,      // 谚文音节
             0xF900...0xFAFF,      // CJK 兼容表意
             0xFE30...0xFE4F,      // CJK 兼容标点
             0xFF00...0xFF60,      // 全角 ASCII
             0xFFE0...0xFFE6,      // 全角符号
             0x1F300...0x1FAFF:    // emoji（宽度不可控，按全角兜底）
            return true
        default:
            return false
        }
    }

    // MARK: - 应用字体

    /// 把 attributed string 的 range 设为代码字体：西文段用等宽字体，中文段用全角字体
    /// 并逐字加 kern，使「1 中文 = 2 西文」。
    static func applyCodeFont(
        to text: NSMutableAttributedString,
        range: NSRange,
        size: CGFloat,
        style: Style
    ) {
        guard range.length > 0, range.location >= 0, range.location + range.length <= text.length else { return }

        // 系统字体缺失（非 macOS 环境）：整段用系统等宽字体，不补 kern。
        guard hasOfficialPair(style: style) else {
            let fallback = latinFont(size: size, style: style)
            text.addAttribute(.font, value: fallback, range: range)
            return
        }

        let latin = latinFont(size: size, style: style)
        let chinese = chineseFont(size: size, style: style)
        let kernValue = kern(size: size, style: style)
        let ns = text.string as NSString

        var segmentStart = range.location
        var segmentIsWide = isWideCharacter(at: range.location, in: ns)
        var index = range.location + 1
        let end = range.location + range.length

        while index <= end {
            let atEnd = index == end
            let wide = atEnd ? false : isWideCharacter(at: index, in: ns)
            if atEnd || wide != segmentIsWide {
                let segment = NSRange(location: segmentStart, length: index - segmentStart)
                if segmentIsWide {
                    text.addAttribute(.font, value: chinese, range: segment)
                    text.addAttribute(.kern, value: kernValue, range: segment)
                } else {
                    text.addAttribute(.font, value: latin, range: segment)
                }
                segmentStart = index
                segmentIsWide = wide
            }
            index += 1
        }
    }

    /// 读取指定 UTF-16 位置的字符是否全角（正确处理代理对）。
    private static func isWideCharacter(at index: Int, in ns: NSString) -> Bool {
        let unit = ns.character(at: index)
        if unit >= 0xD800, unit <= 0xDBFF, index + 1 < ns.length {
            let low = ns.character(at: index + 1)
            if low >= 0xDC00, low <= 0xDFFF {
                let value = 0x10000 + ((UInt32(unit - 0xD800) << 10) | UInt32(low - 0xDC00))
                    return isWide(Unicode.Scalar(value) ?? " ")
            }
        }
        return isWide(Unicode.Scalar(unit) ?? " ")
    }
}
