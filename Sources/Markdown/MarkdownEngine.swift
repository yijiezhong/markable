import Foundation
import Markdown

/// 大纲条目（用于导出书签与大纲面板）。
struct OutlineItem: Equatable {
    var title: String
    var level: Int
}

/// Markdown 解析与序列化引擎，基于 swift-markdown（cmark-gfm）。
/// 保证纯 Markdown 往返保真（FR-006）。
struct MarkdownEngine {
    /// 解析 Markdown 文本为 AST。
    func parse(_ text: String) -> Markdown.Document {
        Markdown.Document(parsing: text)
    }

    /// 序列化 AST 回 Markdown 文本。
    func serialize(_ document: Markdown.Document) -> String {
        document.format()
    }

    /// 往返：解析后再序列化。
    func roundTrip(_ text: String) -> String {
        serialize(parse(text))
    }

    /// 提取标题大纲（供 PDF 书签与大纲面板使用）。
    /// 提取大纲标题（**先剥掉 front matter**，否则 `---` 会把 YAML 当成 setext 标题）。
    func outline(of text: String) -> [OutlineItem] {
        let document = parse(Self.strippingFrontMatter(text))
        var items: [OutlineItem] = []
        collectOutline(document, into: &items)
        return items
    }

    /// 去掉开头的 YAML front matter（`---` … `---`），返回正文。
    static func strippingFrontMatter(_ text: String) -> String {
        guard text.hasPrefix("---") else { return text }
        let start = text.index(text.startIndex, offsetBy: 3)
        guard let closing = text.range(of: "\n---", range: start..<text.endIndex) else { return text }
        var index = closing.upperBound
        // 越过该行剩余的 `-`
        while index < text.endIndex, text[index] == "-" { index = text.index(after: index) }
        // 越过行尾换行
        if index < text.endIndex, text[index] == "\n" { index = text.index(after: index) }
        return String(text[index...])
    }

    private func collectOutline(_ markup: Markup, into items: inout [OutlineItem]) {
        if let heading = markup as? Heading {
            let title = Self.strippingTrailingLabel(heading.plainText)
            items.append(OutlineItem(title: title, level: heading.level))
            return
        }
        for child in markup.children {
            collectOutline(child, into: &items)
        }
    }

    /// 去掉标题末尾的交叉引用标签 `[标签]`（与渲染一致，标签不进标题）。
    static func strippingTrailingLabel(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard let regex = try? NSRegularExpression(pattern: #"^(.*?)\s*\[[^\[\]]+\]\s*$"#) else { return trimmed }
        let ns = trimmed as NSString
        guard let match = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) else { return trimmed }
        return ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
    }
}
