import AppKit

/// 自研 **Mermaid `quadrantChart`** 渲染（swift-mermaid 不支持）：解析 → 四象限布局 → 绘制。
///
/// 支持的语法（简化子集）：
/// ```
/// quadrantChart
///   title 标题
///   x-axis 低 --> 高
///   y-axis 低 --> 高
///   quadrant-1 右上
///   quadrant-2 左上
///   quadrant-3 左下
///   quadrant-4 右下
///   数据点 A: [0.3, 0.6]
/// ```
/// 取值约定：x 向右增大、y 向上增大，坐标都在 [0, 1]。
enum QuadrantRenderer {
    private struct Point {
        var label: String
        var x: Double
        var y: Double
    }

    private static let padding: CGFloat = 16
    private static let chart: CGFloat = 360
    private static let labelGutter: CGFloat = 12

    static func image(forSource source: String) -> NSImage? {
        // 统一剔除 `%%{init}%%` / `%%` 注释（与主流程 MermaidRenderer.headType 一致）
        let source = MermaidSource.stripped(source)
        var title = ""
        var xLabels: (String, String) = ("", "")
        var yLabels: (String, String) = ("", "")
        var quadrants: [Int: String] = [:]
        var points: [Point] = []

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("%%") else { continue }
            if line.hasPrefix("quadrantChart") { continue }

            if line.hasPrefix("title") {
                title = line.replacingOccurrences(of: "title", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("x-axis") {
                xLabels = axisLabels(line)
            } else if line.hasPrefix("y-axis") {
                yLabels = axisLabels(line)
            } else if line.hasPrefix("quadrant-") {
                let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                if parts.count == 2, let index = Int(parts[0].dropFirst("quadrant-".count)) {
                    quadrants[index] = String(parts[1]).trimmingCharacters(in: .whitespaces)
                }
            } else if let point = parsePoint(line) {
                points.append(point)
            }
        }

        let titleHeight: CGFloat = title.isEmpty ? 0 : 26
        let width = padding * 2 + chart + 120      // 右侧留点标签
        let height = padding * 2 + titleHeight + chart + 40

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.textBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        var top = height - padding
        if !title.isEmpty {
            (title as NSString).draw(
                at: NSPoint(x: padding, y: top - 18),
                withAttributes: [.font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.labelColor]
            )
            top -= titleHeight
        }

        let originX = padding + labelGutter + 20
        let originY = padding + 24
        let rect = NSRect(x: originX, y: originY, width: chart, height: chart)
        let midX = rect.midX
        let midY = rect.midY

        // 象限底色（交替淡色，便于区分）
        NSColor.controlAccentColor.withAlphaComponent(0.05).setFill()
        NSRect(x: midX, y: midY, width: rect.width / 2, height: rect.height / 2).fill()   // 右上
        NSRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height / 2).fill()  // 左下

        // 边框 + 中轴
        let border = NSBezierPath(rect: rect)
        NSColor.separatorColor.setStroke()
        border.lineWidth = 1
        border.stroke()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: midX, y: rect.minY)); cross.line(to: NSPoint(x: midX, y: rect.maxY))
        cross.move(to: NSPoint(x: rect.minX, y: midY)); cross.line(to: NSPoint(x: rect.maxX, y: midY))
        cross.lineWidth = 0.75
        cross.stroke()

        // 象限名称
        let quadFont = NSFont.systemFont(ofSize: 11)
        let quadColor = NSColor.secondaryLabelColor
        func drawQuadrant(_ index: Int, at point: NSPoint, alignRight: Bool, alignTop: Bool) {
            guard let text = quadrants[index], !text.isEmpty else { return }
            let size = (text as NSString).size(withAttributes: [.font: quadFont])
            let x = alignRight ? point.x - size.width - 6 : point.x + 6
            let y = alignTop ? point.y - size.height - 6 : point.y + 6
            (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: quadFont, .foregroundColor: quadColor])
        }
        drawQuadrant(2, at: NSPoint(x: rect.minX, y: rect.maxY), alignRight: false, alignTop: true)   // 左上
        drawQuadrant(1, at: NSPoint(x: rect.maxX, y: rect.maxY), alignRight: true, alignTop: true)    // 右上
        drawQuadrant(3, at: NSPoint(x: rect.minX, y: rect.minY), alignRight: false, alignTop: false)  // 左下
        drawQuadrant(4, at: NSPoint(x: rect.maxX, y: rect.minY), alignRight: true, alignTop: false)   // 右下

        // 轴端标签
        let axisFont = NSFont.systemFont(ofSize: 10)
        if !xLabels.0.isEmpty || !xLabels.1.isEmpty {
            (xLabels.0 as NSString).draw(at: NSPoint(x: rect.minX, y: rect.minY - 16),
                withAttributes: [.font: axisFont, .foregroundColor: quadColor])
            let size = (xLabels.1 as NSString).size(withAttributes: [.font: axisFont])
            (xLabels.1 as NSString).draw(at: NSPoint(x: rect.maxX - size.width, y: rect.minY - 16),
                withAttributes: [.font: axisFont, .foregroundColor: quadColor])
        }
        if !yLabels.0.isEmpty || !yLabels.1.isEmpty {
            (yLabels.1 as NSString).draw(at: NSPoint(x: rect.maxX + 6, y: rect.maxY - 12),
                withAttributes: [.font: axisFont, .foregroundColor: quadColor])
            (yLabels.0 as NSString).draw(at: NSPoint(x: rect.maxX + 6, y: rect.minY),
                withAttributes: [.font: axisFont, .foregroundColor: quadColor])
        }

        // 数据点
        let pointFont = NSFont.systemFont(ofSize: 10)
        for point in points {
            let x = rect.minX + CGFloat(min(max(point.x, 0), 1)) * rect.width
            let y = rect.minY + CGFloat(min(max(point.y, 0), 1)) * rect.height
            let dot = NSBezierPath(ovalIn: NSRect(x: x - 4, y: y - 4, width: 8, height: 8))
            NSColor.controlAccentColor.setFill()
            dot.fill()
            (point.label as NSString).draw(
                at: NSPoint(x: x + 7, y: y - 6),
                withAttributes: [.font: pointFont, .foregroundColor: NSColor.labelColor]
            )
        }

        return image
    }

    // MARK: - 解析辅助

    private static func axisLabels(_ line: String) -> (String, String) {
        let rest = line.replacingOccurrences(of: "x-axis", with: "")
            .replacingOccurrences(of: "y-axis", with: "")
            .trimmingCharacters(in: .whitespaces)
        let parts = rest.components(separatedBy: "-->")
        guard parts.count == 2 else {
            let single = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            return (single, single)
        }
        return (clean(parts[0]), clean(parts[1]))
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private static func parsePoint(_ line: String) -> Point? {
        guard let regex = try? NSRegularExpression(pattern: #"^(.+?):\s*\[\s*([0-9.]+)\s*,\s*([0-9.]+)\s*\]\s*$"#) else { return nil }
        let ns = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let label = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        guard let x = Double(ns.substring(with: match.range(at: 2))),
              let y = Double(ns.substring(with: match.range(at: 3))) else { return nil }
        return Point(label: label, x: x, y: y)
    }
}
