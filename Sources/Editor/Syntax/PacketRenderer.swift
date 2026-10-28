import AppKit

/// 自研 **Mermaid `packet-beta`** 渲染（swift-mermaid 不支持）：解析字段 → 32 位列布局 → 绘制。
///
/// 支持的语法（简化子集）：
/// ```
/// packet-beta
///   0-15: "Source Port"
///   16-31: "Destination Port"
///   +32: "Sequence Number"
/// ```
/// `start-end` 为绝对位区间；`+N` 表示从上一位之后起的 N 位。每行 32 位（可 `packet-beta 16` 指定）。
enum PacketRenderer {
    private struct Field {
        var start: Int
        var end: Int
        var title: String
    }

    private static let padding: CGFloat = 16
    private static let cellWidth: CGFloat = 26
    private static let rowHeight: CGFloat = 44

    static func image(forSource source: String) -> NSImage? {
        // 统一剔除 `%%{init}%%` / `%%` 注释（与主流程 MermaidRenderer.headType 一致）
        let source = MermaidSource.stripped(source)
        var bitsPerRow = 32
        var fields: [Field] = []
        var cursor = 0

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("%%") else { continue }
            if line.hasPrefix("packet-beta") {
                let rest = line.replacingOccurrences(of: "packet-beta", with: "").trimmingCharacters(in: .whitespaces)
                if let value = Int(rest), value > 0 { bitsPerRow = value }
                continue
            }
            if let field = parseField(line, cursor: cursor) {
                fields.append(field)
                cursor = field.end + 1
            }
        }
        guard !fields.isEmpty else { return nil }

        let totalBits = fields.map(\.end).max().map { $0 + 1 } ?? bitsPerRow
        let rows = max(1, Int(ceil(Double(totalBits) / Double(bitsPerRow))))

        let width = padding * 2 + CGFloat(bitsPerRow) * cellWidth
        let height = padding * 2 + CGFloat(rows) * rowHeight + 16

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.textBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        let font = NSFont.systemFont(ofSize: 10)
        let rangeFont = NSFont.systemFont(ofSize: 8)

        for row in 0..<rows {
            let rowTop = height - padding - CGFloat(row) * rowHeight
            let rowBottom = rowTop - rowHeight + 8

            // 位标尺（每 4 位一个刻度）
            for bit in 0..<bitsPerRow {
                let x = padding + CGFloat(bit) * cellWidth
                if bit % 4 == 0 {
                    let label = String(row * bitsPerRow + bit)
                    (label as NSString).draw(
                        at: NSPoint(x: x, y: rowTop + 2),
                        withAttributes: [.font: rangeFont, .foregroundColor: NSColor.tertiaryLabelColor]
                    )
                }
            }

            // 该行内的字段段
            for field in fields {
                let rowStartBit = row * bitsPerRow
                let rowEndBit = rowStartBit + bitsPerRow - 1
                let segStart = max(field.start, rowStartBit)
                let segEnd = min(field.end, rowEndBit)
                guard segStart <= segEnd else { continue }

                let x = padding + CGFloat(segStart - rowStartBit) * cellWidth
                let segWidth = CGFloat(segEnd - segStart + 1) * cellWidth
                let rect = NSRect(x: x, y: rowBottom, width: segWidth, height: rowHeight - 10)

                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
                NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
                path.fill()
                NSColor.separatorColor.setStroke()
                path.lineWidth = 0.75
                path.stroke()

                // 字段名（居中）
                let titleSize = (field.title as NSString).size(withAttributes: [.font: font])
                if titleSize.width <= rect.width - 4 {
                    (field.title as NSString).draw(
                        at: NSPoint(x: rect.midX - titleSize.width / 2, y: rect.midY + 1),
                        withAttributes: [.font: font, .foregroundColor: NSColor.labelColor]
                    )
                }
                // 位区间（左上）
                let range = "\(field.start)-\(field.end)"
                let rangeSize = (range as NSString).size(withAttributes: [.font: rangeFont])
                if rangeSize.width <= rect.width - 4 {
                    (range as NSString).draw(
                        at: NSPoint(x: rect.midX - rangeSize.width / 2, y: rect.minY + 2),
                        withAttributes: [.font: rangeFont, .foregroundColor: NSColor.tertiaryLabelColor]
                    )
                }
            }
        }
        return image
    }

    private static func parseField(_ line: String, cursor: Int) -> Field? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let rangePart = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        var title = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

        if rangePart.hasPrefix("+") {
            guard let length = Int(rangePart.dropFirst()) else { return nil }
            return Field(start: cursor, end: cursor + length - 1, title: title)
        }
        let bounds = rangePart.split(separator: "-")
        if bounds.count == 2, let start = Int(bounds[0]), let end = Int(bounds[1]), start <= end {
            return Field(start: start, end: end, title: title)
        }
        return nil
    }
}
