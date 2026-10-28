import AppKit

/// 自研 **Mermaid `timeline`** 渲染（swift-mermaid 不支持）：解析 → 时间线布局 → 绘制。
///
/// 支持的语法（简化子集）：
/// ```
/// timeline
///   title 标题
///   2002 : 事件A
///   2004 : 事件B : 事件C
/// ```
enum TimelineRenderer {
    private static let columnWidth: CGFloat = 170
    private static let padding: CGFloat = 16
    private static let axisY: CGFloat = 90
    private static let boxHeight: CGFloat = 26

    private struct Period {
        var label: String
        var events: [String]
    }

    static func image(forSource source: String) -> NSImage? {
        // 统一剔除 `%%{init}%%` / `%%` 注释（与主流程 MermaidRenderer.headType 一致）
        let source = MermaidSource.stripped(source)
        var title = ""
        var periods: [Period] = []

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line != "timeline", !line.hasPrefix("%%") else { continue }
            if line.hasPrefix("title") {
                title = line.replacingOccurrences(of: "title", with: "").trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                continue
            }
            let parts = line.split(separator: ":", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2 else { continue }
            periods.append(Period(label: parts[0], events: Array(parts.dropFirst()).filter { !$0.isEmpty }))
        }
        guard !periods.isEmpty else { return nil }

        let titleHeight: CGFloat = title.isEmpty ? 0 : 26
        let maxEvents = periods.map { $0.events.count }.max() ?? 1
        let width = padding * 2 + CGFloat(periods.count) * columnWidth
        let height = padding * 2 + titleHeight + axisY + CGFloat(maxEvents) * (boxHeight + 8) + 10

        let image = NSImage(size: NSSize(width: max(width, 200), height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.textBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: max(width, 200), height: height).fill()

        var top = height - padding
        if !title.isEmpty {
            (title as NSString).draw(
                at: NSPoint(x: padding, y: top - 18),
                withAttributes: [.font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.labelColor]
            )
            top -= titleHeight
        }

        let axisYPos = top - axisY
        // 轴线
        let axis = NSBezierPath()
        axis.move(to: NSPoint(x: padding, y: axisYPos))
        axis.line(to: NSPoint(x: padding + CGFloat(periods.count) * columnWidth - 40, y: axisYPos))
        NSColor.separatorColor.setStroke()
        axis.lineWidth = 1.5
        axis.stroke()

        let periodFont = NSFont.boldSystemFont(ofSize: 12)
        let eventFont = NSFont.systemFont(ofSize: 11)

        for (index, period) in periods.enumerated() {
            let centerX = padding + CGFloat(index) * columnWidth + columnWidth / 2 - 20

            // 时间点刻度
            let dot = NSBezierPath(ovalIn: NSRect(x: centerX - 4, y: axisYPos - 4, width: 8, height: 8))
            NSColor.controlAccentColor.setFill()
            dot.fill()

            // 期标签（轴上方）
            let labelSize = (period.label as NSString).size(withAttributes: [.font: periodFont])
            (period.label as NSString).draw(
                at: NSPoint(x: centerX - labelSize.width / 2, y: axisYPos + 10),
                withAttributes: [.font: periodFont, .foregroundColor: NSColor.labelColor]
            )

            // 事件（轴下方，自上而下）
            var y = axisYPos - 34
            for event in period.events {
                let rect = NSRect(x: centerX - columnWidth / 2 + 20, y: y, width: columnWidth - 50, height: boxHeight)
                let box = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
                NSColor.quaternaryLabelColor.setFill()
                box.fill()
                NSColor.separatorColor.setStroke()
                box.lineWidth = 0.5
                box.stroke()

                let size = (event as NSString).size(withAttributes: [.font: eventFont])
                (event as NSString).draw(
                    at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                    withAttributes: [.font: eventFont, .foregroundColor: NSColor.labelColor]
                )
                y -= (boxHeight + 8)
            }
        }
        return image
    }
}
