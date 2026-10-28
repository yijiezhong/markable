import Foundation

/// live-preview 决策结果。
/// - `rendered`：应呈现为渲染态的语义片段（保留 kind 供样式映射）；
/// - `sourceParagraph`：光标所在段落，保持可编辑的源码态。
struct LivePreviewPlan: Equatable {
    var rendered: [StyledRange]
    var sourceParagraph: NSRange

    /// 渲染态的范围（便捷访问，供测试与交集判断）。
    var renderedRanges: [NSRange] { rendered.map(\.range) }
}

/// 单视图 WYSIWYM 的核心决策（纯逻辑，便于测试）。
enum LivePreview {
    /// 依据光标位置，把**非光标段落**标记为渲染态，光标所在段落保持源码态。
    /// - Parameter readOnly: 只读（阅读器）模式下，全文一律渲染，无"源码段落"。
    static func plan(text: String, styled: [StyledRange], cursor: NSRange, readOnly: Bool = false) -> LivePreviewPlan {
        if readOnly {
            return LivePreviewPlan(rendered: styled, sourceParagraph: NSRange(location: NSNotFound, length: 0))
        }
        let ns = text as NSString
        // 光标位置可能越界或为 NSNotFound（视图未布局时）——此时视为文档开头，
        // 否则会把"文末段落"误当作光标段落而不渲染。
        let location = cursor.location
        let safeLocation = (location == NSNotFound || location > ns.length) ? 0 : max(0, location)
        let paragraph = ns.paragraphRange(for: NSRange(location: safeLocation, length: 0))
        let rendered = styled.filter { NSIntersectionRange($0.range, paragraph).length == 0 }
        return LivePreviewPlan(rendered: rendered, sourceParagraph: paragraph)
    }
}
