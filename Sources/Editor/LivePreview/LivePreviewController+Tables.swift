import AppKit

/// `LivePreviewController` 的表格渲染：`| A | B |` → `NSTextTable` 网格，
/// 含行列解析、列宽测量与单元格内行内语法。
/// （自 `LivePreviewController.swift` 机械拆分，逻辑未改。）
extension LivePreviewController {
    /// 表格 → 真网格：把 `| A | B |` 结构重建成「每格一段 + `NSTextTableBlock`」，
    /// 由 TextKit1 的 `NSTextTable` 负责画网格线（替换阶段整体替换）。
    func collectTableReplacements(
        in storage: NSMutableAttributedString,
        into list: inout [(range: NSRange, text: NSAttributedString)]
    ) {
        let text = storage.string
        let ns = text as NSString
        let tables = cachedBlockRanges.filter { $0.kind == .table }
        for (tableIndex, table) in tables.enumerated() {
            let rows = parseTableRows(in: ns, range: table.range)
            guard rows.count >= 2 else { continue }
            let alignments = parseTableAlignments(in: ns, range: table.range)
            let attributed = makeTable(rows, alignments: alignments, tableIndex: tableIndex)
            guard attributed.length > 0 else { continue }
            list.append((table.range, attributed))
        }
    }

    /// 解析表格为「行 → 单元格文本」（去掉分隔行与首尾空列）。
    private func parseTableRows(in ns: NSString, range: NSRange) -> [[String]] {
        var rows: [[String]] = []
        var index = range.location
        let end = range.location + range.length
        while index < end {
            let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
            let line = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if !isSeparatorLine(line) && !line.isEmpty {
                var cells = Self.splitTableRow(line)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.first?.isEmpty == true { cells.removeFirst() }
                if cells.last?.isEmpty == true { cells.removeLast() }
                rows.append(cells)
            }
            if lineRange.length == 0 { break }
            index = lineRange.location + lineRange.length
        }
        return rows
    }

    /// 解析表格分隔行（`|---|:---:|---:|`）得到每列对齐方式。
    private func parseTableAlignments(in ns: NSString, range: NSRange) -> [NSTextAlignment] {
        var index = range.location
        let end = range.location + range.length
        while index < end {
            let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
            let line = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if isSeparatorLine(line) {
                var cells = Self.splitTableRow(line).map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.first?.isEmpty == true { cells.removeFirst() }
                if cells.last?.isEmpty == true { cells.removeLast() }
                return cells.map { cell in
                    let left = cell.hasPrefix(":")
                    let right = cell.hasSuffix(":")
                    if left, right { return .center }
                    if right { return .right }
                    return .left
                }
            }
            if lineRange.length == 0 { break }
            index = lineRange.location + lineRange.length
        }
        return []
    }

    /// 按 `|` 分割表格行：`\|` 是字面竖线，不作为列分隔（同时去掉转义反斜杠）。
    private static func splitTableRow(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var pendingEscape = false
        for character in line {
            if pendingEscape {
                if character == "|" {
                    current.append("|")
                } else {
                    current.append("\\")
                    current.append(character)
                }
                pendingEscape = false
                continue
            }
            if character == "\\" {
                pendingEscape = true
                continue
            }
            if character == "|" {
                cells.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        if pendingEscape { current.append("\\") }
        cells.append(current)
        return cells
    }

    /// 用 `NSTextTable` 构建网格（表头加粗；自动列宽 + 细边框）。
    ///
    /// 每个单元格字符都带 `.markableTableCell = "表序,行,列"`：复制时据此把被拉平成
    /// 「每格一行」的文本重新拼回 TSV（见 `CopyFormatted`）。
    private func makeTable(
        _ rows: [[String]],
        alignments: [NSTextAlignment] = [],
        tableIndex: Int = 0
    ) -> NSAttributedString {
        let columnCount = rows.map(\.count).max() ?? 1
        guard columnCount > 0 else { return NSAttributedString() }

        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false

        // 列宽自适应：先按内容测量自然宽度，再按比例分配到可用宽度（内容多的列更宽）。
        let widths = columnWidths(for: rows, columnCount: columnCount)

        let result = NSMutableAttributedString()
        for (rowIndex, cells) in rows.enumerated() {
            for column in 0..<columnCount {
                let cellText = column < cells.count ? cells[column] : ""
                let block = NSTextTableBlock(
                    table: table,
                    startingRow: rowIndex, rowSpan: 1,
                    startingColumn: column, columnSpan: 1
                )
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setBorderColor(NSColor.separatorColor)
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                block.setContentWidth(widths[column], type: .absoluteValueType)
                if rowIndex == 0 {
                    block.backgroundColor = NSColor.quaternaryLabelColor
                }

                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                if column < alignments.count {
                    style.alignment = alignments[column]
                }
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: rowIndex == 0 ? boldFont : baseFont,
                    .foregroundColor: NSColor.labelColor,
                ]
                let normalizedCell = Self.normalizeCellBreaks(cellText)
                let cell = NSMutableAttributedString(string: normalizedCell + "\n", attributes: attributes)
                applyInlineMarkup(to: cell)
                let cellRange = NSRange(location: 0, length: cell.length)
                cell.addAttribute(.paragraphStyle, value: style, range: cellRange)
                cell.addAttribute(.markableTableCell,
                                  value: "\(tableIndex),\(rowIndex),\(column)", range: cellRange)
                result.append(cell)
            }
        }
        // 表格后留一空行，避免与下文粘连
        result.append(NSAttributedString(string: "\n", attributes: baseAttributes))
        return result
    }

    /// 按内容计算每列宽度：测量每列最长文本，按比例分配容器宽度，并限制最小/最大列宽。
    private func columnWidths(for rows: [[String]], columnCount: Int) -> [CGFloat] {
        let minWidth: CGFloat = 64
        var natural = [CGFloat](repeating: minWidth, count: columnCount)
        for (rowIndex, cells) in rows.enumerated() {
            let font = rowIndex == 0 ? boldFont : baseFont
            for column in 0..<columnCount {
                let text = column < cells.count ? cells[column] : ""
                let plain = Self.plainWidthText(text)
                let width = (plain as NSString).size(withAttributes: [.font: font]).width + 14
                natural[column] = max(natural[column], width)
            }
        }

        let available = max(CGFloat(columnCount) * minWidth, containerWidth - CGFloat(columnCount) * 12)
        let total = natural.reduce(0, +)
        var widths = natural.map { max(minWidth, available * ($0 / max(total, 1))) }
        let totalWidth = widths.reduce(0, +)
        if totalWidth > available {
            let scale = available / totalWidth
            widths = widths.map { max(minWidth, $0 * scale) }
        }
        return widths
    }

    /// 单元格内 `<br>` → 行分隔符；反引号代码段内的 `<br>` 保持字面。
    private static func normalizeCellBreaks(_ text: String) -> String {
        var codeSpans: [String] = []
        var protected = text
        if let regex = try? NSRegularExpression(pattern: #"`[^`]*`"#) {
            let ns = protected as NSString
            let matches = regex.matches(in: protected, range: NSRange(location: 0, length: ns.length))
            for (index, match) in matches.enumerated().reversed() {
                codeSpans.insert(ns.substring(with: match.range), at: 0)
                protected = (protected as NSString).replacingCharacters(in: match.range, with: "\u{FFFC}\(index)\u{FFFC}")
            }
        }
        protected = protected.replacingOccurrences(
            of: #"<br\s*/?>"#,
            with: "\u{2028}",
            options: [.regularExpression, .caseInsensitive]
        )
        for (index, span) in codeSpans.enumerated() {
            protected = protected.replacingOccurrences(of: "\u{FFFC}\(index)\u{FFFC}", with: span)
        }
        return protected
    }

    /// 估算显示宽度前去掉行内标记（粗体/代码/链接语法/HTML 标签）。
    private static func plainWidthText(_ text: String) -> String {
        var result = text
        let patterns = [
            #"\*\*([^*]+)\*\*"#,
            #"`([^`]+)`"#,
            #"\*([^*]+)\*"#,
            #"\[([^\]]+)\]\([^)]+\)"#,
            #"<[^>]+>"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
        }
        return result
    }

    /// 在表格单元格内应用行内语法（粗体/斜体/行内代码/高亮/链接），并隐藏标记。
    private func applyInlineMarkup(to text: NSMutableAttributedString) {
        let plain = text.string
        for item in InlineSyntax.ranges(in: plain) {
            let full = item.range
            let content = item.content
            guard full.location + full.length <= text.length else { continue }

            let headLength = max(0, content.location - full.location)
            if headLength > 0 {
                hideInlineMarkup(text, range: NSRange(location: full.location, length: headLength))
            }
            let tailStart = content.location + content.length
            let tailLength = (full.location + full.length) - tailStart
            if tailLength > 0 {
                hideInlineMarkup(text, range: NSRange(location: tailStart, length: tailLength))
            }

            switch item.kind {
            case .bold:
                text.addAttribute(.font, value: boldFont, range: content)
            case .italic:
                text.addAttribute(.obliqueness, value: 0.2, range: content)
            case .code:
                CodeTypography.applyCodeFont(to: text, range: content, size: baseSize - 1, style: codeStyle)
                text.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: content)
            case .highlight:
                text.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: content)
            case .strikethrough:
                text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: content)
            case .link:
                text.addAttribute(.foregroundColor, value: NSColor.linkColor, range: content)
            default:
                break
            }
        }
    }

    /// 是否表格分隔行（形如 `|---|---|` 或 `:--:|`）。
    func isSeparatorLine(_ line: String) -> Bool {
        guard line.contains("-") else { return false }
        let allowed: Set<Character> = ["-", ":", "|", " "]
        return line.allSatisfy { allowed.contains($0) }
    }
}
