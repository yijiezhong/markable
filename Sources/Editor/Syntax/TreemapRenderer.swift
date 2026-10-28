import AppKit

/// 自研 **Mermaid `treemap` / `treemap-beta`** 渲染（swift-mermaid 不支持）：
/// 缩进层级 → 权重树 → squarify 面积分配 → 嵌套矩形 + 标签。
///
/// 支持的语法（简化子集）：
/// ```
/// treemap
///   title 季度投入
///   "研发"
///     "解析器": 30
///     "渲染器": 18
///   "文档"
///     "教程": 12
/// ```
/// - 首行 `treemap` / `treemap-beta`；可选 `title 文本`。
/// - 缩进（空格/tab）表示层级；形如 `名称: 数值` 的行是带权重的叶子，只有名称的行是分组。
/// - 名称可用双引号包裹（可含空格，但分隔数值的冒号必须是半角 `:`）。
/// - 面积与权重成正比，权重取该节点下全部叶子数值之和；嵌套矩形用同一色系深浅区分层级。
/// - 没有可用正数值时返回 nil（调用方回退源码并提示）。
enum TreemapRenderer {
    /// top-down 布局框（`top` 为距容器顶部的距离，便于 squarify 直接计算）。
    private struct Box {
        var x: CGFloat
        var top: CGFloat
        var width: CGFloat
        var height: CGFloat
    }

    private final class Node {
        var name: String
        var value: Double?
        var children: [Node] = []
        var weight: Double = 0
        var depth: Int = 0
        /// 顶层分支索引，用于整幅图取色。
        var branch: Int = 0
        var box = Box(x: 0, top: 0, width: 0, height: 0)

        init(name: String, value: Double?) {
            self.name = name
            self.value = value
        }
    }

    private static let padding: CGFloat = 16
    private static let canvasWidth: CGFloat = 720
    private static let canvasHeight: CGFloat = 460
    /// 分组节点为标题预留的头部高度（小于此尺寸时不画标题，把空间留给子项）。
    private static let groupHeaderHeight: CGFloat = 16

    private static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let groupFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let leafFont = NSFont.systemFont(ofSize: 10)
    private static let valueFont = NSFont.systemFont(ofSize: 9)

    /// 克制的灰蓝色板（父子同色系、以透明度区分层级）。
    private static let palette: [NSColor] = [
        NSColor(srgbRed: 0.29, green: 0.47, blue: 0.68, alpha: 1),
        NSColor(srgbRed: 0.36, green: 0.58, blue: 0.62, alpha: 1),
        NSColor(srgbRed: 0.45, green: 0.52, blue: 0.62, alpha: 1),
        NSColor(srgbRed: 0.54, green: 0.48, blue: 0.60, alpha: 1),
        NSColor(srgbRed: 0.56, green: 0.54, blue: 0.50, alpha: 1),
    ]

    static func image(forSource source: String) -> NSImage? {
        guard let parsed = parse(MermaidSource.stripped(source)) else { return nil }
        let (title, root) = parsed

        computeWeight(root)
        guard prune(root) else { return nil }
        computeWeight(root)

        // 只有一个顶层分组时把它提升为根，避免整幅图只剩一圈外框。
        let top = root.children.count == 1 ? root.children[0] : root
        let heading = title.isEmpty ? top.name : title

        let headerHeight: CGFloat = heading.isEmpty ? 0 : 26
        let width = canvasWidth
        let height = canvasHeight + headerHeight
        let content = Box(x: padding, top: padding + headerHeight,
                          width: width - padding * 2,
                          height: height - padding * 2 - headerHeight)
        place(top.children.isEmpty ? [top] : top.children, in: content, depth: 0, parentBranch: 0)

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.textBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        if !heading.isEmpty {
            (heading as NSString).draw(
                at: NSPoint(x: padding, y: height - padding - 18),
                withAttributes: [.font: titleFont, .foregroundColor: NSColor.labelColor]
            )
        }
        if top.children.isEmpty {
            draw(top, totalHeight: height)
        } else {
            for child in top.children { draw(child, totalHeight: height) }
        }
        return image
    }

    // MARK: - 解析

    private static func parse(_ source: String) -> (title: String, root: Node)? {
        var title = ""
        let root = Node(name: "", value: nil)
        var stack: [(indent: Int, node: Node)] = [(-1, root)]
        var sawNode = false

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("%%") else { continue }
            let lower = trimmed.lowercased()
            if lower == "treemap" || lower == "treemap-beta" { continue }
            if lower.hasPrefix("title ") {
                title = String(trimmed.dropFirst("title ".count)).trimmingCharacters(in: .whitespaces)
                continue
            }

            let indent = leadingIndent(of: line)
            let (name, value) = splitEntry(trimmed)
            guard !name.isEmpty else { continue }
            let node = Node(name: name, value: value)
            while let last = stack.last, last.indent >= indent, stack.count > 1 {
                stack.removeLast()
            }
            stack.last?.node.children.append(node)
            stack.append((indent, node))
            sawNode = true
        }
        return sawNode ? (title, root) : nil
    }

    /// 拆出 `名称: 数值`；没有合法数值时返回只有名称的分组节点。
    private static func splitEntry(_ text: String) -> (name: String, value: Double?) {
        var body = text
        // 整行被引号包裹（`"A: 30"`）时先去掉外层引号。
        if body.count > 2, body.hasPrefix("\""), body.hasSuffix("\"") {
            body = String(body.dropFirst().dropLast())
        }
        if let colon = body.range(of: ":", options: .backwards) {
            let name = unquote(String(body[..<colon.lowerBound]))
            let valueText = String(body[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let value = Double(valueText), value.isFinite, value > 0 {
                return (name, value)
            }
        }
        return (unquote(body), nil)
    }

    private static func unquote(_ text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespaces)
        if body.count >= 2, body.hasPrefix("\""), body.hasSuffix("\"") {
            body = String(body.dropFirst().dropLast())
        }
        return body.trimmingCharacters(in: .whitespaces)
    }

    /// 行首缩进：空格记 1，tab 记 4。
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

    // MARK: - 权重与剪枝

    @discardableResult
    private static func computeWeight(_ node: Node) -> Double {
        if node.children.isEmpty {
            node.weight = max(0, node.value ?? 0)
        } else {
            node.weight = node.children.reduce(0) { $0 + computeWeight($1) }
        }
        return node.weight
    }

    /// 丢掉没有正权重的子树；返回该节点是否仍保留。
    private static func prune(_ node: Node) -> Bool {
        if node.children.isEmpty {
            return (node.value ?? 0) > 0
        }
        node.children = node.children.filter { prune($0) }
        if node.children.isEmpty {
            return (node.value ?? 0) > 0
        }
        return true
    }

    // MARK: - 布局（squarify）

    private static func place(_ nodes: [Node], in box: Box, depth: Int, parentBranch: Int) {
        guard !nodes.isEmpty else { return }
        squarify(nodes, in: box)
        for (index, node) in nodes.enumerated() {
            node.depth = depth
            node.branch = depth == 0 ? index : parentBranch
            guard !node.children.isEmpty else { continue }
            let header: CGFloat = (node.box.height >= 40 && node.box.width >= 72) ? groupHeaderHeight : 0
            let inner = Box(x: node.box.x, top: node.box.top + header,
                            width: node.box.width, height: node.box.height - header)
            place(node.children, in: inner, depth: depth + 1, parentBranch: node.branch)
        }
    }

    /// 经典 squarify：按权重把矩形切成尽量接近正方形的块。
    private static func squarify(_ nodes: [Node], in rect: Box) {
        var remaining = nodes
        var free = rect

        while !remaining.isEmpty {
            let remainingWeight = remaining.reduce(0) { $0 + $1.weight }
            guard remainingWeight > 0, free.width > 0.5, free.height > 0.5 else { return }
            let scale = Double(free.width) * Double(free.height) / remainingWeight
            let side = Double(min(free.width, free.height))

            var row = [remaining.removeFirst()]
            while !remaining.isEmpty {
                let candidate = remaining[0].weight * scale
                let current = worstRatio(row.map { $0.weight * scale }, side: side)
                let next = worstRatio(row.map { $0.weight * scale } + [candidate], side: side)
                if next <= current {
                    row.append(remaining.removeFirst())
                } else {
                    break
                }
            }

            let rowArea = row.reduce(0) { $0 + $1.weight } * scale
            if free.width <= free.height {
                // 短边是宽度：整行沿宽度排布，向高度方向吃掉一层。
                let thickness = max(0.001, CGFloat(rowArea) / free.width)
                var x = free.x
                for node in row {
                    let width = CGFloat(node.weight * scale) / thickness
                    node.box = Box(x: x, top: free.top, width: width, height: thickness)
                    x += width
                }
                free.top += thickness
                free.height -= thickness
            } else {
                // 短边是高度：整行沿高度排布，向宽度方向吃掉一层。
                let thickness = max(0.001, CGFloat(rowArea) / free.height)
                var top = free.top
                for node in row {
                    let height = CGFloat(node.weight * scale) / thickness
                    node.box = Box(x: free.x, top: top, width: thickness, height: height)
                    top += height
                }
                free.x += thickness
                free.width -= thickness
            }
        }
    }

    /// 每一块与正方形的偏离程度（越大越瘦长）。
    private static func worstRatio(_ areas: [Double], side: Double) -> Double {
        let sum = areas.reduce(0, +)
        guard sum > 0, side > 0 else { return .infinity }
        let sideSquared = side * side
        var worst = 0.0
        for area in areas where area > 0 {
            worst = max(worst, max(sideSquared * area / (sum * sum), (sum * sum) / (sideSquared * area)))
        }
        return worst
    }

    // MARK: - 绘制

    private static func draw(_ node: Node, totalHeight: CGFloat) {
        let rect = NSRect(x: node.box.x,
                          y: totalHeight - node.box.top - node.box.height,
                          width: node.box.width,
                          height: node.box.height)
        guard rect.width >= 1, rect.height >= 1 else { return }

        let isLeaf = node.children.isEmpty
        let color = palette[node.branch % palette.count]
        let fillAlpha: CGFloat = isLeaf ? 0.45 : 0.20

        let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        color.withAlphaComponent(fillAlpha).setFill()
        path.fill()
        NSColor.textBackgroundColor.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 1
        path.stroke()

        drawLabel(node, in: rect, isLeaf: isLeaf)

        for child in node.children {
            draw(child, totalHeight: totalHeight)
        }
    }

    private static func drawLabel(_ node: Node, in rect: NSRect, isLeaf: Bool) {
        // 小矩形省略标签，避免文字溢出。
        guard rect.width >= 44, rect.height >= 18 else { return }

        if isLeaf {
            let value = format(node.value ?? node.weight)
            if rect.height >= 34, rect.width >= 64 {
                let name = fitted(node.name, font: leafFont, maxWidth: rect.width - 8)
                let nameSize = (name as NSString).size(withAttributes: [.font: leafFont])
                (name as NSString).draw(
                    at: NSPoint(x: rect.midX - nameSize.width / 2, y: rect.midY + 1),
                    withAttributes: [.font: leafFont, .foregroundColor: NSColor.labelColor]
                )
                let valueSize = (value as NSString).size(withAttributes: [.font: valueFont])
                (value as NSString).draw(
                    at: NSPoint(x: rect.midX - valueSize.width / 2, y: rect.midY - 1 - valueSize.height),
                    withAttributes: [.font: valueFont, .foregroundColor: NSColor.secondaryLabelColor]
                )
            } else {
                let line = fitted("\(node.name) \(value)", font: leafFont, maxWidth: rect.width - 8)
                let size = (line as NSString).size(withAttributes: [.font: leafFont])
                (line as NSString).draw(
                    at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                    withAttributes: [.font: leafFont, .foregroundColor: NSColor.labelColor]
                )
            }
        } else {
            guard rect.height >= 22 else { return }
            let name = fitted(node.name, font: groupFont, maxWidth: rect.width - 10)
            let size = (name as NSString).size(withAttributes: [.font: groupFont])
            (name as NSString).draw(
                at: NSPoint(x: rect.minX + 5, y: rect.maxY - size.height - 3),
                withAttributes: [.font: groupFont, .foregroundColor: NSColor.labelColor]
            )
        }
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
