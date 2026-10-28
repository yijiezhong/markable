import AppKit

/// 自研 **Mermaid `mindmap`** 渲染（swift-mermaid 不支持）：缩进层级 → 树形布局 → 绘制。
///
/// 支持的语法（简化子集）：以 `mindmap` 起始；缩进（空格/tab）表示层级；其余行为节点文本。
enum MindmapRenderer {
    private final class Node {
        var text: String
        var children: [Node] = []
        var position = NSPoint.zero
        var width: CGFloat = 0
        init(text: String) { self.text = text }
    }

    private static let levelWidth: CGFloat = 150
    private static let rowGap: CGFloat = 30
    private static let padding: CGFloat = 16
    private static let nodeHeight: CGFloat = 24

    static func image(forSource source: String) -> NSImage? {
        // 统一剔除 `%%{init}%%` / `%%` 注释（与主流程 MermaidRenderer.headType 一致）
        let source = MermaidSource.stripped(source)
        guard let root = parse(source) else { return nil }
        measure(root, font: nodeFont)
        var cursor: CGFloat = 0
        layout(root, depth: 0, top: &cursor)

        // 计算画布尺寸
        var maxX: CGFloat = 0
        var minY: CGFloat = .greatestFiniteMagnitude
        var maxY: CGFloat = 0
        visit(root) { node in
            maxX = max(maxX, node.position.x + node.width)
            minY = min(minY, node.position.y)
            maxY = max(maxY, node.position.y + nodeHeight)
        }
        let width = maxX + padding * 2
        let height = (maxY - minY) + padding * 2
        let yOffset = padding - minY

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.textBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        draw(node: root, yOffset: yOffset, isRoot: true)
        return image
    }

    private static let nodeFont = NSFont.systemFont(ofSize: 12)
    private static let rootFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

    // MARK: - 解析

    private static func parse(_ source: String) -> Node? {
        var root: Node?
        var stack: [(indent: Int, node: Node)] = []
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed != "mindmap", !trimmed.hasPrefix("%%") else { continue }
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            let node = Node(text: stripShape(trimmed))
            while let last = stack.last, last.indent >= indent { stack.removeLast() }
            if let parent = stack.last?.node {
                parent.children.append(node)
            } else {
                root = root ?? node
            }
            stack.append((indent, node))
        }
        return root
    }

    /// 去掉 Mermaid 节点形状包裹：`((x))` / `{{x}}` / `[x]` / `(x)` / `{x}`。
    private static func stripShape(_ s: String) -> String {
        var text = s.trimmingCharacters(in: .whitespaces)
        let pairs: [(String, String)] = [("((", "))"), ("{{", "}}"), ("[", "]"), ("(", ")"), ("{", "}")]
        for (open, close) in pairs
        where text.hasPrefix(open) && text.hasSuffix(close) && text.count > open.count + close.count {
            text = String(text.dropFirst(open.count).dropLast(close.count))
            break
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 布局

    @discardableResult
    private static func measure(_ node: Node, font: NSFont) -> CGFloat {
        let size = (node.text as NSString).size(withAttributes: [.font: font])
        node.width = size.width + 16
        if node.children.isEmpty { return 1 }
        var total: CGFloat = 0
        for child in node.children { total += measure(child, font: font) }
        return total
    }

    /// 返回该子树占用的“行数”。
    private static func subtreeRows(_ node: Node) -> CGFloat {
        if node.children.isEmpty { return 1 }
        return node.children.reduce(0) { $0 + subtreeRows($1) }
    }

    private static func layout(_ node: Node, depth: Int, top: inout CGFloat) {
        let rows = subtreeRows(node)
        let centerRow = top + rows / 2
        node.position = NSPoint(x: padding + CGFloat(depth) * levelWidth, y: -centerRow * rowGap)
        var childTop = top
        for child in node.children {
            layout(child, depth: depth + 1, top: &childTop)
        }
        top += rows
    }

    // MARK: - 绘制

    private static func draw(node: Node, yOffset: CGFloat, isRoot: Bool) {
        let font = isRoot ? rootFont : nodeFont
        let rect = NSRect(x: node.position.x, y: node.position.y + yOffset, width: node.width, height: nodeHeight)

        // 到父节点的连线（用子节点回连）
        for child in node.children {
            let parentMid = NSPoint(x: rect.maxX, y: rect.midY)
            let childRect = NSRect(x: child.position.x, y: child.position.y + yOffset, width: child.width, height: nodeHeight)
            let childMid = NSPoint(x: childRect.minX, y: childRect.midY)
            let path = NSBezierPath()
            let midX = (parentMid.x + childMid.x) / 2
            path.move(to: parentMid)
            path.line(to: NSPoint(x: midX, y: parentMid.y))
            path.line(to: NSPoint(x: midX, y: childMid.y))
            path.line(to: childMid)
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        // 节点框
        let box = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        let fill = isRoot ? NSColor.controlAccentColor.withAlphaComponent(0.18) : NSColor.quaternaryLabelColor
        fill.setFill()
        box.fill()
        NSColor.separatorColor.setStroke()
        box.lineWidth = 0.5
        box.stroke()

        // 文本
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let size = (node.text as NSString).size(withAttributes: attributes)
        let textPoint = NSPoint(x: rect.minX + 8, y: rect.midY - size.height / 2)
        (node.text as NSString).draw(at: textPoint, withAttributes: attributes)

        for child in node.children {
            draw(node: child, yOffset: yOffset, isRoot: false)
        }
    }

    private static func visit(_ node: Node, _ body: (Node) -> Void) {
        body(node)
        for child in node.children { visit(child, body) }
    }
}
