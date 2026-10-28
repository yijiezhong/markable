import AppKit
import PDFKit
import Testing
@testable import Markable

/// 内置 PDF 分页的「按内容块边界切页」行为。
///
/// 断言只用 ASCII 标记（`PARA-001` / `END-001` / `HEAD-001` / `CODE-BEGIN`）：
/// WebKit 写出的中文文本层会把部分常用字映射成康熙部首 / 兼容字符
/// （`页` → `⻚`、`一` → `⼀`），那与分页无关，但会让中文断言变脆。
@MainActor
@Suite("PDFPaginator 按块边界分页", .serialized)
struct PDFPaginatorLayoutTests {
    private static let pageSetup = PageSetup(paper: .a4, marginMM: 20)

    /// 内容区高度（点）= 纸高 − 上下边距，与 `PDFPaginator` 内部算法一致。
    private static var contentHeight: CGFloat {
        let paper = pageSetup.paper.pointSize
        let margin = CGFloat(pageSetup.marginMM) * 72.0 / 25.4
        return paper.height - margin * 2
    }

    /// 跨页表格：第 2 页应从数据行开始，且页顶重复表头，否则数据行没有列名可对照。
    ///
    /// 断言只用 ASCII：中文文本层会被 WebKit 写成康熙部首。
    @Test("跨页表格在后续页面重复表头")
    func wideTableRepeatsHeaderOnLaterPages() async throws {
        _ = NSApplication.shared

        var rows = ""
        for index in 1...40 {
            rows += "<tr><td>ROW-\(String(format: "%03d", index))</td><td>VALUE-\(String(format: "%03d", index))</td></tr>"
        }
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { margin: 0; font: 12px -apple-system; }
        table { border-collapse: collapse; }
        th, td { border: 1px solid #999; padding: 4px 8px; }
        </style></head><body>
        <table><thead><tr><th>HDR-COL-A</th><th>HDR-COL-B</th></tr></thead>
        <tbody>\(rows)</tbody></table>
        </body></html>
        """

        let paginated = try await PDFPaginator().paginate(html: html, pageSetup: Self.pageSetup)
        let document = paginated.document
        #expect(document.pageCount >= 2, "40 行表格应跨页，实际 \(document.pageCount) 页")
        #expect(paginated.repeatedTableHeaders >= 1, "应有页面重复表头，实际 \(paginated.repeatedTableHeaders)")

        guard document.pageCount >= 2, let second = document.page(at: 1) else {
            Issue.record("缺少第 2 页")
            return
        }
        let secondText = second.string ?? ""
        #expect(secondText.contains("HDR-COL-A"), "第 2 页应重复表头，实际文本：\(secondText.prefix(200))")
        #expect(secondText.contains("HDR-COL-B"))
        // 数据行仍在第 2 页（表头不是把整页换成表头）。
        #expect(secondText.contains("ROW-"), "第 2 页应包含数据行")
    }

    // MARK: - 端到端：块边界分页

    /// 18 组「标题 + 段落」+ 一个整体代码块，约 3 页 A4。
    ///
    /// 断言的思路（对应要求里的三种伪影）：
    /// - **段落被切断**：同一页出现的 `PARA-nnn` 必须同时出现 `END-nnn`；
    /// - **代码块被切断**：同一页出现 `CODE-BEGIN` 就必须出现 `CODE-END`；
    /// - **标题孤行**：标题必须和它引出的首段同页，且页尾最后一行不能是标题。
    ///
    /// 注：要求里写的是「页面文本首行不是标题」，但按本实现的避让策略，标题被推到
    /// 下一页时下一页首行**恰恰是**标题——那正是正确结果。所以这里检测的是
    /// 「页尾不是标题」+「标题与首段同页」这两个真正等价的条件。
    @Test("段落与代码块不被切断，页尾不留孤立标题")
    func blockBoundaryPaginationKeepsBlocksWhole() async throws {
        _ = NSApplication.shared

        let paginated = try await PDFPaginator().paginate(
            html: Self.layoutHTML(),
            pageSetup: Self.pageSetup
        )
        let document = paginated.document

        #expect(paginated.usedBlockLayout, "内容块边界采集应成功，实际走了等分回退")
        #expect(document.pageCount >= 2, "内容应切成多页，实际 \(document.pageCount) 页")

        var allParas: Set<String> = []
        var allEnds: Set<String> = []
        var allHeads: Set<String> = []

        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index), "缺少第 \(index + 1) 页")
            let text = page.string ?? ""
            let paras = Self.marks(in: text, prefix: "PARA-")
            let ends = Self.marks(in: text, prefix: "END-")
            let heads = Self.marks(in: text, prefix: "HEAD-")
            allParas.formUnion(paras)
            allEnds.formUnion(ends)
            allHeads.formUnion(heads)

            // (a) 段落完整：本页出现的每个段落开头，其结尾也必须在本页。
            #expect(
                paras.isSubset(of: ends),
                "第 \(index + 1) 页把段落切断了：\(paras.subtracting(ends).sorted())"
            )

            // (b) 代码块是原子块：BEGIN 与 END 必须同页。
            if text.contains("CODE-BEGIN") {
                #expect(text.contains("CODE-END"), "第 \(index + 1) 页把代码块切断了")
            }

            // (c) 标题不孤行：标题必须与它引出的首段同页。
            for head in heads {
                #expect(
                    paras.contains(head),
                    "第 \(index + 1) 页的标题 HEAD-\(head) 与首段 PARA-\(head) 被分到了两页"
                )
            }

            // (d) 页尾最后一行不能是标题：标题落在页尾就是孤行（内容全在下一页）。
            let lastLine = text.split(separator: "\n").last.map(String.init) ?? ""
            #expect(
                !lastLine.contains("HEAD-"),
                "第 \(index + 1) 页以标题收尾（孤行标题）：\(lastLine)"
            )
        }

        // (e) 文本总量守恒：18 个标题 / 18 个段落开头 / 18 个段落结尾，一个不多一个不少。
        let expected = Set((1...18).map { String(format: "%03d", $0) })
        #expect(allHeads == expected, "标题缺失或重复：\(allHeads.symmetricDifference(expected).sorted())")
        #expect(allParas == expected, "段落开头缺失或重复：\(allParas.symmetricDifference(expected).sorted())")
        #expect(allEnds == expected, "段落结尾缺失或重复：\(allEnds.symmetricDifference(expected).sorted())")
    }

    // MARK: - 回退路径

    /// 采集脚本判定「没有可见块」时（这里用 `visibility: hidden` 的元素撑起高度），
    /// 必须回退到按内容高度等分切：页数 = ceil(总高 / 内容区高)，不是导不出。
    @Test("JS 边界采集为空时回退到按内容高度等分")
    func fallsBackToEqualSplitWhenNoBlocks() async throws {
        _ = NSApplication.shared

        // visibility: hidden 的元素仍然占布局空间（scrollHeight > 0），
        // 但采集脚本按 visibility 判定不可见 → 块数组为空 → 走等分回退。
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { margin: 0; }
        .hidden { height: 1500px; visibility: hidden; }
        </style></head><body>
        <div class="hidden"><p>HIDDEN-001 这一块整体不可见，不应被采集为内容块。</p></div>
        </body></html>
        """

        let paginated = try await PDFPaginator().paginate(html: html, pageSetup: Self.pageSetup)
        #expect(paginated.usedBlockLayout == false, "采集为空时应回退等分切")

        let expected = Int((paginated.totalHeight / Self.contentHeight).rounded(.up))
        #expect(expected >= 2, "这个 HTML 至少要占 2 页才有验证意义，实际 \(expected) 页")
        #expect(
            paginated.document.pageCount == expected,
            "等分回退页数应为 ceil(总高 / 内容区高) = \(expected)，实际 \(paginated.document.pageCount)"
        )
        #expect(paginated.isTruncated == false, "3 页远低于页数上限，不应标记截断")
    }

    // MARK: - 规划器纯函数（不依赖 WebKit，覆盖切点规则本身）

    /// 内容区 100，块：0–30 / 40–70 / 80–110 / 120–150。
    @Test("切点落在能完整放下的最后一个块底边")
    func plannerCutsAtLastCompleteBlock() throws {
        let blocks = [
            ContentBlock(top: 0, bottom: 30, tag: "p"),
            ContentBlock(top: 40, bottom: 70, tag: "p"),
            ContentBlock(top: 80, bottom: 110, tag: "p"),
            ContentBlock(top: 120, bottom: 150, tag: "pre"),
        ]
        let plan = PDFPaginationPlanner.plan(
            blocks: blocks, totalHeight: 150, contentHeight: 100, maxPages: 10
        )

        #expect(plan.usedBlocks)
        #expect(plan.isTruncated == false)
        #expect(plan.slices.count == 2, "应为 2 页，实际 \(plan.slices.count) 页")

        let first = try #require(plan.slices.first)
        // 第三个块底边 110 超出内容区 100，切点回退到第二个块底边 70。
        #expect(first.top == 0)
        #expect(first.height == 70)

        let second = try #require(plan.slices.last)
        #expect(second.top == 70)
        #expect(second.height == 80)
    }

    /// 页尾最后一块是标题（70–90，页底 100 还剩 10）：标题必须整体推到下一页。
    @Test("页尾标题被整体推到下一页")
    func plannerPushesTrailingHeading() throws {
        let blocks = [
            ContentBlock(top: 0, bottom: 60, tag: "p"),
            ContentBlock(top: 70, bottom: 90, tag: "h2"),
            ContentBlock(top: 100, bottom: 130, tag: "p"),
        ]
        let plan = PDFPaginationPlanner.plan(
            blocks: blocks, totalHeight: 200, contentHeight: 100, maxPages: 10
        )

        #expect(plan.slices.count == 2)
        let first = try #require(plan.slices.first)
        #expect(first.height == 70, "切点应前移到标题顶边 70，实际 \(first.height)")
        let second = try #require(plan.slices.last)
        #expect(second.top == 70, "下一页应从标题开始")
        #expect(second.height == 60, "标题与其后段落应在同一页")
    }

    /// 单个块 0–250 高于内容区 100：只能按内容区高度硬切。
    @Test("超高块按内容区高度硬切")
    func plannerHardCutsOversizedBlock() {
        let plan = PDFPaginationPlanner.plan(
            blocks: [ContentBlock(top: 0, bottom: 250, tag: "pre")],
            totalHeight: 250,
            contentHeight: 100,
            maxPages: 10
        )

        #expect(plan.slices.count == 3, "250 高 / 100 内容区应切 3 页，实际 \(plan.slices.count)")
        #expect(plan.slices.map(\.height) == [100, 100, 50])
    }

    /// 块数组为空 / 页数超限：回退等分，且 `isTruncated` 语义与原实现一致。
    @Test("空块数组回退等分，超页数上限标记截断")
    func plannerFallsBackAndTruncates() {
        let fallback = PDFPaginationPlanner.plan(
            blocks: [], totalHeight: 250, contentHeight: 100, maxPages: 10
        )
        #expect(fallback.usedBlocks == false)
        #expect(fallback.slices.map(\.height) == [100, 100, 50])
        #expect(fallback.isTruncated == false)

        let limited = PDFPaginationPlanner.plan(
            blocks: [], totalHeight: 250, contentHeight: 100, maxPages: 2
        )
        #expect(limited.slices.count == 2)
        #expect(limited.isTruncated, "3 页超过上限 2，应标记截断")
    }

    // MARK: - 标题锚点

    /// 标题锚点：数量、文档顺序、文本（含空白归一化）、同名保留、空标题跳过。
    ///
    /// 这里读的是 DOM 的 `textContent`（不是 PDF 文本层），所以中文标题可以逐字比对——
    /// 这正是 `headingAnchors` 的用途：让「标题 → 页码」映射绕开 WebKit 把汉字写成
    /// 康熙部首（`页` → `⻚`）导致字面匹配失败的问题。
    @Test("采集标题锚点：数量、顺序、文本与源文一致")
    func collectsHeadingAnchors() async throws {
        _ = NSApplication.shared

        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system, "PingFang SC", sans-serif; font-size: 11pt;
               line-height: 1.7; margin: 0; }
        h1 { font-size: 20pt; margin: 0 0 10px 0; }
        h2 { font-size: 15pt; margin: 16px 0 8px 0; }
        p { margin: 0 0 10px 0; }
        </style></head><body>
        <h1>总标题</h1>
        <p>PARA-001 正文。END-001</p>
        <h2>第一节
            说明</h2>
        <p>PARA-002 正文。END-002</p>
        <h2>小结</h2>
        <p>PARA-003 正文。END-003</p>
        <h2>小结</h2>
        <p>PARA-004 正文。END-004</p>
        <h2>   </h2>
        <p>PARA-005 正文。END-005</p>
        </body></html>
        """

        let paginated = try await PDFPaginator().paginate(html: html, pageSetup: Self.pageSetup)
        let anchors = paginated.headingAnchors

        // (a) 数量：1 个 h1 + 3 个 h2；只有空白的 h2 应被跳过。
        #expect(anchors.count == 4, "应采集 4 个标题，实际 \(anchors.count)：\(anchors.map(\.title))")

        // (b) 文本与源文一致：跨行标题的连续空白压成一个空格；同名标题保留两条。
        #expect(anchors.map(\.title) == ["总标题", "第一节 说明", "小结", "小结"])

        // (c) 文档顺序 → top 严格递增，且落在文档范围内（与 pageOffsets 同一坐标系）。
        for index in 1..<anchors.count {
            #expect(
                anchors[index - 1].top < anchors[index].top,
                "第 \(index) 与第 \(index + 1) 个标题的 top 应递增（实际 \(anchors[index - 1].top) → \(anchors[index].top)）"
            )
        }
        for anchor in anchors {
            #expect(
                anchor.top >= 0 && anchor.top < paginated.totalHeight,
                "标题「\(anchor.title)」的 top=\(anchor.top) 超出文档范围 0..<\(paginated.totalHeight)"
            )
        }
    }

    // MARK: - 内联图片（HtmlRenderer 的 data URI 产物）

    /// `HtmlRenderer` 把本地图片内联成 data URI 后，分页器能真正渲染它并撑高文档。
    ///
    /// 判据用**页数**而不是总高：`totalHeight` 至少等于 WKWebView 视口高度（内容区），
    /// 内容很少时也被抬到 728pt，区分不出图片有没有加载。
    /// - 400×900 的图（高于内容区）→ 至少 2 页；
    /// - 同样的 HTML 去掉图片 → 只有 1 页。
    @Test("内联 data URI 图片会撑高文档并分页")
    func inlineDataURIImageRenders() async throws {
        _ = NSApplication.shared

        let image = NSImage(size: NSSize(width: 400, height: 900))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 400, height: 900).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let dataURI = "data:image/png;base64,\(png.base64EncodedString())"

        let withImage = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { margin: 0; }
        </style></head><body><p>IMAGE-TEST</p><img src="\(dataURI)" width="400"></body></html>
        """
        let withImageResult = try await PDFPaginator().paginate(
            html: withImage, pageSetup: Self.pageSetup
        )
        #expect(
            withImageResult.document.pageCount >= 2,
            "900pt 高的内联图片应撑出多页，实际 \(withImageResult.document.pageCount) 页"
        )

        let withoutImage = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { margin: 0; }
        </style></head><body><p>IMAGE-TEST</p></body></html>
        """
        let withoutImageResult = try await PDFPaginator().paginate(
            html: withoutImage, pageSetup: Self.pageSetup
        )
        #expect(
            withoutImageResult.document.pageCount == 1,
            "没有图片时应只有 1 页，实际 \(withoutImageResult.document.pageCount) 页"
        )
    }

    // MARK: - 测试素材

    /// 从文本里抽取 `PARA-001` 这类标记的编号（要求前缀后紧跟固定位数数字）。
    private static func marks(in text: String, prefix: String) -> Set<String> {
        var result: Set<String> = []
        var rest = Substring(text)
        while let range = rest.range(of: prefix) {
            let tail = rest[range.upperBound...]
            let number = tail.prefix(3)
            if number.count == 3, number.allSatisfy(\.isNumber) {
                result.insert(String(number))
            }
            rest = tail
        }
        return result
    }

    /// 18 组「标题 + 段落」+ 一个整体代码块：每段都带 ASCII 首尾标记。
    private static func layoutHTML() -> String {
        var body = ""
        for index in 1...18 {
            let number = String(format: "%03d", index)
            body += "<h2>HEAD-\(number) 小节标题 \(index)</h2>\n"
            body += "<p>PARA-\(number) 这是一段用于验证按内容块边界分页的中文正文，"
            body += "长度足够折行，页面切点应当落在段落与段落之间而不是段落中间。END-\(number)</p>\n"
        }
        var code = "<pre>CODE-BEGIN\n"
        for line in 1...10 {
            code += "CODE-\(String(format: "%02d", line)) sample code line\n"
        }
        code += "CODE-END</pre>\n"
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system, "PingFang SC", sans-serif; font-size: 11pt;
               line-height: 1.7; color: #1f2329; margin: 0; }
        h2 { font-size: 15pt; margin: 18px 0 8px 0; }
        p { margin: 0 0 10px 0; }
        pre { background: #f6f8fa; padding: 8px 10px; margin: 12px 0;
              font-size: 10pt; line-height: 1.5; }
        </style></head><body>\(body)\(code)</body></html>
        """
    }
}
