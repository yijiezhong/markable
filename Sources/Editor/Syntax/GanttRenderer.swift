import AppKit

/// 自研 **Mermaid `gantt`** 渲染（swift-mermaid 不支持）：解析 → 布局 → 绘制为 `NSImage`。
///
/// 支持的语法（简化子集）：
/// ```
/// gantt
///   title 标题
///   dateFormat YYYY-MM-DD
///   section 分组
///   任务名 : 状态, id, 开始, 时长      # 状态/id 可省略
///   任务名 : 开始, 时长
///   任务名 : 时长                      # 开始省略 → 紧跟上一个任务结束
/// ```
/// 时长单位：`d`（天）/ `w`（周）/ `h`（小时，按 1/24 天）/ `m`（分钟）；数字默认按天。
enum GanttRenderer {
    private struct Task {
        var name: String
        var start: Double        // 天
        var duration: Double     // 天
        var section: String
    }

    static func image(forSource source: String) -> NSImage? {
        // 统一剔除 `%%{init}%%` / `%%` 注释（与主流程 MermaidRenderer.headType 一致）
        let source = MermaidSource.stripped(source)
        var tasks: [Task] = []
        var title = ""
        var currentSection = ""
        var cursor = 0.0

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line == "gantt" { continue }
            if line.hasPrefix("title") {
                title = line.replacingOccurrences(of: "title", with: "").trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                continue
            }
            if line.hasPrefix("dateFormat") || line.hasPrefix("axisFormat")
                || line.hasPrefix("excludes") || line.hasPrefix("todayMarker")
                || line.hasPrefix("%%") {
                continue
            }
            if line.hasPrefix("section") {
                currentSection = line.replacingOccurrences(of: "section", with: "").trimmingCharacters(in: .whitespaces)
                continue
            }

            // 任务行：`名称 : 字段, 字段, ...`
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let fields = parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

            var start: Double? = nil
            var duration: Double? = nil
            for field in fields {
                if let days = parseDate(field) {
                    start = days
                } else if let d = parseDuration(field) {
                    duration = d
                }
            }
            guard let dur = duration else { continue }
            let begin = start ?? cursor
            cursor = max(cursor, begin + dur)
            tasks.append(Task(name: name, start: begin, duration: dur, section: currentSection))
        }

        guard !tasks.isEmpty else { return nil }
        return draw(tasks: tasks, title: title)
    }

    // MARK: - 解析

    /// 时长：`3d` / `2w` / `5h` / `90m` / 纯数字（天）。
    private static func parseDuration(_ field: String) -> Double? {
        let s = field.lowercased()
        guard let match = s.range(of: #"^([0-9]+(?:\.[0-9]+)?)\s*([dwhm]?)"#, options: .regularExpression) else { return nil }
        let token = String(s[match])
        var number = token
        var unit = ""
        if let last = token.last, "dwhm".contains(last) {
            unit = String(last)
            number = String(token.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard let value = Double(number) else { return nil }
        switch unit {
        case "w": return value * 7
        case "h": return value / 24
        case "m": return value / (24 * 60)
        default: return value
        }
    }

    /// 日期 `YYYY-MM-DD` → 距 1970 的天数。
    private static func parseDate(_ field: String) -> Double? {
        guard field.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: field) else { return nil }
        return date.timeIntervalSince1970 / 86400
    }

    // MARK: - 绘制

    private static func draw(tasks: [Task], title: String) -> NSImage? {
        let labelWidth: CGFloat = 150
        let padding: CGFloat = 14
        let rowHeight: CGFloat = 24
        let sectionHeight: CGFloat = 20
        let titleHeight: CGFloat = title.isEmpty ? 0 : 26

        // 时间范围
        let minStart = tasks.map(\.start).min() ?? 0
        let maxEnd = tasks.map { $0.start + $0.duration }.max() ?? 1
        let span = max(1, maxEnd - minStart)
        let chartWidth: CGFloat = 460
        let width = padding + labelWidth + chartWidth + padding

        // 高度：标题 + 各 section 标题 + 任务行
        var sections: [(String, [Task])] = []
        for task in tasks {
            if let idx = sections.firstIndex(where: { $0.0 == task.section }) {
                sections[idx].1.append(task)
            } else {
                sections.append((task.section, [task]))
            }
        }
        var height = padding * 2 + titleHeight
        for (name, list) in sections { height += (name.isEmpty ? 0 : sectionHeight) + CGFloat(list.count) * rowHeight }
        height = max(height, 80)

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.textBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        // 自上而下布局：用 y 从顶部累加，绘制时翻转
        var y = height - padding

        if !title.isEmpty {
            (title as NSString).draw(
                at: NSPoint(x: padding, y: y - 18),
                withAttributes: [.font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.labelColor]
            )
            y -= titleHeight
        }

        let labelFont = NSFont.systemFont(ofSize: 12)
        let sectionFont = NSFont.boldSystemFont(ofSize: 12)

        for (name, list) in sections {
            if !name.isEmpty {
                (name as NSString).draw(
                    at: NSPoint(x: padding, y: y - 14),
                    withAttributes: [.font: sectionFont, .foregroundColor: NSColor.secondaryLabelColor]
                )
                y -= sectionHeight
            }
            for task in list {
                let rowY = y - rowHeight
                // 任务名
                (task.name as NSString).draw(
                    at: NSPoint(x: padding + 6, y: rowY + 5),
                    withAttributes: [.font: labelFont, .foregroundColor: NSColor.labelColor]
                )
                // 条
                let startX = padding + labelWidth + CGFloat((task.start - minStart) / span) * chartWidth
                let barWidth = max(6, CGFloat(task.duration / span) * chartWidth)
                let bar = NSRect(x: startX, y: rowY + 4, width: barWidth, height: rowHeight - 8)
                let path = NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3)
                NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
                path.fill()
                // 时长
                let durText = task.duration >= 1
                    ? "\(Int(task.duration.rounded()))d"
                    : String(format: "%.1fh", task.duration * 24)
                (durText as NSString).draw(
                    at: NSPoint(x: bar.maxX + 5, y: rowY + 5),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
                )
                y -= rowHeight
            }
        }
        return image
    }
}
