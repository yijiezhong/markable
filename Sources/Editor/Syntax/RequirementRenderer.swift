import AppKit

/// 自研 **Mermaid `requirement` / `requirementDiagram`** 渲染（swift-mermaid 不支持）：
/// 需求声明 → 网格布局的需求框（名称 + 关键属性）+ 带动词标签的关系箭头。
///
/// 支持的语法（简化子集）：
/// ```
/// requirementDiagram
///
/// requirement 登录 {
///   id: 1
///   text: 支持用户名密码登录
///   risk: high
///   verifymethod: test
/// }
///
/// requirement 审计 {
///   id: 2
///   text: 记录全部登录事件
/// }
///
/// 登录 - satisfies -> 审计
/// ```
/// - 首行 `requirement` 或 `requirementDiagram`。
/// - 节点声明 `requirement 名称 { ... }`（多行块）或简化成 `requirement 名称`（无属性）；
///   也接受 `element 名称 { type: ... }`，用虚线框与需求框区分。
/// - 块内属性按 `键: 值` 解析，只显示 `id` / `text` / `risk` / `verifymethod`（`element` 用 `type`），
///   其余键忽略；单行块 `requirement a { id: 1, text: b }` 也支持（`text` 里的逗号不会被切碎）。
/// - 关系 `A - 动词 -> B`，动词限 satisfies / derives / refines / traces / copies / verifies / contains；
///   关系端点若未声明会自动补成无属性的需求节点。
/// - 节点数必须为 2–8；不足、超出或没有任何节点时返回 nil（调用方回退源码并提示）。
enum RequirementRenderer {
    /// 一个节点是「需求」还是「元素」（元素用虚线框，属性键为 type）。
    private enum NodeKind {
        case requirement
        case element
    }

    private struct Node {
        var name: String
        var kind: NodeKind
        /// 属性按首次写入顺序保存，同名键以后写为准。
        var attributes: [(key: String, value: String)] = []
    }

    private struct Relation {
        var from: String
        var to: String
        var verb: String
    }

    /// 关系动词白名单（Mermaid requirementDiagram 的七种关系）。
    private static let verbs: Set<String> = [
        "satisfies", "derives", "refines", "traces", "copies", "verifies", "contains",
    ]

    /// 允许识别并显示在框内的属性键，顺序即显示顺序。
    private static let attributeKeys = ["id", "text", "risk", "verifymethod", "type"]

    // 画布与排版常量：宽度硬上限 1200pt。
    private static let padding: CGFloat = 22
    /// 列间距要容得下关系动词标签（如 `satisfies`），否则标签会压住两侧的框。
    private static let columnGap: CGFloat = 62
    private static let rowGap: CGFloat = 84
    private static let minNodeWidth: CGFloat = 180
    private static let maxNodeWidth: CGFloat = 300
    private static let maxCanvasWidth: CGFloat = 1200
    private static let maxColumns = 3
    private static let minNodes = 2
    private static let maxNodes = 8

    /// 框内的竖向度量（与外层 `height(of:)` 必须一致）。
    private static let framePadding: CGFloat = 12
    private static let titleHeight: CGFloat = 16
    private static let titleGap: CGFloat = 4
    private static let attributeHeight: CGFloat = 15
    private static let attributeGap: CGFloat = 4

    /// 同行跨列的关系绕到该行上方的通道高度（在节点框上方 14pt）。
    /// 选在上方而不是下方：行间 gap 的中线已被跨行关系占用，走上方可避免标签叠在一起。
    private static let detourHeight: CGFloat = 14

    private static let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    private static let attributeFont = NSFont.systemFont(ofSize: 10.5)
    private static let verbFont = NSFont.systemFont(ofSize: 10, weight: .medium)

    /// 低饱和灰蓝：框线、箭头与动词标签统一使用。
    private static let accent = NSColor(srgbRed: 0.34, green: 0.47, blue: 0.62, alpha: 1)
    private static let elementAccent = NSColor(srgbRed: 0.42, green: 0.45, blue: 0.55, alpha: 1)

    /// 节点在画布上的位置（行/列用于决定关系线的走法）。
    private struct Placed {
        var rect: NSRect
        var row: Int
        var column: Int
    }

    static func image(forSource source: String) -> NSImage? {
        guard let parsed = parse(MermaidSource.stripped(source)) else { return nil }
        let nodes = parsed.nodes
        let relations = parsed.relations

        let nodeWidth = min(maxNodeWidth,
                            max(minNodeWidth, measureWidth(nodes) + framePadding * 2))
        let columns = min(maxColumns, nodes.count)
        let rows = Int((Double(nodes.count) / Double(columns)).rounded(.up))
        var rowHeights: [CGFloat] = []
        for row in 0..<rows {
            let start = row * columns
            let end = min(nodes.count, start + columns)
            rowHeights.append(nodes[start..<end].map { height(of: $0) }.max() ?? 44)
        }

        let width = padding * 2 + CGFloat(columns) * nodeWidth
            + CGFloat(max(0, columns - 1)) * columnGap
        // 同行跨列的关系要绕到该行上方的通道。首行上方只有画布留白，
        // 所以这里预留一段额外顶部空间，避免通道与动词标签被裁掉。
        var rowIndexBy: [String: Int] = [:]
        for (index, node) in nodes.enumerated() { rowIndexBy[node.name] = index }
        let needsTopChannel = relations.contains { relation in
            guard let a = rowIndexBy[relation.from], let b = rowIndexBy[relation.to]
            else { return false }
            return (a / columns) == 0 && (b / columns) == 0
                && abs((a % columns) - (b % columns)) > 1
        }
        let topExtra = needsTopChannel ? detourHeight + 22 : 0
        // 注意：这里命名为 totalHeight，避免遮蔽静态方法 `height(of:)`。
        let totalHeight = padding * 2 + rowHeights.reduce(0, +)
            + CGFloat(max(0, rows - 1)) * rowGap + topExtra

        // 网格定位：每行水平居中，行内节点垂直居中。
        var placed: [String: Placed] = [:]
        var top = totalHeight - padding - topExtra
        for row in 0..<rows {
            let rowHeight = rowHeights[row]
            let start = row * columns
            let end = min(nodes.count, start + columns)
            let count = end - start
            let rowWidth = CGFloat(count) * nodeWidth + CGFloat(max(0, count - 1)) * columnGap
            let startX = (width - rowWidth) / 2
            for (offset, node) in nodes[start..<end].enumerated() {
                let nodeHeight = height(of: node)
                let rect = NSRect(x: startX + CGFloat(offset) * (nodeWidth + columnGap),
                                  y: top - rowHeight + (rowHeight - nodeHeight) / 2,
                                  width: nodeWidth,
                                  height: nodeHeight)
                placed[node.name] = Placed(rect: rect, row: row, column: offset)
            }
            top -= rowHeight + rowGap
        }

        let image = NSImage(size: NSSize(width: width, height: totalHeight))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.textBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: width, height: totalHeight).fill()

        // 先画关系线（线会被节点框遮挡，端口自然落在框外），再画框，最后画动词标签。
        var labels: [(String, NSPoint)] = []
        for relation in relations {
            guard let from = placed[relation.from], let to = placed[relation.to] else { continue }
            if let point = drawRelation(from: from, to: to) {
                labels.append((relation.verb, point))
            }
        }
        for node in nodes {
            guard let spot = placed[node.name] else { continue }
            drawNode(node, rect: spot.rect)
        }
        for (verb, point) in labels {
            drawVerb(verb, at: point)
        }

        return image
    }

    // MARK: - 解析

    private static func parse(_ source: String) -> (nodes: [Node], relations: [Relation])? {
        var nodes: [Node] = []
        var indexBy: [String: Int] = [:]
        var relations: [Relation] = []
        /// 当前处于多行块的节点下标；nil 表示不在块内。
        var blockIndex: Int? = nil
        var isFirstLine = true

        func upsertNode(_ name: String, kind: NodeKind) -> Int {
            if let index = indexBy[name] { return index }
            nodes.append(Node(name: name, kind: kind))
            indexBy[name] = nodes.count - 1
            return nodes.count - 1
        }

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            // 首行是类型声明（`requirement` / `requirementDiagram`），直接跳过。
            if isFirstLine {
                isFirstLine = false
                continue
            }
            guard !line.isEmpty, !line.hasPrefix("%%") else { continue }

            // 块内：属性行或结束花括号。
            if let index = blockIndex {
                if let closing = line.firstIndex(where: { $0 == "}" }) {
                    appendAttributes(String(line[..<closing]), to: index, in: &nodes)
                    blockIndex = nil
                } else {
                    appendAttributes(line, to: index, in: &nodes)
                }
                continue
            }

            if let declaration = declaration(from: line) {
                let name = unquote(declaration.name)
                guard !name.isEmpty else { continue }
                let kind: NodeKind = declaration.keyword == "element" ? .element : .requirement
                let index = upsertNode(name, kind: kind)
                if let inline = declaration.inline {
                    if let closing = inline.firstIndex(where: { $0 == "}" }) {
                        appendAttributes(String(inline[..<closing]), to: index, in: &nodes)
                    } else {
                        appendAttributes(inline, to: index, in: &nodes)
                        blockIndex = index
                    }
                }
                continue
            }

            if let relation = relation(from: line) {
                relations.append(relation)
            }
        }

        // 关系里出现但没声明的端点补成无属性需求节点（保持在末尾）。
        for relation in relations {
            _ = upsertNode(relation.from, kind: .requirement)
            _ = upsertNode(relation.to, kind: .requirement)
        }

        guard (minNodes...maxNodes).contains(nodes.count) else { return nil }
        // 自环无法在网格布局里表达，直接丢弃。
        let valid = relations.filter { $0.from != $0.to }
        return (nodes, valid)
    }

    /// 拆出 `需求/element` 声明行：关键字、名称、可选的 `{` 之后内容。
    private static func declaration(from line: String) -> (keyword: String, name: String,
                                                          inline: String?)? {
        let lower = line.lowercased()
        for keyword in ["requirement", "element"] {
            guard lower.hasPrefix(keyword) else { continue }
            let rest = String(line.dropFirst(keyword.count))
            // 关键字后必须是空白或 `{`，避免把 `requirementDiagram` 之类当成声明。
            guard rest.isEmpty || rest.first?.isWhitespace == true || rest.first == "{"
            else { continue }
            var body = rest.trimmingCharacters(in: .whitespaces)
            var inline: String? = nil
            if let brace = body.firstIndex(of: "{") {
                inline = String(body[body.index(after: brace)...])
                body = String(body[..<brace]).trimmingCharacters(in: .whitespaces)
            }
            return (keyword, body, inline)
        }
        return nil
    }

    /// 解析 `A - satisfies -> B`；动词不在白名单、缺端点或自环时返回 nil。
    private static func relation(from line: String) -> Relation? {
        // `-->` 统一收成 `->`，两种写法都接受。
        let normalized = line.replacingOccurrences(of: "-->", with: "->")
        guard let arrow = normalized.range(of: "->") else { return nil }
        let left = String(normalized[..<arrow.lowerBound]).trimmingCharacters(in: .whitespaces)
        var right = String(normalized[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
        while right.hasSuffix(";") {
            right = String(right.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard let dash = left.range(of: " - ", options: .backwards) else { return nil }
        let from = unquote(String(left[..<dash.lowerBound]))
        let verb = String(left[dash.upperBound...]).trimmingCharacters(in: .whitespaces).lowercased()
        let to = unquote(right)
        guard !from.isEmpty, !to.isEmpty, from != to, verbs.contains(verb) else { return nil }
        return Relation(from: from, to: to, verb: verb)
    }

    /// 写入一段可能含多个 `key: value` 的文本（单行块用逗号/分号分隔）。
    private static func appendAttributes(_ body: String, to index: Int,
                                         in nodes: inout [Node]) {
        guard index >= 0, index < nodes.count else { return }
        let text = body.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        for part in splitAttributes(text) {
            guard let colon = part.firstIndex(where: { $0 == ":" || $0 == "：" }) else { continue }
            let key = String(part[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(part[part.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            while value.hasSuffix(",") || value.hasSuffix(";") {
                value = String(value.dropLast()).trimmingCharacters(in: .whitespaces)
            }
            guard attributeKeys.contains(key), !value.isEmpty else { continue }
            if let existing = nodes[index].attributes.firstIndex(where: { $0.key == key }) {
                nodes[index].attributes[existing].value = value
            } else {
                nodes[index].attributes.append((key: key, value: value))
            }
        }
    }

    /// 只在「`,` / `;` 后紧跟已知属性键」处切分，避免把 `text: A, B` 里的逗号切碎。
    private static func splitAttributes(_ text: String) -> [String] {
        var parts: [String] = []
        var remainder = Substring(text)
        while true {
            var splitIndex: String.Index? = nil
            var cursor = remainder.startIndex
            while cursor < remainder.endIndex {
                let character = remainder[cursor]
                if character == "," || character == ";" {
                    let tail = remainder[remainder.index(after: cursor)...]
                        .trimmingCharacters(in: .whitespaces).lowercased()
                    if attributeKeys.contains(where: {
                        tail.hasPrefix($0 + ":") || tail.hasPrefix($0 + "：")
                    }) {
                        splitIndex = cursor
                        break
                    }
                }
                cursor = remainder.index(after: cursor)
            }
            guard let splitIndex else {
                parts.append(String(remainder))
                break
            }
            parts.append(String(remainder[..<splitIndex]))
            remainder = remainder[remainder.index(after: splitIndex)...]
        }
        return parts
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

    // MARK: - 布局

    /// 框内要显示的属性（固定顺序，最多四个）。
    private static func displayAttributes(_ node: Node) -> [(key: String, value: String)] {
        let preferred = node.kind == .element ? ["type", "id", "text", "risk"] : ["id", "text", "risk", "verifymethod"]
        return preferred.compactMap { key in
            node.attributes.first(where: { $0.key == key }).map { (key: key, value: $0.value) }
        }
    }

    private static func height(of node: Node) -> CGFloat {
        let count = displayAttributes(node).count
        let content = framePadding * 2 + titleHeight + titleGap
        return content + CGFloat(count) * attributeHeight
            + (count > 0 ? attributeGap : 0)
    }

    /// 所有节点的最宽内容（标题 / 属性行）。
    private static func measureWidth(_ nodes: [Node]) -> CGFloat {
        var widest: CGFloat = 0
        for node in nodes {
            widest = max(widest, measure(node.name, font: titleFont))
            for attribute in displayAttributes(node) {
                widest = max(widest, measure("\(attribute.key): \(attribute.value)", font: attributeFont))
            }
        }
        return widest
    }

    // MARK: - 绘制

    /// 画关系线，返回动词标签应该落的位置（`nil` 表示两端不可见）。
    private static func drawRelation(from: Placed, to: Placed) -> NSPoint? {
        let a = from.rect
        let b = to.rect

        // 同一行相邻两列：直接水平连。
        if from.row == to.row, abs(from.column - to.column) == 1 {
            let rightward = b.midX > a.midX
            let start = NSPoint(x: rightward ? a.maxX : a.minX, y: a.midY)
            let end = NSPoint(x: rightward ? b.minX : b.maxX, y: b.midY)
            // 行内两框高度可能不同，用两点连线（近似水平）保证箭头落在框边中点。
            drawPolyline([start, end], dashed: false)
            drawHead(at: end, angle: atan2(end.y - start.y, end.x - start.x), color: accent)
            return NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 + 8)
        }

        // 同一行跨列：绕到两框上方的通道，避免线穿过中间节点；
        // 通道位于行间 gap 的上半部（首行则在预留的顶部空白里），与跨行关系的通道错开。
        if from.row == to.row {
            let channelY = max(a.maxY, b.maxY) + detourHeight
            let points = [NSPoint(x: a.midX, y: a.maxY),
                          NSPoint(x: a.midX, y: channelY),
                          NSPoint(x: b.midX, y: channelY),
                          NSPoint(x: b.midX, y: b.maxY)]
            drawPolyline(points, dashed: false)
            drawHead(at: points[3], angle: -.pi / 2, color: accent)
            return NSPoint(x: (a.midX + b.midX) / 2, y: channelY + 6)
        }

        // 跨行：走两行之间的通道。
        let downward = to.row > from.row
        let start = NSPoint(x: a.midX, y: downward ? a.minY : a.maxY)
        let end = NSPoint(x: b.midX, y: downward ? b.maxY : b.minY)
        let channelY = downward ? (a.minY + b.maxY) / 2 : (a.maxY + b.minY) / 2
        let points = [start,
                      NSPoint(x: a.midX, y: channelY),
                      NSPoint(x: b.midX, y: channelY),
                      end]
        drawPolyline(points, dashed: false)
        drawHead(at: end, angle: downward ? -.pi / 2 : .pi / 2, color: accent)
        return NSPoint(x: (a.midX + b.midX) / 2, y: channelY + 2)
    }

    private static func drawPolyline(_ points: [NSPoint], dashed: Bool) {
        guard points.count >= 2 else { return }
        let path = NSBezierPath()
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.line(to: point)
        }
        path.lineWidth = 1.2
        path.lineJoinStyle = .round
        if dashed { path.setLineDash([4, 3], count: 2, phase: 0) }
        accent.withAlphaComponent(0.85).setStroke()
        path.stroke()
    }

    /// 实心三角箭头头部，`angle` 为箭头指向（弧度，0 = 向右）。
    private static func drawHead(at point: NSPoint, angle: CGFloat, color: NSColor) {
        let length: CGFloat = 8
        let halfWidth: CGFloat = 4.5
        let baseX = point.x - cos(angle) * length
        let baseY = point.y - sin(angle) * length
        let offsetX = -sin(angle) * halfWidth
        let offsetY = cos(angle) * halfWidth
        let head = NSBezierPath()
        head.move(to: point)
        head.line(to: NSPoint(x: baseX + offsetX, y: baseY + offsetY))
        head.line(to: NSPoint(x: baseX - offsetX, y: baseY - offsetY))
        head.close()
        color.setFill()
        head.fill()
    }

    private static func drawNode(_ node: Node, rect: NSRect) {
        let color = node.kind == .element ? elementAccent : accent
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        color.withAlphaComponent(0.09).setFill()
        path.fill()
        color.withAlphaComponent(0.72).setStroke()
        path.lineWidth = 1.2
        if node.kind == .element {
            path.setLineDash([4, 3], count: 2, phase: 0)
        }
        path.stroke()

        // 标题（左上）与分隔线。
        let titleY = rect.maxY - framePadding - titleHeight
        drawLeft(node.name, font: titleFont, color: NSColor.labelColor,
                 x: rect.minX + framePadding, y: titleY,
                 maxWidth: max(1, rect.width - framePadding * 2))
        let separatorY = titleY - titleGap
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: rect.minX + framePadding, y: separatorY))
        separator.line(to: NSPoint(x: rect.maxX - framePadding, y: separatorY))
        NSColor.separatorColor.setStroke()
        separator.lineWidth = 0.8
        separator.stroke()

        // 属性行自上而下。
        let attributes = displayAttributes(node)
        let top = separatorY - attributeGap
        for (index, attribute) in attributes.enumerated() {
            let y = top - CGFloat(index + 1) * attributeHeight + 2
            let text = "\(attribute.key): \(attribute.value)"
            drawLeft(text, font: attributeFont, color: NSColor.secondaryLabelColor,
                     x: rect.minX + framePadding, y: y,
                     maxWidth: max(1, rect.width - framePadding * 2))
        }
    }

    /// 动词标签：先用背景色垫一层，压住关系线，再画文字。
    private static func drawVerb(_ verb: String, at point: NSPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: verbFont,
            .foregroundColor: accent,
        ]
        let size = (verb as NSString).size(withAttributes: attributes)
        let background = NSRect(x: point.x - size.width / 2 - 4, y: point.y - size.height / 2 - 1,
                                width: size.width + 8, height: size.height + 2)
        NSColor.textBackgroundColor.setFill()
        background.fill()
        (verb as NSString).draw(at: NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2),
                                withAttributes: attributes)
    }

    private static func drawLeft(_ text: String, font: NSFont, color: NSColor,
                                 x: CGFloat, y: CGFloat, maxWidth: CGFloat) {
        let line = fitted(text, font: font, maxWidth: maxWidth)
        guard !line.isEmpty else { return }
        (line as NSString).draw(at: NSPoint(x: x, y: y),
                                withAttributes: [.font: font, .foregroundColor: color])
    }

    private static func measure(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
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
