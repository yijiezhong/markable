import AppKit

/// 自研 **Mermaid `xychart-beta`** 渲染（swift-mermaid 不支持）：解析 → 坐标布局 → 绘制。
///
/// 支持的语法（简化子集）：
/// ```
/// xychart-beta
///   title "月度销量"
///   x-axis [一月, 二月, 三月, 四月]
///   y-axis "销量" 0 --> 100
///   bar [20, 45, 70, 88]
///   line [20, 45, 70, 88]
/// ```
enum XychartRenderer {
    private static let padding: CGFloat = 16
    private static let leftAxis: CGFloat = 48
    private static let chartWidth: CGFloat = 460
    private static let chartHeight: CGFloat = 240

    static func image(forSource source: String) -> NSImage? {
        // 统一剔除 `%%{init}%%` / `%%` 注释（与主流程 MermaidRenderer.headType 一致）
        let source = MermaidSource.stripped(source)
        var title = ""
        var xLabels: [String] = []
        var yLabel = ""
        var yMin: Double? = nil
        var yMax: Double? = nil
        var bars: [Double] = []
        var line: [Double] = []

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = rawLine.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasPrefix("%%") else { continue }
            if text.hasPrefix("xychart") { continue }

            if text.hasPrefix("title") {
                title = unquote(text.replacingOccurrences(of: "title", with: "").trimmingCharacters(in: .whitespaces))
            } else if text.hasPrefix("x-axis") {
                xLabels = bracketList(text)
            } else if text.hasPrefix("y-axis") {
                let rest = text.replacingOccurrences(of: "y-axis", with: "").trimmingCharacters(in: .whitespaces)
                if let rangeStart = rest.firstIndex(of: "\"") {
                    if let endQuote = rest[rest.index(after: rangeStart)...].firstIndex(of: "\"") {
                        yLabel = String(rest[rest.index(after: rangeStart)..<endQuote])
                    }
                }
                // min --> max
                let parts = rest.components(separatedBy: "-->")
                if parts.count == 2 {
                    yMin = Double(lastNumber(in: parts[0]))
                    yMax = Double(lastNumber(in: parts[1]))
                }
            } else if text.hasPrefix("bar") {
                bars = numberList(text)
            } else if text.hasPrefix("line") {
                line = numberList(text)
            }
        }

        let values = bars + line
        guard !values.isEmpty else { return nil }

        let lo = yMin ?? min(0, values.min() ?? 0)
        let hi = yMax ?? ((values.max() ?? 1) * 1.1)
        let span = max(0.0001, hi - lo)

        let titleHeight: CGFloat = title.isEmpty ? 0 : 26
        let width = padding * 2 + leftAxis + chartWidth
        let height = padding * 2 + titleHeight + chartHeight + 28

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

        let originX = padding + leftAxis
        let originY = padding + 22                       // 底部留出 x 轴标签
        let chartTop = originY + chartHeight

        func yPos(_ value: Double) -> CGFloat {
            originY + CGFloat((value - lo) / span) * chartHeight
        }

        // y 轴网格 + 刻度值
        let gridLines = 4
        for k in 0...gridLines {
            let value = lo + span * Double(k) / Double(gridLines)
            let y = yPos(value)
            let grid = NSBezierPath()
            grid.move(to: NSPoint(x: originX, y: y))
            grid.line(to: NSPoint(x: originX + chartWidth, y: y))
            NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
            grid.lineWidth = 0.5
            grid.stroke()

            let label = format(value)
            let size = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9)])
            (label as NSString).draw(
                at: NSPoint(x: originX - 6 - size.width, y: y - size.height / 2),
                withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor]
            )
        }

        // y 轴单位标签（横排在轴顶上方，避免旋转绘制的复杂度）
        if !yLabel.isEmpty {
            (yLabel as NSString).draw(
                at: NSPoint(x: 2, y: chartTop + 4),
                withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
            )
        }

        // 坐标轴
        let axis = NSBezierPath()
        axis.move(to: NSPoint(x: originX, y: originY))
        axis.line(to: NSPoint(x: originX + chartWidth, y: originY))   // x
        axis.move(to: NSPoint(x: originX, y: originY))
        axis.line(to: NSPoint(x: originX, y: chartTop))               // y
        NSColor.separatorColor.setStroke()
        axis.lineWidth = 1
        axis.stroke()

        // 每个数据点的 x 中心
        let count = max(bars.count, line.count)
        func xCenter(_ index: Int) -> CGFloat {
            guard count > 0 else { return originX }
            let step = chartWidth / CGFloat(count)
            return originX + step * (CGFloat(index) + 0.5)
        }

        // 柱状
        let barWidth = count > 0 ? (chartWidth / CGFloat(count)) * 0.6 : 0
        for (index, value) in bars.enumerated() {
            let x = xCenter(index)
            let y0 = yPos(lo)
            let y1 = yPos(value)
            let rect = NSRect(x: x - barWidth / 2, y: min(y0, y1), width: barWidth, height: abs(y1 - y0))
            let path = NSBezierPath(rect: rect)
            NSColor.controlAccentColor.withAlphaComponent(0.65).setFill()
            path.fill()
        }

        // 折线
        if !line.isEmpty {
            let path = NSBezierPath()
            for (index, value) in line.enumerated() {
                let point = NSPoint(x: xCenter(index), y: yPos(value))
                if index == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            NSColor.systemRed.setStroke()
            path.lineWidth = 2
            path.stroke()
            for (index, value) in line.enumerated() {
                let point = NSPoint(x: xCenter(index), y: yPos(value))
                let dot = NSBezierPath(ovalIn: NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
                NSColor.systemRed.setFill()
                dot.fill()
            }
        }

        // x 轴标签
        let labelFont = NSFont.systemFont(ofSize: 9)
        for index in 0..<max(xLabels.count, count) where index < xLabels.count {
            let label = xLabels[index]
            let size = (label as NSString).size(withAttributes: [.font: labelFont])
            (label as NSString).draw(
                at: NSPoint(x: xCenter(index) - size.width / 2, y: originY - 16),
                withAttributes: [.font: labelFont, .foregroundColor: NSColor.secondaryLabelColor]
            )
        }

        return image
    }

    // MARK: - 解析辅助

    private static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\"") && t.hasSuffix("\"") && t.count >= 2 {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }

    private static func bracketList(_ line: String) -> [String] {
        guard let open = line.firstIndex(of: "["), let close = line.lastIndex(of: "]"), open < close else { return [] }
        let inner = line[line.index(after: open)..<close]
        return inner.split(separator: ",").map { unquote(String($0).trimmingCharacters(in: .whitespaces)) }
    }

    private static func numberList(_ line: String) -> [Double] {
        bracketList(line).compactMap { Double($0) }
    }

    private static func lastNumber(in s: String) -> String {
        let tokens = s.split(whereSeparator: { $0 == " " || $0 == "\t" })
        return tokens.last.map(String.init) ?? ""
    }

    private static func format(_ value: Double) -> String {
        if abs(value - value.rounded()) < 0.001 { return String(Int(value.rounded())) }
        return String(format: "%.1f", value)
    }
}
