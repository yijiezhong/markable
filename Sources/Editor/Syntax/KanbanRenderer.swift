import AppKit

/// 自研 **Mermaid `kanban`** 渲染（swift-mermaid 不支持）：解析列/卡片 → 横向分栏 → 纯 AppKit 绘制。
///
/// 支持的语法（简化子集）：
/// ```
/// kanban
///   todo[待办]
///     t1[写解析器]
///     t2[补测试] @{ assigned: 'kimi' }
///   doing[进行中]
///     [没有 ID 的卡片]
///   done[已完成]
/// ```
/// - 首行 `kanban`；之后按缩进分层：**第一行有效内容的缩进**作为「列缩进基线」，
///   缩进 ≤ 基线的行定义列（`列ID[列标题]`，无方括号时整行即标题），
///   缩进更大的行是上一列的卡片（`卡片ID[卡片文本]`、`[卡片文本]`、`id(文本)` 或裸文本）。
/// - 行内 `@{ ... }` 卡片元数据会被丢弃；`%%` 注释行忽略。
/// - 没有任何列时返回 nil（调用方回退源码并提示）。
enum KanbanRenderer {
    private struct Card {
        var text: String
    }

    private struct Column {
        var title: String
        var cards: [Card] = []
    }

    // 画布与排版常量：宽度上限 1200pt，便于嵌入正文预览。
    private static let padding: CGFloat = 16
    private static let columnGap: CGFloat = 12
    private static let columnInset: CGFloat = 8
    private static let maxColumnWidth: CGFloat = 240
    private static let maxCanvasWidth: CGFloat = 1200
    private static let headerHeight: CGFloat = 28
    private static let cardHeight: CGFloat = 38
    private static let cardGap: CGFloat = 8
    private static let minColumnHeight: CGFloat = 72

    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let cardFont = NSFont.systemFont(ofSize: 11)

    static func image(forSource source: String) -> NSImage? {
        guard let columns = parse(MermaidSource.stripped(source)), !columns.isEmpty else { return nil }

        // 先按可用宽度均分，再夹到上限；不抬下限，保证总宽不超 1200pt。
        let count = CGFloat(columns.count)
        let available = maxCanvasWidth - padding * 2 - columnGap * (count - 1)
        let columnWidth = min(maxColumnWidth, max(1, (available / count).rounded(.down)))
        let width = padding * 2 + columnWidth * count + columnGap * (count - 1)

        let cardCount = columns.map(\.cards.count).max() ?? 0
        let bodyHeight = cardCount > 0
            ? CGFloat(cardCount) * cardHeight + CGFloat(cardCount - 1) * cardGap
            : 0
        let columnHeight = max(minColumnHeight, headerHeight + 10 + bodyHeight + columnInset)
        let height = padding * 2 + columnHeight

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.textBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        for (index, column) in columns.enumerated() {
            let x = padding + CGFloat(index) * (columnWidth + columnGap)
            drawColumn(column, at: x, width: columnWidth, height: columnHeight)
        }
        return image
    }

    // MARK: - 解析

    private static func parse(_ source: String) -> [Column]? {
        var columns: [Column] = []
        var baseline: Int?
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("%%") else { continue }
            if trimmed.lowercased() == "kanban" { continue }
            // 独立的卡片属性行（如 `assigned: 'x', priority: 'High'`）不单独成卡。
            if trimmed.hasPrefix("@{") { continue }
            let text = displayText(stripMetadata(trimmed))
            guard !text.isEmpty else { continue }

            let indent = leadingIndent(of: line)
            let base = baseline ?? indent
            baseline = base
            if indent <= base || columns.isEmpty {
                columns.append(Column(title: text))
            } else {
                columns[columns.count - 1].cards.append(Card(text: text))
            }
        }
        return columns.isEmpty ? nil : columns
    }

    /// 去掉行内的 `@{ ... }` 元数据后缀。
    private static func stripMetadata(_ text: String) -> String {
        guard let range = text.range(of: "@{") else { return text }
        return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    /// 取列/卡片的显示文本：支持 `id[标题]`、`[标题]`、`id(标题)`，其余原样保留。
    private static func displayText(_ text: String) -> String {
        let body = unquote(text.trimmingCharacters(in: .whitespaces))
        guard !body.isEmpty else { return body }

        if let close = body.lastIndex(of: "]"), close > body.startIndex {
            let before = body[..<close]
            if let open = before.lastIndex(of: "[") {
                let prefix = before[..<open]
                if prefix.isEmpty || isIdentifier(prefix) {
                    return unquote(String(before[before.index(after: open)...]).trimmingCharacters(in: .whitespaces))
                }
            }
        }
        if let close = body.lastIndex(of: ")"), close > body.startIndex {
            let before = body[..<close]
            if let open = before.lastIndex(of: "("), isIdentifier(before[..<open]) {
                return unquote(String(before[before.index(after: open)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return body
    }

    private static func isIdentifier(_ text: Substring) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    private static func unquote(_ text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespaces)
        if body.count >= 2, body.hasPrefix("\""), body.hasSuffix("\"") {
            body = String(body.dropFirst().dropLast())
        } else if body.count >= 2, body.hasPrefix("'"), body.hasSuffix("'") {
            body = String(body.dropFirst().dropLast())
        }
        return body.trimmingCharacters(in: .whitespaces)
    }

    /// 行首缩进：空格记 1，tab 记 4（贴合 Mermaid 缩进习惯）。
    private static func leadingIndent(of line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " {
                count += 1
            } else if character == "\t" {
                count += 4
            } else {
                break
            }
        }
        return count
    }

    // MARK: - 绘制

    private static func drawColumn(_ column: Column, at x: CGFloat, width: CGFloat, height: CGFloat) {
        let columnRect = NSRect(x: x, y: padding, width: width, height: height)
        let background = NSBezierPath(roundedRect: columnRect, xRadius: 8, yRadius: 8)
        NSColor.quaternaryLabelColor.setFill()
        background.fill()

        // 列标题（顶部）与分隔线。
        let titleRect = NSRect(x: x + columnInset, y: columnRect.maxY - headerHeight,
                               width: max(1, width - columnInset * 2), height: headerHeight - 6)
        let title = fitted(column.title, font: titleFont, maxWidth: titleRect.width)
        let titleSize = (title as NSString).size(withAttributes: [.font: titleFont])
        (title as NSString).draw(
            at: NSPoint(x: titleRect.minX, y: titleRect.midY - titleSize.height / 2),
            withAttributes: [.font: titleFont, .foregroundColor: NSColor.labelColor]
        )

        let separatorY = columnRect.maxY - headerHeight
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: columnRect.minX + columnInset, y: separatorY))
        separator.line(to: NSPoint(x: columnRect.maxX - columnInset, y: separatorY))
        NSColor.separatorColor.setStroke()
        separator.lineWidth = 0.5
        separator.stroke()

        // 卡片自上而下堆叠。
        var top = separatorY - 10
        for card in column.cards {
            let cardRect = NSRect(x: x + columnInset, y: top - cardHeight,
                                  width: max(1, width - columnInset * 2), height: cardHeight)
            let path = NSBezierPath(roundedRect: cardRect, xRadius: 6, yRadius: 6)
            NSColor.textBackgroundColor.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 0.5
            path.stroke()

            let text = fitted(card.text, font: cardFont, maxWidth: max(1, cardRect.width - 16))
            let size = (text as NSString).size(withAttributes: [.font: cardFont])
            (text as NSString).draw(
                at: NSPoint(x: cardRect.minX + 8, y: cardRect.midY - size.height / 2),
                withAttributes: [.font: cardFont, .foregroundColor: NSColor.labelColor]
            )
            top -= (cardHeight + cardGap)
        }
    }

    /// 单行截断到指定宽度（超出时以 `…` 结尾），保证文字不溢出。
    private static func fitted(_ text: String, font: NSFont, maxWidth: CGFloat) -> String {
        guard maxWidth > 8 else { return "" }
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        if (text as NSString).size(withAttributes: attributes).width <= maxWidth { return text }
        var characters = Array(text)
        while !characters.isEmpty {
            characters.removeLast()
            let candidate = String(characters) + "…"
            if (candidate as NSString).size(withAttributes: attributes).width <= maxWidth {
                return candidate
            }
        }
        return "…"
    }
}
