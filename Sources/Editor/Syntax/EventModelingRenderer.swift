import AppKit

/// 自研 **Mermaid `eventmodeling` / `tf`** 渲染（swift-mermaid 不支持）：
/// 事件建模的「命令 → 事件 → 视图」流水线，按链分行、节点横向排列、箭头相连。
///
/// 支持的语法（简化子集）：
/// ```
/// eventmodeling
///   下单 -> 订单已创建 -> 订单详情
///   订单详情 => 发货
///   command 支付
///   event 已支付
///   view 支付结果
/// ```
/// - 首行 `eventmodeling` 或 `tf`。
/// - 链式行 `A -> B -> C`：箭头 `->` 画实线、`=>` 画虚线；一条链占一行。
/// - 显式声明 `command 名称` / `event 名称` / `view 名称`（也接受 `cmd` / `evt` 简写）；
///   连续多条声明组成一条隐式链，相邻节点自动用实线箭头连接，空行或注释行结束该链。
/// - 节点类型：显式声明优先；未声明时按链内位置推断（命令 → 事件 → 视图循环），
///   若链首节点已有类型，则从该类型开始循环（例如 `event X -> view Y`）。
/// - 每条链最多 10 个节点；无法识别出任何节点时返回 nil（调用方回退源码并提示）。
enum EventModelingRenderer {
    private enum Kind {
        case command
        case event
        case view

        /// 框内顶部的中文类型标签。
        var label: String {
            switch self {
            case .command: return "命令"
            case .event: return "事件"
            case .view: return "视图"
            }
        }
    }

    private struct Node {
        var name: String
        var kind: Kind
    }

    /// 一条链：节点序列 + 相邻节点之间的箭头类型（`dashed.count == nodes.count - 1`）。
    private struct Chain {
        var nodes: [Node]
        var dashed: [Bool]
    }

    // 画布与排版常量：宽度硬上限 1200pt。
    private static let padding: CGFloat = 20
    private static let nodeHeight: CGFloat = 56
    private static let rowGap: CGFloat = 34
    private static let arrowGap: CGFloat = 58
    private static let minArrowGap: CGFloat = 30
    private static let minNodeWidth: CGFloat = 76
    private static let maxNodeWidth: CGFloat = 200
    private static let maxCanvasWidth: CGFloat = 1200
    private static let maxNodesPerChain = 10

    private static let nameFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let kindFont = NSFont.systemFont(ofSize: 9, weight: .medium)

    /// 三种低饱和色：蓝灰 = 命令、琥珀灰 = 事件、青灰 = 视图。
    private static let commandColor = NSColor(srgbRed: 0.33, green: 0.46, blue: 0.63, alpha: 1)
    private static let eventColor = NSColor(srgbRed: 0.62, green: 0.49, blue: 0.31, alpha: 1)
    private static let viewColor = NSColor(srgbRed: 0.32, green: 0.53, blue: 0.49, alpha: 1)
    /// 箭头统一用低调的灰蓝，避免抢节点颜色的戏。
    private static let arrowColor = NSColor(srgbRed: 0.52, green: 0.57, blue: 0.64, alpha: 1)

    static func image(forSource source: String) -> NSImage? {
        guard let chains = parse(MermaidSource.stripped(source)) else { return nil }

        // 全图共用一个节点宽度；行内太挤时先压节点宽，再压箭头间距。
        let measured = chains.flatMap { $0.nodes }
            .map { measure($0.name, font: nameFont) + 26 }
            .max() ?? minNodeWidth
        let longest = chains.map { $0.nodes.count }.max() ?? 1
        let maxContent = maxCanvasWidth - padding * 2

        var nodeWidth = min(maxNodeWidth, max(minNodeWidth, measured.rounded()))
        var gap = arrowGap
        func rowWidth(_ count: Int) -> CGFloat {
            CGFloat(count) * nodeWidth + CGFloat(max(0, count - 1)) * gap
        }
        if longest > 1, rowWidth(longest) > maxContent {
            let available = maxContent - CGFloat(longest - 1) * gap
            nodeWidth = min(nodeWidth, max(70, (available / CGFloat(longest)).rounded(.down)))
            if rowWidth(longest) > maxContent {
                gap = minArrowGap
                let second = maxContent - CGFloat(longest - 1) * gap
                nodeWidth = max(64, (second / CGFloat(longest)).rounded(.down))
                if rowWidth(longest) > maxContent { return nil }
            }
        }

        let contentWidth = rowWidth(longest)
        let width = padding * 2 + contentWidth
        let height = padding * 2 + CGFloat(chains.count) * nodeHeight
            + CGFloat(max(0, chains.count - 1)) * rowGap

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.textBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        let top = height - padding
        for (row, chain) in chains.enumerated() {
            let rowTop = top - CGFloat(row) * (nodeHeight + rowGap)
            let y = rowTop - nodeHeight
            let widthOfRow = rowWidth(chain.nodes.count)
            let startX = (width - widthOfRow) / 2

            var rects: [NSRect] = []
            for column in chain.nodes.indices {
                let rect = NSRect(x: startX + CGFloat(column) * (nodeWidth + gap),
                                  y: y, width: nodeWidth, height: nodeHeight)
                rects.append(rect)
            }

            // 先画箭头（压在节点框下面），再画节点。
            for index in 0..<max(0, rects.count - 1) {
                let from = NSPoint(x: rects[index].maxX + 2, y: rects[index].midY)
                let to = NSPoint(x: rects[index + 1].minX - 2, y: rects[index + 1].midY)
                let dashed = index < chain.dashed.count && chain.dashed[index]
                drawArrow(from: from, to: to, dashed: dashed)
            }
            for (column, node) in chain.nodes.enumerated() {
                drawNode(node, rect: rects[column])
            }
        }

        return image
    }

    // MARK: - 解析

    private static func parse(_ source: String) -> [Chain]? {
        var kinds: [String: Kind] = [:]
        var chains: [Chain] = []
        /// 连续声明行累积成一条隐式链。
        var pending: [String] = []
        var isFirstLine = true

        func flushPending() {
            guard !pending.isEmpty else { return }
            let nodes = pending.map { Node(name: $0, kind: kinds[$0] ?? .command) }
            chains.append(Chain(nodes: nodes,
                                dashed: Array(repeating: false, count: max(0, nodes.count - 1))))
            pending.removeAll()
        }

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            // 首行是类型声明（`eventmodeling` / `tf`），直接跳过。
            if isFirstLine {
                isFirstLine = false
                continue
            }
            // 空行与注释行结束当前的隐式链。
            if line.isEmpty || line.hasPrefix("%%") {
                flushPending()
                continue
            }

            if let declaration = declaration(from: line) {
                kinds[declaration.name] = declaration.kind
                pending.append(declaration.name)
                continue
            }

            if let sequence = chain(from: line) {
                flushPending()
                chains.append(buildChain(names: sequence.names,
                                         arrows: sequence.dashed,
                                         kinds: &kinds))
                continue
            }
            // 无法识别的行：结束隐式链，忽略该行。
            flushPending()
        }
        flushPending()

        guard !chains.isEmpty else { return nil }
        guard chains.allSatisfy({ (1...maxNodesPerChain).contains($0.nodes.count) }) else {
            return nil
        }
        return chains
    }

    /// 解析显式声明：`command 名称` / `event 名称` / `view 名称`（含 `cmd` / `evt` 简写与冒号写法）。
    private static func declaration(from line: String) -> (name: String, kind: Kind)? {
        let keywords: [(String, Kind)] = [
            ("command", .command), ("cmd", .command),
            ("event", .event), ("evt", .event),
            ("view", .view),
        ]
        let lower = line.lowercased()
        for (keyword, kind) in keywords {
            guard lower.hasPrefix(keyword) else { continue }
            let rest = String(line.dropFirst(keyword.count))
            // 关键字后必须是空白、冒号或行尾，避免 `commandCenter`、`viewModel` 之类误判。
            guard rest.isEmpty || rest.first?.isWhitespace == true
                || rest.first == ":" || rest.first == "：" else { continue }
            let name = clean(rest.trimmingCharacters(in: CharacterSet(charactersIn: " :：")))
            guard !name.isEmpty else { continue }
            return (name, kind)
        }
        return nil
    }

    /// 解析链式行 `A -> B => C`，返回节点名与箭头类型；不足两个节点时返回 nil。
    private static func chain(from line: String) -> (names: [String], dashed: [Bool])? {
        var names: [String] = []
        var dashed: [Bool] = []
        var remainder = Substring(line)
        while let arrow = firstArrow(in: remainder) {
            let name = clean(String(remainder[..<arrow.range.lowerBound]))
            guard !name.isEmpty else { return nil }
            names.append(name)
            dashed.append(arrow.dashed)
            remainder = remainder[arrow.range.upperBound...]
        }
        let tail = clean(String(remainder))
        guard !tail.isEmpty else { return nil }
        names.append(tail)
        guard names.count >= 2 else { return nil }
        return (names, dashed)
    }

    /// 在一段文本里找最早的箭头（`=>` 为虚线、`->` 为实线）。
    private static func firstArrow(in text: Substring)
        -> (range: Range<Substring.Index>, dashed: Bool)? {
        var best: (range: Range<Substring.Index>, dashed: Bool)? = nil
        for (symbol, dashed) in [("=>", true), ("->", false)] {
            guard let range = text.range(of: symbol) else { continue }
            if let current = best, current.range.lowerBound <= range.lowerBound { continue }
            best = (range, dashed)
        }
        return best
    }

    /// 名称清洗：去引号、去尾部 `;`，限制长度。
    private static func clean(_ text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespaces)
        while body.hasSuffix(";") {
            body = String(body.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if body.count >= 2, body.hasPrefix("\""), body.hasSuffix("\"") {
            body = String(body.dropFirst().dropLast())
        } else if body.count >= 2, body.hasPrefix("'"), body.hasSuffix("'") {
            body = String(body.dropFirst().dropLast())
        }
        return String(body.trimmingCharacters(in: .whitespaces).prefix(60))
    }

    /// 按「命令 → 事件 → 视图」循环补全类型；显式类型会重置后续推断的起点。
    private static func buildChain(names: [String], arrows: [Bool],
                                   kinds: inout [String: Kind]) -> Chain {
        let cycle: [Kind] = [.command, .event, .view]
        // `start` 是一个偏移量：让第 index 个节点落在 cycle[(start + index) % 3]。
        var start = 0
        if let first = names.first, let kind = kinds[first],
           let index = cycle.firstIndex(where: { $0 == kind }) {
            start = index
        }
        var nodes: [Node] = []
        for (index, name) in names.enumerated() {
            if let kind = kinds[name] {
                nodes.append(Node(name: name, kind: kind))
                let position = cycle.firstIndex(where: { $0 == kind }) ?? 0
                start = position - index
            } else {
                let position = ((start + index) % cycle.count + cycle.count) % cycle.count
                let kind = cycle[position]
                kinds[name] = kind
                nodes.append(Node(name: name, kind: kind))
            }
        }
        let dashes = Array(arrows.prefix(max(0, nodes.count - 1)))
        return Chain(nodes: nodes, dashed: dashes)
    }

    // MARK: - 绘制

    private static func drawNode(_ node: Node, rect: NSRect) {
        let color = self.color(for: node.kind)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        color.withAlphaComponent(0.16).setFill()
        path.fill()
        color.withAlphaComponent(0.85).setStroke()
        path.lineWidth = 1.2
        path.stroke()

        // 顶部类型小字 + 居中的名称（两行，均单行截断）。
        let innerWidth = max(1, rect.width - 20)
        drawLeft(node.kind.label, font: kindFont, color: color.withAlphaComponent(0.95),
                 x: rect.minX + 10, y: rect.maxY - 20, maxWidth: innerWidth)
        drawLeft(node.name, font: nameFont, color: NSColor.labelColor,
                 x: rect.minX + 10, y: rect.minY + 14, maxWidth: innerWidth)
    }

    private static func color(for kind: Kind) -> NSColor {
        switch kind {
        case .command: return commandColor
        case .event: return eventColor
        case .view: return viewColor
        }
    }

    private static func drawArrow(from: NSPoint, to: NSPoint, dashed: Bool) {
        let path = NSBezierPath()
        path.move(to: from)
        path.line(to: to)
        path.lineWidth = 1.2
        if dashed { path.setLineDash([4, 3], count: 2, phase: 0) }
        arrowColor.setStroke()
        path.stroke()
        drawHead(at: to, angle: atan2(to.y - from.y, to.x - from.x), color: arrowColor)
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
