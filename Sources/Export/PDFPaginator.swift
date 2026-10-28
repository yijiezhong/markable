import Foundation
import PDFKit
import WebKit

/// 分页渲染结果。
struct PaginatedDocument {
    /// 合成后的多页文档：每页尺寸 = 纸张尺寸，内容从页边距开始。
    var document: PDFDocument
    /// 页面内容总高度（CSS px；WKWebView 里 1px ≈ 1pt）。
    var totalHeight: CGFloat
    /// 因单页渲染失败被跳过的逻辑页序号（0-based）。
    var skippedPageIndexes: [Int]
    /// 是否因为超过页数安全上限而截掉了尾部内容。
    var isTruncated: Bool
    /// 是否真的按「内容块边界」分页；false = 边界采集失败 / 为空，走了等分回退。
    var usedBlockLayout: Bool = false
    /// 成功渲染的每页切片相对文档顶部的起点（CSS px），仅用于排查与测试断言。
    var pageOffsets: [CGFloat] = []
    /// 本次导出重复绘制的表格表头数量（跨页表格）。
    var repeatedTableHeaders: Int = 0
    /// 标题目录：按文档顺序采集的 h1–h6 锚点（详见 `HeadingAnchor`）。
    /// JS 采集失败时为空数组（不抛错），分页照常进行。
    var headingAnchors: [HeadingAnchor] = []
}

/// 标题锚点：一个 h1–h6 标题的纯文本与它相对文档顶部的垂直位置。
///
/// 用途：把大纲标题映射到页。`top` 与 `PaginatedDocument.pageOffsets` 是同一坐标系，
/// 二分即可得到该标题落在第几页——不必回查 PDF 文本层，也就绕开了 WebKit 把汉字
/// 写成康熙部首（`页` → `⻚`、`一` → `⼀`）导致中文标题匹配不上的问题。
///
/// 语义：
/// - 按**文档顺序**（DOM 顺序）返回，正常文档流里 `top` 随之递增；
/// - `title` 是 `textContent` 归一化空白后的结果（连续空白压成一个空格并去首尾）；
/// - 空文本标题跳过；同名标题**保留多条**（调用方需要首次出现时取第一条）；
/// - 采集失败时整个数组为空，绝不影响分页。
struct HeadingAnchor: Equatable {
    /// 标题纯文本。
    var title: String
    /// 标题顶边（CSS px ≈ pt，与 `pageOffsets` 同一坐标系）。
    var top: CGFloat
}

/// 一个内容块：页面上的一块可视内容（一段正文、一个标题、整个代码块、整张表格…）。
///
/// 坐标是 CSS px，原点在**文档顶部**、y 向下——与 `document.documentElement.scrollHeight`
/// 和 `WKPDFConfiguration.rect` 是同一坐标系（无窗口的 `WKWebView` 里 1 CSS px = 1 pt，
/// 既有等分分页路径已按这个比例工作）。
struct ContentBlock: Equatable {
    /// 块顶边（相对文档顶部）。
    var top: CGFloat
    /// 块底边（相对文档顶部）。
    var bottom: CGFloat
    /// 小写标签名（`p` / `h2` / `pre` / `img` …）。
    var tag: String
    /// 块**内部**的候选切点（相对文档顶部，自小到大）。
    ///
    /// 只对「块高 > 内容区高度」的块采集：`pre` 是相邻代码行之间（行间隙中点）、
    /// `table` 是 `tr` 行底边，规划器在超高块内优先切在这些边界上，
    /// 避免把一行代码 / 一行表格切成两半。
    /// `img` / `svg` 等无法按内部结构拆分的块保持为空数组（仍按内容区高度硬切）。
    ///
    /// 默认空数组：普通块与手工构造的块（测试）无需关心这个字段。
    var internalBreaks: [CGFloat] = []

    /// 块高度。
    var height: CGFloat { max(0, bottom - top) }

    /// 是否标题块（h1–h6）：页尾孤行检查只认标题。
    var isHeading: Bool { Self.headingTags.contains(tag) }

    private static let headingTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]
}

/// 表格表头信息：跨页时在每页顶部重复表头，避免「表格翻页后不知道哪列是哪列」。
struct TableHeader: Equatable {
    /// 整张表格的上下边界。
    var tableTop: CGFloat
    var tableBottom: CGFloat
    /// 表头行的上下边界。
    var headerTop: CGFloat
    var headerBottom: CGFloat

    var height: CGFloat { max(0, headerBottom - headerTop) }
}

/// 一页的切片计划：从文档顶部偏移 `top` 处切 `height` 高的一段。
struct PageSlice: Equatable {
    var top: CGFloat
    var height: CGFloat
}

/// 分页计划。
struct PaginationPlan: Equatable {
    var slices: [PageSlice]
    /// 是否因页数上限截断了尾部内容。
    var isTruncated: Bool
    /// 是否用了块边界规划（false = 走的等分回退）。
    var usedBlocks: Bool = false
    /// 每页顶部实际预留的表头高度（与 `slices` 一一对应；0 = 本页不重复表头）。
    var headerHeights: [CGFloat] = []
}

/// 分页规划器：把「内容块边界」换算成「每页切点」。
///
/// 纯函数、不碰 WebKit，便于用构造的块数组直接单测切点规则。
/// 所有长度都是 CSS px（= pt）。
enum PDFPaginationPlanner {
    /// 浮点比较容差：WebKit 的布局尺寸常带小数，0.5px 内的差异视为相等。
    static let epsilon: CGFloat = 0.5
    /// 单页最小切片高度：低于它只会得到一张几乎空白的纸（浮点余量），不单独出页。
    static let minimumSliceHeight: CGFloat = 1

    /// 按内容块边界规划页切点。
    ///
    /// 规则（自上而下扫描）：
    /// 1. 页切点取「能完整放进本页的最后一个块的底边」——段落 / 代码块 / 表格不跨页；
    /// 2. 页尾最后一块是标题时，切点前移到标题顶边，把标题整体推到下一页（避免孤立标题）；
    /// 3. 标题就在页顶、紧随块又放不下时，宁可硬切也让标题后面跟着内容（同样避免孤行）；
    /// 4. 单个块高于内容区（长代码块 / 跨页表格 / 大图）时，优先在块内采集的切点
    ///    （代码行 / 表格行底边）里取「能放进本页的最后一个」；内部切点为空或都放不下
    ///    （`img` / `svg`、单行超高代码等）时，才按内容区高度硬切；
    /// 5. 块与块之间的大段空白不单独占页，直接跳过；
    /// 6. `blocks` 为空（采集失败）时回退到 `equalSplitPlan`，保持旧的等分行为。
    static func plan(
        blocks: [ContentBlock],
        totalHeight: CGFloat,
        contentHeight: CGFloat,
        maxPages: Int,
        topHeaderHeight: (CGFloat) -> CGFloat = { _ in 0 }
    ) -> PaginationPlan {
        guard totalHeight.isFinite, totalHeight > 0,
              contentHeight.isFinite, contentHeight > 0,
              maxPages > 0
        else { return PaginationPlan(slices: [], isTruncated: false) }

        let normalized = normalizedBlocks(blocks, totalHeight: totalHeight)
        // 采集失败 / 为空：回退到按内容高度等分切。
        guard !normalized.isEmpty else {
            return equalSplitPlan(
                totalHeight: totalHeight,
                contentHeight: contentHeight,
                maxPages: maxPages
            )
        }

        var slices: [PageSlice] = []
        var headerHeights: [CGFloat] = []
        var pageStart: CGFloat = 0
        var nextIndex = 0
        var isTruncated = false
        var iterations = 0
        // 每次迭代要么出一页、要么跳过一段空白，正常文档远低于这个上限；
        // 超限只可能是逻辑漏洞，直接按截断收尾，避免挂死。
        let iterationLimit = max(64, normalized.count + maxPages + 16)

        while pageStart < totalHeight - minimumSliceHeight {
            iterations += 1
            guard iterations <= iterationLimit else {
                isTruncated = true
                break
            }
            guard slices.count < maxPages else {
                isTruncated = true
                break
            }

            // 跨页表格：本页顶部要重复表头时，可用内容高度相应减少（否则会丢内容）。
            var headerHeight = max(0, topHeaderHeight(pageStart))
            var pageEnd = pageStart + max(minimumSliceHeight, contentHeight - headerHeight)

            // 上一页硬切留下的残余：底边已落在本页起点之内的块直接跳过。
            while nextIndex < normalized.count,
                  normalized[nextIndex].bottom <= pageStart + epsilon {
                nextIndex += 1
            }

            var cursor = nextIndex
            var lastCompleteIndex: Int?
            var firstIntersecting: ContentBlock?
            while cursor < normalized.count {
                let block = normalized[cursor]
                // 起于本页底边之下：本页放不下，留给下一页。
                if block.top >= pageEnd - epsilon { break }
                if firstIntersecting == nil { firstIntersecting = block }
                // 底边越过内容区：切点只能落在它之前。
                if block.bottom > pageEnd + epsilon { break }
                lastCompleteIndex = cursor
                cursor += 1
            }

            var cut: CGFloat
            var followingIndex: Int
            if let lastIndex = lastCompleteIndex {
                let last = normalized[lastIndex]
                followingIndex = lastIndex + 1
                cut = last.bottom
                if last.isHeading {
                    if last.top > pageStart + epsilon {
                        // 标题孤行：切点前移到标题顶边，标题整体推到下一页。
                        cut = last.top
                        followingIndex = lastIndex
                    } else if cursor < normalized.count,
                              normalized[cursor].top < pageEnd - epsilon {
                        // 标题就在页顶、紧随块又放不下：宁可硬切，也让标题后面跟着内容。
                        // 紧随块本身超高时（标题 + 长代码块），同样优先切在它的内部行边界上，
                        // 否则这一次硬切就会落在代码行中间。
                        cut = internalCut(
                            in: normalized[cursor],
                            pageStart: pageStart,
                            pageEnd: pageEnd
                        ) ?? pageEnd
                        followingIndex = cursor
                    }
                }
                if cut <= pageStart + epsilon {
                    // 兜底：页起点必须前进，否则死循环。
                    cut = pageEnd
                    followingIndex = max(followingIndex, lastIndex + 1)
                }
            } else if let first = firstIntersecting {
                if first.top > pageStart + epsilon {
                    // 本页只剩块与块之间的空白：跳过空白，不产生空白页。
                    pageStart = first.top
                    continue
                }
                // 第一个块就比内容区还高（长代码块 / 跨页表格 / 大图）：
                // 优先切在块内采集的行边界上（切点之后的行整行留给下一页）；
                // 内部切点为空或本页放不下任何一个时，按内容区高度硬切。
                var cutPoint: CGFloat? = internalCut(in: first, pageStart: pageStart, pageEnd: pageEnd)
                if cutPoint == nil, headerHeight > 0 {
                    // 表头预留后连一行都放不下：放弃本页表头，用完整高度重算，
                    // 避免把表格行切成两半（切点破坏比缺表头更糟）。
                    headerHeight = 0
                    pageEnd = pageStart + contentHeight
                    cutPoint = internalCut(in: first, pageStart: pageStart, pageEnd: pageEnd)
                }
                cut = cutPoint ?? pageEnd
                followingIndex = nextIndex
            } else if nextIndex < normalized.count,
                      normalized[nextIndex].top > pageStart + epsilon {
                // 本页没有任何块（大段尾部空白）：直接跳到下一块，不产生空白页。
                pageStart = normalized[nextIndex].top
                continue
            } else {
                // 剩余区域没有任何块：内容已排完。
                break
            }

            cut = min(max(cut, pageStart), totalHeight)
            let height = cut - pageStart
            if height >= minimumSliceHeight {
                slices.append(PageSlice(top: pageStart, height: height))
                headerHeights.append(headerHeight)
            }
            pageStart = cut
            nextIndex = min(followingIndex, normalized.count)
        }

        return PaginationPlan(
            slices: slices, isTruncated: isTruncated, usedBlocks: true,
            headerHeights: headerHeights
        )
    }

    /// 在超高块的内部切点里挑「本页能放下的最后一个切点」。
    ///
    /// - `internalBreaks` 是块内代码行 / 表格行的底边（相对文档顶部、升序）；
    /// - 要求切点距页顶超过 `minimumSliceHeight`，避免切出只有浮点余量的空页；
    /// - 允许切点比页底多出 `epsilon`（与「块底边刚好等于页底」的既有容差一致）；
    /// - 返回 nil = 没有可用切点（块内无切点 / 第一行就高于内容区），
    ///   调用方回退到按内容区高度硬切。
    private static func internalCut(
        in block: ContentBlock,
        pageStart: CGFloat,
        pageEnd: CGFloat
    ) -> CGFloat? {
        var best: CGFloat?
        for value in block.internalBreaks {
            guard value.isFinite else { continue }
            guard value > pageStart + minimumSliceHeight else { continue }
            // 已按升序归一化，后续切点只会更远，无需继续扫描。
            guard value <= pageEnd + epsilon else { break }
            best = value
        }
        return best
    }

    /// 按内容区高度等分切（回退路径，与原实现逐字一致）。
    static func equalSplitPlan(
        totalHeight: CGFloat,
        contentHeight: CGFloat,
        maxPages: Int
    ) -> PaginationPlan {
        guard totalHeight.isFinite, totalHeight > 0,
              contentHeight.isFinite, contentHeight > 0,
              maxPages > 0
        else { return PaginationPlan(slices: [], isTruncated: false) }

        let pageTotal = Int((totalHeight / contentHeight).rounded(.up))
        guard pageTotal > 0 else { return PaginationPlan(slices: [], isTruncated: false) }

        let isTruncated = pageTotal > maxPages
        let pageLimit = min(pageTotal, maxPages)
        var slices: [PageSlice] = []
        for page in 0..<pageLimit {
            let top = CGFloat(page) * contentHeight
            let height = min(contentHeight, totalHeight - top)
            // 剩余不足 1pt 时不再切最后一页：浮点余量（totalHeight 恰好等于整数倍
            // 内容高）会多出一张几乎空白的纸，而 1pt 内也放不下任何完整内容。
            guard height >= minimumSliceHeight else { break }
            slices.append(PageSlice(top: top, height: height))
        }
        return PaginationPlan(slices: slices, isTruncated: isTruncated, usedBlocks: false)
    }

    /// 过滤无效块、夹到 `[0, totalHeight]`、按顶边升序（同顶边按底边升序）；
    /// 同时把块内切点夹到块范围内、去掉端点与重复值，保证规划器可以直接顺序扫描。
    private static func normalizedBlocks(
        _ blocks: [ContentBlock],
        totalHeight: CGFloat
    ) -> [ContentBlock] {
        var result: [ContentBlock] = []
        result.reserveCapacity(blocks.count)
        for block in blocks {
            guard block.top.isFinite, block.bottom.isFinite else { continue }
            let top = min(max(block.top, 0), totalHeight)
            let bottom = min(max(block.bottom, 0), totalHeight)
            guard bottom - top >= epsilon else { continue }
            let breaks = normalizedInternalBreaks(block.internalBreaks, top: top, bottom: bottom)
            result.append(
                ContentBlock(top: top, bottom: bottom, tag: block.tag, internalBreaks: breaks)
            )
        }
        result.sort { lhs, rhs in
            lhs.top == rhs.top ? lhs.bottom < rhs.bottom : lhs.top < rhs.top
        }
        return result
    }

    /// 块内切点归一化：只保留有限值、严格落在块内部、升序去重（容差为 `epsilon`）。
    ///
    /// 与块顶 / 块底重合的切点没有拆分意义（切在块顶等于空页、切在块底等价于整块放下），
    /// 直接丢掉；采集阶段 JS 也可能返回重复的行底边。
    private static func normalizedInternalBreaks(
        _ breaks: [CGFloat],
        top: CGFloat,
        bottom: CGFloat
    ) -> [CGFloat] {
        guard !breaks.isEmpty else { return [] }
        var result: [CGFloat] = []
        result.reserveCapacity(breaks.count)
        for value in breaks.sorted() {
            guard value.isFinite else { continue }
            guard value > top + epsilon, value < bottom - epsilon else { continue }
            if let last = result.last, value - last <= epsilon { continue }
            result.append(value)
        }
        return result
    }
}

/// 把长 HTML 切成真正的多页 PDF，页切点尽量落在**内容块边界**上。
///
/// 流程：
/// 1. 用「内容宽度 × 内容区高度」的 `WKWebView` 加载 HTML（不联网，`loadHTMLString`）；
/// 2. 等布局稳定后读 `documentElement.scrollHeight` 得到内容总高；
/// 3. **一次 JS 采集内容块边界** `[{top, bottom, tag, internalBreaks?}]`（CSS px，文档顶部为原点）：
///    只取「叶子级可视块」——容器由内部块代表，`pre` / `table` / `img` 整块计入；
///    块高超过内容区时再采集块内切点（`pre` 的行间切点、`table` 的 `tr` 底边）；
/// 4. `PDFPaginationPlanner` 按块边界算页切点（见其文档注释）；
/// 5. 逐页用 `WKPDFConfiguration.rect` 截取 `[top, +height]`，再 1:1 画到纸张尺寸的页上。
///
/// 每段仍是 WebKit 生成的**矢量 PDF**，文本层完整保留：可搜索、可复制，
/// `PDFTOC`（按文本查页）与 `PDFStamper`（逐页盖章）都能照常工作。
///
/// 回退：JS 采集失败 / 返回为空 / 解析不出块时，按内容高度等分切（旧行为），
/// 任何 HTML 都还能出 PDF；`PaginatedDocument.usedBlockLayout` 标出实际走了哪条路。
///
/// 已知限制：
/// - 超高块中只有 **长代码块（`pre`）与表格（`table`）** 会在行边界上拆分；
///   `img` / `svg` / `canvas` / `video` 等无法按内部结构拆分，仍按内容区高度硬切。
///   **内置导出路径已通过 `HtmlRenderer` 的 `img { max-height }` 把图片限制在内容区高度内**，
///   因此正常 Markdown 里的图片会整块推到下一页、不会被拦腰切断；只有外部直接传入的
///   超高 HTML 块（如手工构造的 `<div>` / 未限高的 `<img>`）才会触发硬切；
/// - 代码块跨页时，切点在相邻行盒之间的**行间隙中点**（`Range.getClientRects` 取得行盒），
///   既不切字形，也不会正好压在 WebKit 裁剪矩形的边界上（切在行盒底边时，后一页的
///   文本层会重复带上该行）；但 `pre` 的背景 / 圆角 / 内边距不会在切口处重复，
///   跨页代码块的两半各自没有独立的内边距（视觉上贴边）；
/// - 表格按 `tr` 切；`rowspan` 横跨的行边界会被跳过（避免把单元格劈开），
///   此时可能退化为按内容区高度硬切；`thead` 不会在每页重复；
/// - 单行高度就超过内容区的代码（超大字号 / 极窄内容区）没有可用行边界，
///   仍按内容区高度硬切；
/// - 块与块之间的外边距落在页底时会变成留白。
///
/// 另注：WebKit 写出的中文文本层会把部分常用字映射成康熙部首 / 兼容字符
/// （`页` → `⻚`、`一` → `⼀`），因此按字面文本匹配的 `PDFTOC` 对中文标题可能查不到
/// 页码。这是 `WKWebView` 的既有行为（旧的 `pdf()` 路径同样如此），与分页无关。
@MainActor
final class PDFPaginator {
    /// 加载与布局稳定的最长等待时间（秒）。本地 HTML 通常 <1s。
    ///
    /// 放宽到 20s 的原因：`swift test` 并行跑多个 PDF 套件时会同时创建多个 `WKWebView`，
    /// CPU/GPU 争抢下首次布局可能超过 8s（实测 11s 才完成），过紧会把正常渲染误判成
    /// `renderFailed`。真实导出（单个 HTML）仍在 1s 内返回，不受影响。
    var loadTimeout: TimeInterval = 20
    /// 单页 `createPDF` 的超时（秒）；WebKit 偶发不回调时跳过该页，避免卡死导出。
    var pageTimeout: TimeInterval = 10
    /// 页数安全上限：超长文档（异常 HTML）不至于把内存和时间吃光。
    var maxPages: Int = 2000

    /// 渲染并合成多页 PDF。全部页失败时抛 `ExportError.renderFailed`。
    func paginate(html: String, pageSetup: PageSetup) async throws -> PaginatedDocument {
        let paper = pageSetup.paper.pointSize
        let margin = CGFloat(pageSetup.marginMM) * 72.0 / 25.4
        let contentWidth = max(1, paper.width - margin * 2)
        let contentHeight = max(1, paper.height - margin * 2)

        // view 的宽 = 内容宽度（让文字按内容区换行），高 = 内容区高度
        // （实测 createPDF 的 rect 可以截取 view 之外的文档区域，无需把 view 拉高到全文）。
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight))
        // 图片在 HtmlRenderer 里已内联为 data: URI，因此不需要 baseURL 访问本地文件
        // （`loadHTMLString` 的 about:blank 页面读 file:// 会被 WebKit 拒绝）。
        webView.loadHTMLString(html, baseURL: nil)

        let measuredHeight = try await measureContentHeight(webView)
        guard measuredHeight.isFinite, measuredHeight > 0 else { throw ExportError.renderFailed }

        // 一次 JS 采集全部内容块边界 + 标题锚点；失败时两者都为空，planner 自动回退等分切。
        // 传入内容区高度：只有块高超过它时才采集块内切点（代码行 / 表格行）。
        let probe = await collectContentBlocks(webView, contentHeight: contentHeight)
        let blocks = probe?.blocks ?? []
        let headingAnchors = probe?.headings ?? []
        // 块坐标与采集时的 scrollHeight 同源，取两者较大值：宁可页底多留白，也不丢内容。
        let totalHeight = max(measuredHeight, probe?.height ?? 0)

        let tables = probe?.tables ?? []
        // 规划器需要知道每页顶部要预留多少表头高度（与渲染阶段同一判据）。
        let headerHeightAt: (CGFloat) -> CGFloat = { top in
            guard let header = tables.first(where: {
                $0.tableTop <= top && top < $0.tableBottom && top >= $0.headerBottom - PDFPaginationPlanner.epsilon
            }) else { return 0 }
            return header.height
        }
        let plan = PDFPaginationPlanner.plan(
            blocks: blocks,
            totalHeight: totalHeight,
            contentHeight: contentHeight,
            maxPages: maxPages,
            topHeaderHeight: headerHeightAt
        )
        guard !plan.slices.isEmpty else { throw ExportError.renderFailed }

        var slices: [PDFDocument] = []
        var headers: [PDFDocument?] = []
        var skipped: [Int] = []
        var pageOffsets: [CGFloat] = []
        var repeatedHeaders = 0
        for (index, slice) in plan.slices.enumerated() {
            // 跨页表格：如果本页从表格中部开始（表头那部分在上一页），就在页顶重复表头，
            // 否则数据行没有列名可对照。
            var headerDocument: PDFDocument?
            let reservedHeader = plan.headerHeights.indices.contains(index) ? plan.headerHeights[index] : 0
            if reservedHeader > 0, let header = tables.first(where: {
                $0.tableTop <= slice.top && slice.top < $0.tableBottom && slice.top >= $0.headerBottom - PDFPaginationPlanner.epsilon
            }) {
                let headerRect = CGRect(x: 0, y: header.headerTop, width: contentWidth, height: header.height)
                headerDocument = try? await renderSlice(webView, rect: headerRect)
            }
            // slice.height 已在规划阶段扣掉表头高度，这里直接截取即可（内容不会丢）。
            let bodyRect = CGRect(x: 0, y: slice.top, width: contentWidth, height: max(1, slice.height))
            do {
                if let rendered = try await renderSlice(webView, rect: bodyRect) {
                    slices.append(rendered)
                    headers.append(headerDocument)
                    if headerDocument != nil { repeatedHeaders += 1 }
                    pageOffsets.append(slice.top)
                } else {
                    skipped.append(index)
                }
            } catch {
                // 单页失败不中断整体，记录后继续下一页。
                skipped.append(index)
            }
        }
        guard !slices.isEmpty else { throw ExportError.renderFailed }
        guard let composed = compose(slices, headers: headers, paper: paper, margin: margin) else {
            throw ExportError.renderFailed
        }
        return PaginatedDocument(
            document: composed,
            totalHeight: totalHeight,
            skippedPageIndexes: skipped,
            isTruncated: plan.isTruncated,
            usedBlockLayout: plan.usedBlocks,
            pageOffsets: pageOffsets,
            repeatedTableHeaders: repeatedHeaders,
            headingAnchors: headingAnchors
        )
    }

    // MARK: - 加载与测量

    /// 等页面加载完成、布局稳定后返回内容总高（`scrollHeight`）。
    ///
    /// 判定「稳定」用连续两次读数一致：字体 / 图片延后到位时高度还会变，
    /// 只等 `isLoading == false` 会拿到过早的高度。
    private func measureContentHeight(_ webView: WKWebView) async throws -> CGFloat {
        let deadline = Date().addingTimeInterval(loadTimeout)
        var previous: CGFloat?

        while Date() < deadline {
            let ready = (try? await webView.evaluateJavaScript("document.readyState")) as? String
            if ready == "complete" {
                let raw = try? await webView.evaluateJavaScript("document.documentElement.scrollHeight")
                // JS 返回非数值 / 0：空文档或页面异常，直接失败（不空等 8 秒）。
                guard let number = raw as? NSNumber, number.doubleValue.isFinite, number.doubleValue > 0 else {
                    throw ExportError.renderFailed
                }
                let height = CGFloat(number.doubleValue)
                if let previous, abs(previous - height) < 0.5 {
                    return height
                }
                previous = height
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        throw ExportError.renderFailed
    }

    /// 一次 JS 采集内容块边界与标题锚点；返回的 `height` 与坐标来自同一次布局读数。
    ///
    /// `contentHeight` 会注入采集脚本：只有块高超过它的块才需要采集块内切点
    /// （代码行 / 表格行底边），普通块不必多算。
    ///
    /// 采集失败（脚本异常 / 返回空 / JSON 解析不出）返回 nil：调用方回退到等分切，
    /// 分页永远不该因为采集失败而导不出 PDF。标题锚点单独失败也不影响分页。
    /// 一次 JS 采集的完整结果：内容总高、内容块、标题锚点、表格表头。
    private struct ProbeResult {
        var height: CGFloat
        var blocks: [ContentBlock]
        var headings: [HeadingAnchor]
        var tables: [TableHeader]
    }

    private func collectContentBlocks(
        _ webView: WKWebView,
        contentHeight: CGFloat
    ) async -> ProbeResult? {
        guard let raw = try? await webView.evaluateJavaScript(
                Self.blockProbeScript(contentHeight: contentHeight)
              ),
              let json = raw as? String,
              let data = json.data(using: .utf8)
        else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any]
        else { return nil }

        let height = (payload["height"] as? NSNumber)?.doubleValue ?? 0
        guard height.isFinite, height > 0 else { return nil }

        let rawBlocks = payload["blocks"] as? [[String: Any]] ?? []
        var blocks: [ContentBlock] = []
        blocks.reserveCapacity(rawBlocks.count)
        for item in rawBlocks {
            guard let top = (item["top"] as? NSNumber)?.doubleValue,
                  let bottom = (item["bottom"] as? NSNumber)?.doubleValue,
                  let tag = item["tag"] as? String,
                  top.isFinite, bottom.isFinite, bottom > top
            else { continue }
            // 块内切点只对超高块出现（JS 只在 height > 内容区高度时返回）；
            // 解析后仍由规划器统一夹取 / 去重，这里只做类型与有限性过滤。
            let rawBreaks = item["internalBreaks"] as? [Any] ?? []
            let breaks = rawBreaks.compactMap { ($0 as? NSNumber)?.doubleValue }
                .filter(\.isFinite)
                .map { CGFloat($0) }
            blocks.append(
                ContentBlock(top: CGFloat(top), bottom: CGFloat(bottom), tag: tag, internalBreaks: breaks)
            )
        }

        let rawHeadings = payload["headings"] as? [[String: Any]] ?? []
        var headings: [HeadingAnchor] = []
        headings.reserveCapacity(rawHeadings.count)
        for item in rawHeadings {
            guard let text = item["text"] as? String,
                  let top = (item["top"] as? NSNumber)?.doubleValue,
                  top.isFinite
            else { continue }
            // JS 已归一化一遍；这里再兜一次，避免不同平台 textContent 带异常空白。
            let title = normalizedHeadingText(text)
            guard !title.isEmpty else { continue }
            headings.append(HeadingAnchor(title: title, top: CGFloat(top)))
        }
        let rawTables = payload["tables"] as? [[String: Any]] ?? []
        var tables: [TableHeader] = []
        tables.reserveCapacity(rawTables.count)
        for item in rawTables {
            guard let top = (item["top"] as? NSNumber)?.doubleValue,
                  let bottom = (item["bottom"] as? NSNumber)?.doubleValue,
                  let headerTop = (item["headerTop"] as? NSNumber)?.doubleValue,
                  let headerBottom = (item["headerBottom"] as? NSNumber)?.doubleValue,
                  top.isFinite, bottom.isFinite, headerTop.isFinite, headerBottom.isFinite,
                  headerBottom > headerTop, bottom > top
            else { continue }
            tables.append(TableHeader(
                tableTop: CGFloat(top), tableBottom: CGFloat(bottom),
                headerTop: CGFloat(headerTop), headerBottom: CGFloat(headerBottom)
            ))
        }

        // 不排序：保持 JS 给的文档顺序（DOM 顺序），正常文档流里 top 自然递增。
        return ProbeResult(
            height: CGFloat(height), blocks: blocks,
            headings: headings, tables: tables
        )
    }

    /// 标题文本兜底归一化：连续空白压成一个空格并去掉首尾。
    private func normalizedHeadingText(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 采集内容块边界与标题锚点的 JS：
    /// 返回 `{ height, blocks: [{ top, bottom, tag, internalBreaks? }], headings: [{ text, top }] }`
    /// 的 JSON 字符串。
    ///
    /// 坐标系：`getBoundingClientRect().top + scrollY` = 相对**文档顶部**的 CSS px（y 向下），
    /// 与 `scrollHeight`、`WKPDFConfiguration.rect` 同一坐标系；无窗口 WKWebView 里
    /// 1 CSS px = 1 pt，可以直接和 pageSetup 的点尺寸比较。
    ///
    /// 「叶子级可视块」的取法：
    /// - 原子块（`pre` / `table` / `img` / `svg` / `hr` / `video` …）整块计入，内部不再下钻，
    ///   所以代码行、表格单元格永远不会成为页切点；
    /// - 纯容器（`div` / `section` / `ul` / `ol` / `blockquote` …）若内部还有可见块级子元素，
    ///   就由内部子块代表，避免同一片区域被重复计入；
    /// - 带直接文字的元素（`<p>文字<img>` 这类混合内容）整体计入，否则文字部分会漏采。
    ///
    /// 超高块的**内部切点**（只在块高 > 内容区高度时采集，见 `record`）：
    /// - `pre`：遍历块内文本节点、用 `Range.getClientRects()` 取每行文本的客户区矩形，
    ///   按行合并同一行的多个片段（语法高亮会把一行拆成多个 span），
    ///   切点取相邻两行**行间隙的中点**——切在行与行之间的空白里，既不切字形，
    ///   也不会正好压在 WebKit 裁剪矩形的边界上（实测切在行盒底边时，后一页的
    ///   文本层仍会带上该行）；
    /// - `table`：取 `table.rows`（只含本表格自己的行，不含嵌套表格）每个 `tr` 的底边；
    ///   `rowspan > 1` 单元格跨过的行边界会被跳过，避免把单元格劈成两半；
    /// - `img` / `svg` / `canvas` / `video` 等没有可拆分的内部结构，不返回切点，
    ///   规划器对它们按内容区高度硬切。
    ///
    /// `headings` 独立按 `querySelectorAll('h1,…,h6')` 的**文档顺序**采集（不复用 `blocks`，
    /// 因为标题若含块级子元素会被下钻而不出现在叶子块里）；`text` 是 `textContent` 去掉
    /// 连续空白后的纯文本，`top` 与 `blocks` 同源。
    private static func blockProbeScript(contentHeight: CGFloat) -> String {
        // 注入 JS 的内容区高度阈值（pt）。`String(format:)` 不本地化小数点，
        // 4 位小数对 pt 级布局足够，也保证输出一定是合法的 JS 数字字面量。
        let limit = String(format: "%.4f", Double(max(0, contentHeight)))
        return BlockProbeScript.preamble(limit: limit)
            + BlockProbeScript.breakCollectors
            + BlockProbeScript.emit
    }

    // MARK: - 单页渲染

    /// 截取 `rect` 范围渲染成一页 PDF；失败返回 nil（由调用方记录并跳过）。
    private func renderSlice(_ webView: WKWebView, rect: CGRect) async throws -> PDFDocument? {
        let configuration = WKPDFConfiguration()
        // rect 使用 view 坐标（原点在内容区左上角、y 向下），与 scrollHeight / 块坐标同一坐标系。
        configuration.rect = rect
        let data = try await createPDF(webView, configuration: configuration)
        guard let document = PDFDocument(data: data), document.pageCount > 0 else { return nil }
        return document
    }

    /// WebKit 只提供 completion 版本，包成 async；并加超时防止偶发不回调挂死。
    private func createPDF(_ webView: WKWebView, configuration: WKPDFConfiguration) async throws -> Data {
        let timeout = pageTimeout
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let resumer = ResumeOnce(continuation)
            webView.createPDF(configuration: configuration) { result in
                resumer.resume(with: result)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                resumer.resume(throwing: ExportError.renderFailed)
            }
        }
    }

    // MARK: - 合成

    /// 把每页切片 1:1 画到纸张尺寸的 PDF 页上：水平从左边距开始，垂直从内容区顶部开始。
    ///
    /// 每页都从内容区顶部重新开始（不是第 N 页就往下挪 N 个内容区），因为每张纸
    /// 独立承载一段内容——这正是分页与长图的区别。最后一页不足一屏时底部留白。
    private func compose(_ slices: [PDFDocument], headers: [PDFDocument?], paper: CGSize, margin: CGFloat) -> PDFDocument? {
        let contentWidthSize = max(1, paper.width - margin * 2)
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: paper)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            return nil
        }

        for (index, slice) in slices.enumerated() {
            guard let page = slice.page(at: 0) else { continue }
            let pageBounds = page.bounds(for: .mediaBox)
            guard pageBounds.width > 0, pageBounds.height > 0 else { continue }

            context.beginPDFPage(nil)
            // 白底：截取页本身是透明背景，直接叠到纸面上会露出阅读器的深色底。
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(box)

            // 页面坐标 y 向上：内容区顶部 = 纸高 − 上边距，向下画。
            var cursor = box.height - margin
            // 跨页表格：先把表头画在内容区顶部，正文紧接着往下排。
            if index < headers.count, let headerPage = headers[index]?.page(at: 0) {
                let headerBounds = headerPage.bounds(for: .mediaBox)
                if headerBounds.height > 0 {
                    context.saveGState()
                    context.translateBy(x: margin, y: cursor - headerBounds.height)
                    headerPage.draw(with: .mediaBox, to: context)
                    context.restoreGState()
                    cursor -= headerBounds.height
                    // 接缝美化：表头切片底边与正文切片顶边各有一条边框线，直接拼接会叠成
                    // 双线/粗线；用与表格边框同色（HtmlRenderer 的 #cbd5e1）的 1px 线覆盖，
                    // 视觉上与表格内部行分隔线一致。
                    context.setFillColor(CGColor(srgbRed: 0xCB / 255, green: 0xD5 / 255, blue: 0xE1 / 255, alpha: 1))
                    context.fill(CGRect(x: margin, y: cursor - 0.5, width: contentWidthSize, height: 1))
                }
            }
            let bottom = cursor - pageBounds.height
            context.saveGState()
            context.translateBy(x: margin, y: bottom)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()

        guard !data.isEmpty else { return nil }
        return PDFDocument(data: data as Data)
    }
}

/// 保证 continuation 只被 resume 一次：`createPDF` 回调与超时任务可能先后到达，
/// 二次 resume 会让进程直接崩溃。
@MainActor
private final class ResumeOnce {
    private var continuation: CheckedContinuation<Data, Error>?

    init(_ continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    func resume(throwing error: Error) {
        resume(with: .failure(error))
    }
}

/// 内容块采集脚本（注入 JS）的分段拼装。
///
/// `PDFPaginator.blockProbeScript(contentHeight:)` 按顺序拼接这三段，逐字节还原拆分前的
/// 脚本文本：分段只为把超长函数体拆小，脚本内容、顺序与换行都没有任何改动。
private enum BlockProbeScript {
    /// 第 1 段：脚本常量、元素测量与可见性判定，以及行盒合并（`mergeLineBoxes`）。
    ///
    /// `limit` 是注入的内容区高度阈值（pt）：块高超过它才采集块内切点。
    static func preamble(limit: String) -> String {
        #"""
        (function () {
          var ATOMIC = {
            PRE: 1, TABLE: 1, IMG: 1, SVG: 1, HR: 1,
            VIDEO: 1, CANVAS: 1, IFRAME: 1, OBJECT: 1, EMBED: 1
          };
          // 内容区高度（pt）：块高超过它才需要采集块内切点；由 Swift 侧注入。
          var CONTENT_HEIGHT = \#(limit);
          var scrollY = window.scrollY || document.documentElement.scrollTop || 0;
          var out = [];

          function measure(el) {
            var rect = el.getBoundingClientRect();
            return {
              top: rect.top + scrollY,
              bottom: rect.bottom + scrollY,
              height: rect.height
            };
          }

          function isVisible(el) {
            var style = window.getComputedStyle(el);
            if (!style) return false;
            if (style.display === 'none' || style.visibility === 'hidden') return false;
            if (parseFloat(style.opacity) === 0) return false;
            return measure(el).height > 0.5;
          }

          function hasDirectText(el) {
            for (var i = 0; i < el.childNodes.length; i++) {
              var node = el.childNodes[i];
              if (node.nodeType === 3 && node.nodeValue && node.nodeValue.trim().length > 0) return true;
            }
            return false;
          }

          function hasVisibleBlockChild(el) {
            for (var i = 0; i < el.children.length; i++) {
              var child = el.children[i];
              var style = window.getComputedStyle(child);
              if (!style) continue;
              if (style.display === 'none' || style.visibility === 'hidden') continue;
              var display = style.display;
              if (display === 'inline' || display === 'contents') continue;
              if (display === 'inline-block' || display === 'inline-flex' || display === 'inline-grid') {
                if (hasVisibleBlockChild(child)) return true;
                continue;
              }
              return true;
            }
            return false;
          }

          // 合并同一行的多个文本片段：垂直区间重叠超过较矮者一半就视为同一行。
          // 语法高亮把一行切成多个 span 时，同一行会返回多个 top 相同的矩形。
          function mergeLineBoxes(boxes) {
            boxes.sort(function (a, b) { return a.top - b.top; });
            var lines = [];
            var current = null;
            for (var i = 0; i < boxes.length; i++) {
              var box = boxes[i];
              if (!current) {
                current = { top: box.top, bottom: box.bottom };
                continue;
              }
              var overlap = Math.min(current.bottom, box.bottom) - Math.max(current.top, box.top);
              var shorter = Math.min(current.bottom - current.top, box.bottom - box.top);
              if (shorter > 0 && overlap >= shorter * 0.5) {
                current.top = Math.min(current.top, box.top);
                current.bottom = Math.max(current.bottom, box.bottom);
              } else {
                lines.push(current);
                current = { top: box.top, bottom: box.bottom };
              }
            }
            if (current) lines.push(current);
            return lines;
          }

        """#
    }

    /// 第 2 段：超高块的内部切点采集（`pre` 行间隙中点 / 表格行底边）。
    static var breakCollectors: String {
        #"""
          // `pre` 的代码行切点：每行文字一个 Range 矩形，合并成视觉行后，
          // 取相邻两行之间的**行间隙中点**（既切不到字形，也不会正好压在
          // WebKit 裁剪矩形的边界上——实测切在行盒底边时，后一页文本层仍会
          // 带上这一行）。行间隙不足 0.5px（行距过密）时跳过该切点。
          // 返回空数组 = 取不到行矩形（例如 pre 里只有图），上层按内容区高度硬切。
          function preLineBreaks(pre) {
            var boxes = [];
            var walker = document.createTreeWalker(pre, NodeFilter.SHOW_TEXT, null);
            var node;
            while ((node = walker.nextNode())) {
              if (!node.nodeValue || !node.nodeValue.replace(/\s+/g, '').length) continue;
              var range = document.createRange();
              range.selectNodeContents(node);
              var rects = range.getClientRects();
              for (var i = 0; i < rects.length; i++) {
                var rect = rects[i];
                if (!isFinite(rect.top) || !isFinite(rect.bottom)) continue;
                if (rect.height <= 0.5) continue;
                boxes.push({ top: rect.top + scrollY, bottom: rect.bottom + scrollY });
              }
              if (range.detach) range.detach();
            }
            var lines = mergeLineBoxes(boxes);
            var breaks = [];
            for (var j = 0; j + 1 < lines.length; j++) {
              var gap = lines[j + 1].top - lines[j].bottom;
              if (gap < 0.5) continue;
              breaks.push(lines[j].bottom + gap / 2);
            }
            return breaks;
          }

          // 表格行底边：`table.rows` 只含本表格自己的行（不含嵌套表格）。
          // `rowspan > 1` 的单元格跨过的行边界不能切，标记为 unsafe 后跳过；
          // 最后一行的底边同样不产出（贴近表格底部边框）。
          function tableRowBreaks(table) {
            var rows = table.rows;
            if (!rows || rows.length < 2) return [];
            var bottoms = [];
            var unsafe = [];
            var i;
            for (i = 0; i < rows.length; i++) {
              bottoms.push(rows[i].getBoundingClientRect().bottom + scrollY);
              unsafe.push(false);
            }
            for (i = 0; i < rows.length; i++) {
              var cells = rows[i].cells || [];
              for (var c = 0; c < cells.length; c++) {
                var span = cells[c].rowSpan || 1;
                if (span <= 1) continue;
                var lastUnsafe = Math.min(i + span - 1, rows.length - 1);
                for (var r = i; r < lastUnsafe; r++) unsafe[r] = true;
              }
            }
            var breaks = [];
            for (i = 0; i + 1 < rows.length; i++) {
              if (unsafe[i]) continue;
              if (!isFinite(bottoms[i])) continue;
              breaks.push(bottoms[i]);
            }
            return breaks;
          }

          // 只对超高块调用：按标签决定内部切点来源；其它原子块返回空数组。
          function collectInternalBreaks(el, box) {
            var breaks = [];
            try {
              if (el.tagName === 'PRE') breaks = preLineBreaks(el);
              else if (el.tagName === 'TABLE') breaks = tableRowBreaks(el);
            } catch (error) {
              return [];
            }
            // 只保留严格落在块内部的切点，升序去重（容差 0.5px，与 Swift 侧一致）。
            var clean = [];
            for (var i = 0; i < breaks.length; i++) {
              var value = breaks[i];
              if (!isFinite(value)) continue;
              if (value <= box.top + 0.5 || value >= box.bottom - 0.5) continue;
              clean.push(value);
            }
            clean.sort(function (a, b) { return a - b; });
            var unique = [];
            for (var k = 0; k < clean.length; k++) {
              if (unique.length && clean[k] - unique[unique.length - 1] <= 0.5) continue;
              unique.push(clean[k]);
            }
            return unique;
          }

        """#
    }

    /// 第 3 段：叶子块遍历、过滤排序，并输出 `{ height, blocks, headings }` JSON。
    static var emit: String {
        #"""
          function record(el) {
            var box = measure(el);
            var block = {
              top: box.top,
              bottom: box.bottom,
              tag: el.tagName.toLowerCase()
            };
            // 只有块高超过内容区时才采集块内切点：普通块的采集开销与旧版一致。
            // img / svg / canvas / video 没有可拆分的内部结构，返回空数组（硬切）。
            if (box.height > CONTENT_HEIGHT) {
              block.internalBreaks = collectInternalBreaks(el, box);
            }
            out.push(block);
          }

          function walk(el) {
            for (var i = 0; i < el.children.length; i++) {
              var child = el.children[i];
              if (!isVisible(child)) continue;
              if (ATOMIC[child.tagName]) { record(child); continue; }
              if (hasVisibleBlockChild(child) && !hasDirectText(child)) { walk(child); continue; }
              record(child);
            }
          }

          if (document.body) walk(document.body);
          else if (document.documentElement) walk(document.documentElement);

          var blocks = [];
          for (var j = 0; j < out.length; j++) {
            var block = out[j];
            if (!isFinite(block.top) || !isFinite(block.bottom)) continue;
            if (block.bottom - block.top < 0.5) continue;
            blocks.push(block);
          }
          blocks.sort(function (a, b) {
            if (a.top !== b.top) return a.top - b.top;
            return a.bottom - b.bottom;
          });

          // 标题锚点：按文档顺序取全部可见 h1–h6，供上层建立「标题 → 页码」映射。
          // textContent 归一化空白（多行标题在源码里常带换行缩进），空文本标题跳过。
          var headings = [];
          var headingEls = document.querySelectorAll('h1, h2, h3, h4, h5, h6');
          for (var k = 0; k < headingEls.length; k++) {
            var headingEl = headingEls[k];
            if (!isVisible(headingEl)) continue;
            var title = (headingEl.textContent || '').replace(/\s+/g, ' ').trim();
            if (!title) continue;
            headings.push({ text: title, top: measure(headingEl).top });
          }

          // 表格表头：跨页时用于在每页顶部重复表头。
          var tables = [];
          var tableEls = document.querySelectorAll('table');
          for (var q = 0; q < tableEls.length; q++) {
            var tableEl = tableEls[q];
            if (!isVisible(tableEl)) continue;
            var headerRow = null;
            if (tableEl.tHead && tableEl.tHead.rows.length) {
              headerRow = tableEl.tHead.rows[0];
            } else {
              // 没有 thead 时，只有第一行确实是表头（含 th）才重复；
              // 否则会把第一行数据当成表头，在后续页面重复渲染数据行。
              var firstRow = tableEl.querySelector('tr');
              if (firstRow && firstRow.querySelectorAll('th').length > 0) headerRow = firstRow;
            }
            if (!headerRow) continue;
            var tBox = measure(tableEl);
            var hBox = measure(headerRow);
            if (!isFinite(tBox.top) || !isFinite(tBox.bottom)) continue;
            if (!isFinite(hBox.top) || !isFinite(hBox.bottom)) continue;
            if (hBox.bottom - hBox.top < 1 || tBox.bottom - tBox.top < 2) continue;
            tables.push({ top: tBox.top, bottom: tBox.bottom, headerTop: hBox.top, headerBottom: hBox.bottom });
          }

          var height = 0;
          if (document.documentElement) height = Math.max(height, document.documentElement.scrollHeight);
          if (document.body) height = Math.max(height, document.body.scrollHeight);

          return JSON.stringify({ height: height, blocks: blocks, headings: headings, tables: tables });
        })()
        """#
    }
}
