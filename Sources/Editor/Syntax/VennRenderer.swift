import AppKit

/// 自研 **Mermaid `venn` / `venn-beta`** 渲染（swift-mermaid 不支持）：集合 → 半径与圆心 → 交叠圆。
///
/// 支持的语法（简化子集）：
/// ```
/// venn-beta
///   title 技能分布
///   "前端": 12
///   "后端": 20
///   "数据": 8
///   "前端&后端": 5
/// ```
/// - 首行 `venn` / `venn-beta`；可选 `title 文本`。
/// - 每个集合一行 `"标签": 数值`，也接受 `标签: 数值` 与整行引号包裹的 `"标签: 数值"`。
/// - `A&B`、`A&B&C` 表示交集，数值画在对应交叠区；成员必须都在集合里，否则忽略该行。
/// - 半径按 `sqrt(数值)` 归一化到 [0.58, 1] × 基准半径；集合数量必须为 2–3，
///   解析不出足够集合时返回 nil（调用方回退源码并提示）。
enum VennRenderer {
    private struct Entry {
        var name: String
        var value: Double
        var members: [String] = []
    }

    private struct Circle {
        var center: NSPoint
        var radius: CGFloat
    }

    private static let padding: CGFloat = 36
    private static let titleHeight: CGFloat = 28
    private static let maxCanvasWidth: CGFloat = 640
    private static let maxCanvasHeight: CGFloat = 420
    private static let minCanvasWidth: CGFloat = 400
    private static let minCanvasHeight: CGFloat = 260
    private static let maxRadius: CGFloat = 130

    private static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let nameFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let valueFont = NSFont.systemFont(ofSize: 11)
    private static let intersectionFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

    /// 克制的蓝 / 青 / 灰紫三色，交叠区靠透明度自然加深。
    private static let palette: [NSColor] = [
        NSColor(srgbRed: 0.26, green: 0.48, blue: 0.72, alpha: 1),
        NSColor(srgbRed: 0.24, green: 0.60, blue: 0.62, alpha: 1),
        NSColor(srgbRed: 0.48, green: 0.45, blue: 0.68, alpha: 1),
    ]

    static func image(forSource source: String) -> NSImage? {
        guard let parsed = parse(MermaidSource.stripped(source)) else { return nil }
        let (title, sets, intersections) = parsed

        // 半径随数值（按平方根）缩放，避免大数值把整幅图撑爆。
        let maxValue = max(1e-9, sets.map(\.value).max() ?? 1)
        let radii = sets.map { entry -> CGFloat in
            let ratio = CGFloat(sqrt(max(0, entry.value) / maxValue))
            return maxRadius * (0.58 + 0.42 * ratio)
        }

        // 相对坐标下的圆心：两集合水平排列，三集合构成等边三角形，重心都在原点。
        var relativeCenters: [NSPoint] = []
        if sets.count == 2 {
            let distance = (radii[0] + radii[1]) * 0.62
            relativeCenters = [
                NSPoint(x: -distance / 2, y: 0),
                NSPoint(x: distance / 2, y: 0),
            ]
        } else {
            // 圆心距取「两两半径和最小值」的 0.60：重心到各圆心约 0.69r，
            // 三圆公共交集才有可见面积（若取 0.92，重心会落到圆外）。
            let distance = pairDistance(radii) * 0.60
            let height = distance / CGFloat(3.0).squareRoot()
            relativeCenters = [
                NSPoint(x: 0, y: height),
                NSPoint(x: -distance / 2, y: -height / 2),
                NSPoint(x: distance / 2, y: -height / 2),
            ]
        }

        // 包围盒 → 等比缩放，保证画布宽度不超过上限。
        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for (index, center) in relativeCenters.enumerated() {
            minX = min(minX, center.x - radii[index])
            maxX = max(maxX, center.x + radii[index])
            minY = min(minY, center.y - radii[index])
            maxY = max(maxY, center.y + radii[index])
        }
        let bboxWidth = max(1, maxX - minX)
        let bboxHeight = max(1, maxY - minY)
        let footer: CGFloat = title.isEmpty ? 0 : titleHeight
        let availableWidth = maxCanvasWidth - padding * 2
        let availableHeight = max(1, maxCanvasHeight - padding * 2 - footer)
        let scale = min(1, min(availableWidth / bboxWidth, availableHeight / bboxHeight))

        let contentWidth = bboxWidth * scale
        let contentHeight = bboxHeight * scale
        let width = max(minCanvasWidth, contentWidth + padding * 2)
        let height = max(minCanvasHeight, contentHeight + padding * 2 + footer)
        let offsetX = (width - contentWidth) / 2 - minX * scale
        let offsetY = (height - footer - contentHeight) / 2 - minY * scale

        let circles = relativeCenters.enumerated().map { index, center in
            Circle(center: NSPoint(x: center.x * scale + offsetX, y: center.y * scale + offsetY),
                   radius: radii[index] * scale)
        }
        let origin = NSPoint(x: offsetX, y: offsetY)

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.textBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        // 圆：半透明填充 + 同色描边，叠加处自然变深。
        for (index, circle) in circles.enumerated() {
            let color = palette[index % palette.count]
            let rect = NSRect(x: circle.center.x - circle.radius, y: circle.center.y - circle.radius,
                              width: circle.radius * 2, height: circle.radius * 2)
            let path = NSBezierPath(ovalIn: rect)
            color.withAlphaComponent(0.24).setFill()
            path.fill()
            color.withAlphaComponent(0.85).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }

        if !title.isEmpty {
            drawCentered(title, font: titleFont, color: NSColor.labelColor,
                         centerX: width / 2, bottom: height - footer + 8,
                         maxWidth: width - padding * 2)
        }

        // 集合名 + 数值：放在各自独占区（从重心指向圆心的方向外推半个半径）。
        for (index, entry) in sets.enumerated() {
            let circle = circles[index]
            let relative = relativeCenters[index]
            let length = (relative.x * relative.x + relative.y * relative.y).squareRoot()
            let unitX = length > 0.001 ? relative.x / length : 0
            let unitY = length > 0.001 ? relative.y / length : 1
            let point = NSPoint(x: circle.center.x + unitX * circle.radius * 0.5,
                                y: circle.center.y + unitY * circle.radius * 0.5)
            drawSetLabel(entry, at: point, radius: circle.radius)
        }

        // 交集数值：两两交集画在交叠区，三交集落在重心。
        for entry in intersections {
            guard let point = intersectionPoint(for: entry, sets: sets, circles: circles, origin: origin)
            else { continue }
            let minRadius = entry.members.compactMap { name in
                sets.firstIndex(where: { $0.name == name }).map { circles[$0].radius }
            }.min() ?? 60
            drawCentered(format(entry.value), font: intersectionFont, color: NSColor.labelColor,
                         centerX: point.x, bottom: point.y - 6,
                         maxWidth: max(28, minRadius * 1.1))
        }

        return image
    }

    // MARK: - 解析

    private static func parse(_ source: String) -> (title: String, sets: [Entry], intersections: [Entry])? {
        var title = ""
        var sets: [Entry] = []
        var intersections: [Entry] = []
        var seen = Set<String>()

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("%%") else { continue }
            let lower = line.lowercased()
            if lower == "venn" || lower == "venn-beta" { continue }
            if lower.hasPrefix("title ") {
                title = String(line.dropFirst("title ".count)).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let (name, value) = parseEntry(line) else { continue }
            let members = name.split(separator: "&").map { $0.trimmingCharacters(in: .whitespaces) }
            if members.count == 1 {
                guard seen.insert(name).inserted else { continue }
                sets.append(Entry(name: name, value: value))
            } else if (2...3).contains(members.count) {
                intersections.append(Entry(name: name, value: value, members: members))
            }
        }

        guard (2...3).contains(sets.count) else { return nil }
        let names = Set(sets.map(\.name))
        let valid = intersections.filter { entry in
            entry.members.count <= sets.count && entry.members.allSatisfy { names.contains($0) }
        }
        return (title, sets, valid)
    }

    /// 解析 `"标签": 数值` / `标签: 数值` / `"标签: 数值"`；数值必须有限且非负。
    private static func parseEntry(_ line: String) -> (name: String, value: Double)? {
        var candidates = [line]
        if line.count > 2, line.hasPrefix("\""), line.hasSuffix("\"") {
            candidates.append(String(line.dropFirst().dropLast()))
        }
        for candidate in candidates {
            guard let colon = candidate.range(of: ":", options: .backwards) else { continue }
            let name = unquote(String(candidate[..<colon.lowerBound]))
            let valueText = unquote(String(candidate[colon.upperBound...]))
            guard !name.isEmpty, let value = Double(valueText), value.isFinite, value >= 0 else { continue }
            return (name, value)
        }
        return nil
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

    // MARK: - 几何

    /// 三集合时取两两半径和的最小值，保证三条边都真正交叠。
    private static func pairDistance(_ radii: [CGFloat]) -> CGFloat {
        guard radii.count >= 3 else {
            return radii.count == 2 ? radii[0] + radii[1] : maxRadius * 2
        }
        return min(radii[0] + radii[1], min(radii[1] + radii[2], radii[0] + radii[2]))
    }

    private static func intersectionPoint(for entry: Entry, sets: [Entry],
                                          circles: [Circle], origin: NSPoint) -> NSPoint? {
        var indices: [Int] = []
        for member in entry.members {
            guard let index = sets.firstIndex(where: { $0.name == member }) else { return nil }
            indices.append(index)
        }
        guard indices.count >= 2 else { return nil }
        if indices.count >= 3 { return origin }

        // 两两交集：先取两圆心中点，再沿「远离重心」方向推出一点点，避开集合标签。
        let first = circles[indices[0]].center
        let second = circles[indices[1]].center
        let mid = NSPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
        let dx = mid.x - origin.x
        let dy = mid.y - origin.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.5 else { return mid }
        let offset = min(circles[indices[0]].radius, circles[indices[1]].radius) * 0.14
        return NSPoint(x: mid.x + dx / length * offset, y: mid.y + dy / length * offset)
    }

    // MARK: - 绘制

    private static func drawSetLabel(_ entry: Entry, at point: NSPoint, radius: CGFloat) {
        let maxWidth = max(48, radius * 1.5)
        drawCentered(entry.name, font: nameFont, color: NSColor.labelColor,
                     centerX: point.x, bottom: point.y + 2, maxWidth: maxWidth)
        drawCentered(format(entry.value), font: valueFont, color: NSColor.secondaryLabelColor,
                     centerX: point.x, bottom: point.y - 15, maxWidth: maxWidth)
    }

    /// 以 `centerX` 水平居中、`bottom` 为底边绘制单行文本（超宽截断）。
    private static func drawCentered(_ text: String, font: NSFont, color: NSColor,
                                     centerX: CGFloat, bottom: CGFloat, maxWidth: CGFloat) {
        let line = fitted(text, font: font, maxWidth: maxWidth)
        guard !line.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (line as NSString).size(withAttributes: attributes)
        (line as NSString).draw(at: NSPoint(x: centerX - size.width / 2, y: bottom),
                                withAttributes: attributes)
    }

    private static func format(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value.rounded())) }
        return String(format: "%.1f", value)
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
