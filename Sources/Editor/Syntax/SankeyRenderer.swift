import AppKit

/// 自研 **Mermaid `sankey-beta`** 渲染（swift-mermaid 不支持）：解析 → 分层布局 → 带状流绘制。
///
/// 支持的语法（简化子集）：每行 `源,目标,数值`（CSV；允许引号包裹含逗号的名称）。
/// ```
/// sankey-beta
///   A,B,10
///   B,C,6
///   B,D,4
/// ```
enum SankeyRenderer {
    private struct Link {
        var source: String
        var target: String
        var value: Double
    }

    private static let padding: CGFloat = 16
    private static let nodeWidth: CGFloat = 16
    private static let chartHeight: CGFloat = 420
    private static let nodeGap: CGFloat = 14

    static func image(forSource source: String) -> NSImage? {
        // 统一剔除 `%%{init}%%` / `%%` 注释（与主流程 MermaidRenderer.headType 一致）
        let source = MermaidSource.stripped(source)
        var links: [Link] = []
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("%%"), !line.hasPrefix("sankey") else { continue }
            let parts = line.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            guard parts.count >= 3, let value = Double(parts[2]), value > 0 else { continue }
            links.append(Link(source: parts[0], target: parts[1], value: value))
        }
        guard !links.isEmpty else { return nil }

        let nodes = orderedNodes(links)
        let depths = nodeDepths(links: links, nodes: nodes)
        let maxDepth = depths.values.max() ?? 0

        // 每个节点的流量（取流入/流出较大值）
        var nodeTotal: [String: Double] = [:]
        for node in nodes {
            let out = links.filter { $0.source == node }.reduce(0) { $0 + $1.value }
            let incoming = links.filter { $0.target == node }.reduce(0) { $0 + $1.value }
            nodeTotal[node] = max(out, incoming, 0.0001)
        }

        // 每列的总高度
        var columnTotals = [Double](repeating: 0, count: maxDepth + 1)
        for node in nodes {
            let depth = depths[node] ?? 0
            columnTotals[depth] += nodeTotal[node] ?? 0
        }
        let maxColumnTotal = max(1, columnTotals.max() ?? 1)
        let scale = chartHeight / CGFloat(maxColumnTotal)

        // 画布尺寸
        let labelWidth: CGFloat = 120
        let width = padding * 2 + CGFloat(maxDepth + 1) * (nodeWidth + labelWidth) + CGFloat(maxDepth) * 40
        let height = padding * 2 + chartHeight + 20
        let columnStride = (width - padding * 2 - nodeWidth) / CGFloat(max(1, maxDepth))

        // 节点位置
        struct Placed { var x: CGFloat; var y: CGFloat; var h: CGFloat }   // y = 顶部
        var placement: [String: Placed] = [:]
        for depth in 0...maxDepth {
            let nodesInColumn = nodes.filter { (depths[$0] ?? 0) == depth }
            let total = CGFloat(columnTotals[depth]) * scale + CGFloat(max(0, nodesInColumn.count - 1)) * nodeGap
            var top = (height - total) / 2 + total          // 顶部对齐到居中区
            for node in nodesInColumn {
                let h = CGFloat(nodeTotal[node] ?? 0.0001) * scale
                let x = depth == 0 ? padding : padding + CGFloat(depth) * columnStride
                placement[node] = Placed(x: x, y: top, h: h)
                top -= (h + nodeGap)
            }
        }

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.textBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        // 流带：源/目标两侧按出现顺序分配纵向槽位
        var outOffset: [String: CGFloat] = [:]
        var inOffset: [String: CGFloat] = [:]
        let palette: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemTeal, .systemPink, .systemIndigo, .systemRed]

        for (index, link) in links.enumerated() {
            guard let s = placement[link.source], let t = placement[link.target] else { continue }
            let band = CGFloat(link.value) * scale

            let so = outOffset[link.source] ?? 0
            let to = inOffset[link.target] ?? 0
            let syTop = s.y - so
            let tyTop = t.y - to
            outOffset[link.source] = so + band
            inOffset[link.target] = to + band

            let sx = s.x + nodeWidth
            let tx = t.x
            let cx = (sx + tx) / 2

            let path = NSBezierPath()
            path.move(to: NSPoint(x: sx, y: syTop))
            path.curve(to: NSPoint(x: tx, y: tyTop),
                       controlPoint1: NSPoint(x: cx, y: syTop),
                       controlPoint2: NSPoint(x: cx, y: tyTop))
            path.line(to: NSPoint(x: tx, y: tyTop - band))
            path.curve(to: NSPoint(x: sx, y: syTop - band),
                       controlPoint1: NSPoint(x: cx, y: tyTop - band),
                       controlPoint2: NSPoint(x: cx, y: syTop - band))
            path.close()

            palette[index % palette.count].withAlphaComponent(0.45).setFill()
            path.fill()
        }

        // 节点与标签
        let font = NSFont.systemFont(ofSize: 10)
        for node in nodes {
            guard let p = placement[node] else { continue }
            let rect = NSRect(x: p.x, y: p.y - p.h, width: nodeWidth, height: max(3, p.h))
            let nodePath = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
            nodePath.fill()

            let depth = depths[node] ?? 0
            let isLast = depth == maxDepth
            let label = "\(node)  \(format(nodeTotal[node] ?? 0))"
            let size = (label as NSString).size(withAttributes: [.font: font])
            let labelX = isLast ? rect.minX - size.width - 6 : rect.maxX + 6
            (label as NSString).draw(
                at: NSPoint(x: labelX, y: rect.midY - size.height / 2),
                withAttributes: [.font: font, .foregroundColor: NSColor.labelColor]
            )
        }

        return image
    }

    // MARK: - 辅助

    private static func orderedNodes(_ links: [Link]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for link in links {
            if seen.insert(link.source).inserted { result.append(link.source) }
            if seen.insert(link.target).inserted { result.append(link.target) }
        }
        return result
    }

    /// 拓扑深度（从源出发的最长路径层数）。
    private static func nodeDepths(links: [Link], nodes: [String]) -> [String: Int] {
        var depth: [String: Int] = [:]
        for node in nodes { depth[node] = 0 }
        // 迭代松弛（图规模小，足够）
        for _ in 0..<nodes.count {
            var changed = false
            for link in links {
                let candidate = (depth[link.source] ?? 0) + 1
                if candidate > (depth[link.target] ?? 0) {
                    depth[link.target] = candidate
                    changed = true
                }
            }
            if !changed { break }
        }
        return depth
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value.rounded())) : String(format: "%.1f", value)
    }
}
