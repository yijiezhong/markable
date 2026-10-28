import CoreGraphics
import Foundation

/// 纸张与页边距设置（导出 PDF / 打印）。落到渲染层就是一条 CSS `@page` 规则。
struct PageSetup: Equatable {
    enum Paper: String, CaseIterable, Identifiable {
        case a4, a3, a5, letter, legal, flow
        var id: String { rawValue }

        var title: String {
            switch self {
            case .a4: return "A4"
            case .a3: return "A3"
            case .a5: return "A5"
            case .letter: return "Letter"
            case .legal: return "Legal"
            case .flow: return "流式"
            }
        }

        /// CSS `@page size` 关键字；流式返回 nil（不约束纸张，按内容连续）。
        var cssSize: String? {
            switch self {
            case .a4: return "A4"
            case .a3: return "A3"
            case .a5: return "A5"
            case .letter: return "letter"
            case .legal: return "legal"
            case .flow: return nil
            }
        }

        /// 点尺寸（1/72 inch，纵向），用于设置 WKWebView frame。
        var pointSize: CGSize {
            switch self {
            case .a4: return CGSize(width: 595.28, height: 841.89)
            case .a3: return CGSize(width: 841.89, height: 1190.55)
            case .a5: return CGSize(width: 419.53, height: 595.28)
            case .letter: return CGSize(width: 612, height: 792)
            case .legal: return CGSize(width: 612, height: 1008)
            case .flow: return CGSize(width: 595.28, height: 841.89)
            }
        }

        static func from(_ raw: String) -> Paper { Paper(rawValue: raw) ?? .a4 }
    }

    var paper: Paper = .a4
    /// 页边距（毫米），统一四边。
    var marginMM: Double = 20

    /// 内容区尺寸（点）：纸张点尺寸减去四边页边距。
    ///
    /// 与 `PDFPaginator` 里的 `contentWidth` / `contentHeight` 同一口径，
    /// 供“图片不得高于一页”这类排版约束使用（见 `HtmlRenderer` 的 `img { max-height }`）。
    var contentSize: CGSize {
        let size = paper.pointSize
        let margin = CGFloat(marginMM) * 72.0 / 25.4
        return CGSize(width: max(1, size.width - margin * 2),
                      height: max(1, size.height - margin * 2))
    }

    /// CSS `@page { … }` 规则。
    var cssRule: String {
        var parts: [String] = []
        if let size = paper.cssSize { parts.append("size: \(size)") }
        parts.append("margin: \(formattedMargin)mm")
        return "@page { \(parts.joined(separator: "; ")); }"
    }

    private var formattedMargin: String {
        // 去掉多余的小数点（20.0 → 20）
        marginMM == marginMM.rounded() ? String(Int(marginMM)) : String(format: "%.1f", marginMM)
    }
}
