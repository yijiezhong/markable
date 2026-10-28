import AppKit
import Mermaid

/// 用 `swift-mermaid`（纯 Swift，无 WebView）把 Mermaid 源码渲染成 `NSImage`。
enum MermaidRenderer {
    private static var cache: [String: NSImage] = [:]

    /// 已知不支持的类型（Vendor 0.3.0 未实现，Markable 也没有扩展渲染器）。
    /// 顺序：长前缀在前，避免短前缀抢先匹配（如 `requirement` 之于 `requirementdiagram`）。
    ///
    /// 目前**为空**：kanban / treemap(-beta) / venn(-beta) / zenuml / requirement(-Diagram) /
    /// eventmodeling 都由自研渲染器接管，其余类型交给 Vendor。保留这个列表作为未来
    /// 「明确不支持、快速失败」的扩展点，`unsupportedType(of:)` 对未知类型返回 nil。
    static let unsupportedTypes: [String] = []

    /// 源码首行的图类型（小写）；空源码返回空串。
    /// 先剔除 `%%{init}%%` 配置与 `%%` 注释，避免「配置在首行」时分派失效。
    static func headType(of source: String) -> String {
        MermaidSource.stripped(source)
            .split(separator: "\n").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    }

    /// 源码里 `%%{init: ...}%%` 声明的 Mermaid 主题（默认 `.default`）。
    ///
    /// 仅解析、不参与配色：Vendor 渲染器不接受配色注入，自研渲染器跟随系统外观。
    /// 暴露出来是为了让上层（设置面板 / 未来的主题适配）能读到源码声明的意图。
    static func theme(of source: String) -> MermaidSource.Theme {
        MermaidSource.theme(of: source)
    }

    /// 命中已知不支持的类型时返回该类型名，否则 nil。
    static func unsupportedType(of source: String) -> String? {
        let head = headType(of: source)
        return unsupportedTypes.first { head.hasPrefix($0) }
    }

    /// Mermaid 源码 → NSImage；失败返回 nil（调用方回退源码并给出提示）。
    static func image(forSource source: String, scale: CGFloat = 2) -> NSImage? {
        if let cached = cache[source] { return cached }
        // 已知不支持的类型直接快速失败，不让 Vendor 抛错
        if unsupportedType(of: source) != nil { return nil }

        let head = headType(of: source)

        var image: NSImage?
        if head.hasPrefix("gantt") {
            image = GanttRenderer.image(forSource: source)
        } else if head.hasPrefix("mindmap") {
            image = MindmapRenderer.image(forSource: source)
        } else if head.hasPrefix("timeline") {
            image = TimelineRenderer.image(forSource: source)
        } else if head.hasPrefix("xychart") {
            image = XychartRenderer.image(forSource: source)
        } else if head.hasPrefix("quadrantchart") {
            image = QuadrantRenderer.image(forSource: source)
        } else if head.hasPrefix("packet") {
            image = PacketRenderer.image(forSource: source)
        } else if head.hasPrefix("sankey") {
            image = SankeyRenderer.image(forSource: source)
        } else if head.hasPrefix("block") {
            image = BlockRenderer.image(forSource: source)
        } else if head.hasPrefix("kanban") {
            image = KanbanRenderer.image(forSource: source)
        } else if head.hasPrefix("treemap") {
            image = TreemapRenderer.image(forSource: source)
        } else if head.hasPrefix("venn") {
            image = VennRenderer.image(forSource: source)
        } else if head.hasPrefix("zenuml") {
            image = ZenUMLRenderer.image(forSource: source)
        } else if head.hasPrefix("requirement") {
            // `requirement` 是 `requirementdiagram` 的前缀，一个分支同时覆盖两种首行。
            image = RequirementRenderer.image(forSource: source)
        } else if head.hasPrefix("eventmodeling") || head == "tf" {
            image = EventModelingRenderer.image(forSource: source)
        } else if let scene = try? Mermaid.render(MermaidSource.stripped(source)),
                  let cgImage = scene.cgImage(scale: scale) {
            let size = NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
            image = NSImage(cgImage: cgImage, size: size)
        }
        if let image { cache[source] = image }
        return image
    }
}
