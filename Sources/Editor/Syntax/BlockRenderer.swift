import AppKit

/// 自研 **Mermaid `block-beta`** 渲染（swift-mermaid 不支持）：分块网格 + 连线。
///
/// 支持的语法（简化子集）：
/// ```
/// block-beta
///   columns 3
///   A["前端"] B["后端"] C["数据库"]
///   A --> B
///   B --> C
/// ```
enum BlockRenderer {
    private struct Block {
        var id: String
        var label: String
        var column: Int
        var row: Int
        var span: Int
    }
    private struct Arrow {
        var from: String
        var to: String
        var label: String?
    }

    private static let padding: CGFloat = 16
    private static let cellWidth: CGFloat = 150
    private static let cellHeight: CGFloat = 56
    private static let gap: CGFloat = 12

    static func image(forSource source: String) -> NSImage? {
        // 统一剔除 `%%{init}%%` / `%%` 注释（与主流程 MermaidRenderer.headType 一致）
        let source = MermaidSource.stripped(source)
        var columns = 0
        var blocks: [Block] = []
        var arrows: [Arrow] = []
        var row = 0
        var column = 0

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("%%"), !line.hasPrefix("block") else { continue }

            if line.hasPrefix("columns") {
                columns = Int(line.replacingOccurrences(of: "columns", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
                continue
            }
            // 箭头行
            if line.contains("-->") {
                let parts = line.components(separatedBy: "-->")
                if parts.count == 2 {
                    let from = trimmedID(parts[0])
                    let toPart = parts[1].trimmingCharacters(in: .whitespaces)
                    var to = toPart
                    var label: String? = nil
                    if toPart.hasPrefix("|"), let end = toPart.dropFirst().firstIndex(of: "|") {
                        label = String(toPart[toPart.index(after: toPart.startIndex)..<end]).trimmingCharacters(in: .whitespaces)
                        to = String(toPart[toPart.index(after: end)...]).trimmingCharacters(in: .whitespaces)
                    }
                    let toID = trimmedID(to)
                    if !from.isEmpty, !toID.isEmpty { arrows.append(Arrow(from: from, to: toID, label: label)) }
                }
                continue
            }

            // 块行
            for token in splitTopLevel(line) {
                if token == "space" {
                    column += 1
                    if columns > 0, column >= columns { column = 0; row += 1 }
                    continue
                }
                guard let block = parseBlock(token, column: column, row: row) else { continue }
                blocks.append(block)
                column += max(1, block.span)
                if columns > 0, column >= columns { column = 0; row += 1 }
            }
        }
        guard !blocks.isEmpty else { return nil }

        if columns == 0 { columns = max(1, blocks.map { $0.column + $0.span }.max() ?? 1) }
        let rowCount = (blocks.map(\.row).max() ?? 0) + 1

        let width = padding * 2 + CGFloat(columns) * cellWidth + CGFloat(max(0, columns - 1)) * gap
        let height = padding * 2 + CGFloat(rowCount) * cellHeight + CGFloat(max(0, rowCount - 1)) * gap

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.textBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        func rect(of block: Block) -> NSRect {
            let x = padding + CGFloat(block.column) * (cellWidth + gap)
            let y = height - padding - CGFloat(block.row + 1) * cellHeight - CGFloat(block.row) * gap
            let w = CGFloat(block.span) * cellWidth + CGFloat(block.span - 1) * gap
            return NSRect(x: x, y: y, width: w, height: cellHeight)
        }
        var frames: [String: NSRect] = [:]
        for block in blocks { frames[block.id] = rect(of: block) }

        // 连线（先画，置于块下）
        let labelFont = NSFont.systemFont(ofSize: 9)
        for arrow in arrows {
            guard let a = frames[arrow.from], let b = frames[arrow.to] else { continue }
            let start = NSPoint(x: a.midX, y: a.midY)
            let end = NSPoint(x: b.midX, y: b.midY)
            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: end)
            NSColor.tertiaryLabelColor.setStroke()
            path.lineWidth = 1.2
            path.stroke()

            // 箭头
            let angle = atan2(end.y - start.y, end.x - start.x)
            let size: CGFloat = 7
            let head = NSBezierPath()
            head.move(to: end)
            head.line(to: NSPoint(x: end.x - size * cos(angle - .pi / 7), y: end.y - size * sin(angle - .pi / 7)))
            head.line(to: NSPoint(x: end.x - size * cos(angle + .pi / 7), y: end.y - size * sin(angle + .pi / 7)))
            head.close()
            NSColor.tertiaryLabelColor.setFill()
            head.fill()

            if let label = arrow.label, !label.isEmpty {
                (label as NSString).draw(
                    at: NSPoint(x: (start.x + end.x) / 2 + 4, y: (start.y + end.y) / 2 + 2),
                    withAttributes: [.font: labelFont, .foregroundColor: NSColor.secondaryLabelColor]
                )
            }
        }

        // 块与文字
        let font = NSFont.systemFont(ofSize: 12)
        for block in blocks {
            let frame = rect(of: block)
            let path = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.65).setStroke()
            path.lineWidth = 1
            path.stroke()

            let size = (block.label as NSString).size(withAttributes: [.font: font])
            (block.label as NSString).draw(
                at: NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2),
                withAttributes: [.font: font, .foregroundColor: NSColor.labelColor]
            )
        }
        return image
    }

    // MARK: - 解析辅助

    private static func parseBlock(_ token: String, column: Int, row: Int) -> Block? {
        guard let regex = try? NSRegularExpression(pattern: #"^([A-Za-z0-9_.\-]+)(?:\["([^"]*)"\]|\(([^)]*)\)|\{([^}]*)\})?(?::(\d+))?$"#) else { return nil }
        let ns = token as NSString
        guard let match = regex.firstMatch(in: token, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let id = ns.substring(with: match.range(at: 1))
        var label = id
        for group in 2...4 where match.range(at: group).location != NSNotFound {
            label = ns.substring(with: match.range(at: group))
            break
        }
        var span = 1
        if match.range(at: 5).location != NSNotFound, let value = Int(ns.substring(with: match.range(at: 5))) {
            span = max(1, value)
        }
        return Block(id: id, label: label, column: column, row: row, span: span)
    }

    private static func trimmedID(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let shape = trimmed.firstIndex(where: { $0 == "[" || $0 == "(" || $0 == "{" }) {
            return String(trimmed[..<shape]).trimmingCharacters(in: .whitespaces)
        }
        if let space = trimmed.firstIndex(of: " ") { return String(trimmed[..<space]) }
        return trimmed
    }

    /// 按顶层空白切分（忽略 `["…"]` / `("…")` 内的空格）。
    private static func splitTopLevel(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var depth = 0
        for char in line {
            switch char {
            case "[", "(", "{": depth += 1; current.append(char)
            case "]", ")", "}": depth = max(0, depth - 1); current.append(char)
            case " " where depth == 0, "\t" where depth == 0:
                if !current.isEmpty { tokens.append(current); current = "" }
            default: current.append(char)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
