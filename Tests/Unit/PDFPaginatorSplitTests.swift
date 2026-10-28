import AppKit
import PDFKit
import Testing
@testable import Markable

/// 超高内容块（长代码块 / 跨页表格）的**块内切点**行为。
///
/// 背景：`PDFPaginator` 已按内容块边界分页；单个块高于内容区时过去只能按内容区高度
/// 硬切，会把代码行 / 表格行切成两半。现在：
/// - JS 只在块高 > 内容区高度时额外采集内部切点：`pre` 的行间切点、`table` 的 `tr` 底边；
/// - 规划器在超高块内优先切在「能放进本页的最后一个」内部切点上；
/// - 内部切点为空或都放不下时（`img` / `svg`、单行超高代码）仍回退按内容区高度硬切。
///
/// 文本断言只用 ASCII 标记（`LINE-01` / `TAIL-01` / `ROW-01` / `VAL-01`）：
/// WebKit 的中文文本层会把部分常用字映射成康熙部首（`页` → `⻚`），
/// 那与分页无关，但会让中文断言变脆。
@MainActor
@Suite("PDFPaginator 超高块内部切点", .serialized)
struct PDFPaginatorSplitTests {
    private static let pageSetup = PageSetup(paper: .a4, marginMM: 20)

    /// 内容区高度（点）= 纸高 − 上下边距，与 `PDFPaginator` 内部算法一致。
    private static var contentHeight: CGFloat {
        let paper = pageSetup.paper.pointSize
        let margin = CGFloat(pageSetup.marginMM) * 72.0 / 25.4
        return paper.height - margin * 2
    }

    // MARK: - 规划器纯函数（不依赖 WebKit）

    /// 3.4 倍页高的 `pre` 块 + 每 10pt 一个行边界：切点必须全部落在传入的行边界上。
    ///
    /// 构造：内容区 100，代码块 0–340（34 行，每行 10pt），行边界 10/20/…/340。
    /// 期望 4 页：100 + 100 + 100 + 40，切点 100 / 200 / 300 / 340 全是行边界。
    @Test("超高块的切点落在传入的代码行边界上")
    func plannerCutsAtInternalLineBreaks() {
        let lineHeight: CGFloat = 10
        let lineCount = 34
        let blockBottom = CGFloat(lineCount) * lineHeight
        let breaks = (1...lineCount).map { CGFloat($0) * lineHeight }
        let block = ContentBlock(
            top: 0,
            bottom: blockBottom,
            tag: "pre",
            internalBreaks: breaks
        )

        let plan = PDFPaginationPlanner.plan(
            blocks: [block],
            totalHeight: blockBottom,
            contentHeight: 100,
            maxPages: 10
        )

        #expect(plan.usedBlocks, "有块数组时应走块边界规划")
        #expect(plan.isTruncated == false, "4 页远低于页数上限，不应标记截断")
        #expect(
            plan.slices.map(\.height) == [100, 100, 100, 40],
            "340 高 / 100 内容区 + 行边界应切成 4 页 100+100+100+40，实际 \(plan.slices.map(\.height))"
        )
        #expect(plan.slices.first?.top == 0, "第一页应从文档顶部开始")

        // 每个页切点（每页顶边 + 最后一页底边）都必须命中传入的行边界。
        var cuts: [CGFloat] = plan.slices.dropFirst().map(\.top)
        if let last = plan.slices.last {
            cuts.append(last.top + last.height)
        }
        let allowed = Set(breaks)
        for cut in cuts {
            #expect(
                allowed.contains(where: { abs($0 - cut) <= PDFPaginationPlanner.epsilon }),
                "切点 \(cut) 不在传入的行边界上；本次切点：\(cuts)"
            )
        }
    }

    /// 内部切点为空（`img` 这类不可拆的块）或本页放不下任何一个切点时，回退按内容区高度硬切。
    @Test("内部切点不可用时回退按内容区高度硬切")
    func plannerFallsBackToHardCut() {
        // (a) 没有内部切点：与旧行为一致，250 高 / 100 内容区切 3 页。
        let image = ContentBlock(top: 0, bottom: 250, tag: "img")
        let plain = PDFPaginationPlanner.plan(
            blocks: [image], totalHeight: 250, contentHeight: 100, maxPages: 10
        )
        #expect(plain.slices.map(\.height) == [100, 100, 50], "无内部切点时应按内容区高度硬切")

        // (b) 第一页窗口（0–100）里没有可用切点（150 在窗口外）：第一页仍硬切到 100；
        //     下一页窗口 100–200 里才用得上 150 这个切点。
        let sparse = ContentBlock(
            top: 0,
            bottom: 250,
            tag: "pre",
            internalBreaks: [150, 250]
        )
        let mixed = PDFPaginationPlanner.plan(
            blocks: [sparse], totalHeight: 250, contentHeight: 100, maxPages: 10
        )
        #expect(
            mixed.slices.map(\.height) == [100, 50, 100],
            "本页无可用内部切点时应只在那一页硬切，实际 \(mixed.slices.map(\.height))"
        )
    }

    // MARK: - 端到端：长代码块

    /// 40 行代码块约 1189pt > 内容区约 728.5pt：应切成多页，且每行代码完整。
    ///
    /// 断言的思路：
    /// - 每页出现的 `LINE-xx` 必须同时出现行尾标记 `TAIL-xx`（行没被切断）；
    /// - 每行在全文里只出现一次（若硬切落在行中间，同一行会被两页各渲染一次）；
    /// - 第二页起点不能正好是内容区高度（那说明仍在硬切，而不是切在行边界上）。
    @Test("40 行超高代码块跨页后每行仍完整")
    func oversizedCodeBlockSplitsBetweenLines() async throws {
        _ = NSApplication.shared

        let paginated = try await PDFPaginator().paginate(
            html: Self.longCodeHTML(),
            pageSetup: Self.pageSetup
        )
        let document = paginated.document

        #expect(paginated.usedBlockLayout, "内容块边界采集应成功，实际走了等分回退")
        #expect(
            document.pageCount >= 2,
            "40 行代码块放不进一页，应切多页，实际 \(document.pageCount) 页"
        )

        // 硬切时第一页必然正好切在内容区高度；切在行边界上则不会（行距约 29.3pt）。
        if paginated.pageOffsets.count > 1 {
            #expect(
                abs(paginated.pageOffsets[1] - Self.contentHeight) > 1,
                "第二页起点 \(paginated.pageOffsets[1]) 等于内容区高度 \(Self.contentHeight)，说明仍在按内容区高度硬切"
            )
        }

        var seen: [String: Int] = [:]
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index), "缺少第 \(index + 1) 页")
            let text = page.string ?? ""
            let heads = Self.marks(in: text, prefix: "LINE-", digits: 2)
            let tails = Self.marks(in: text, prefix: "TAIL-", digits: 2)
            #expect(
                heads == tails,
                "第 \(index + 1) 页代码行首尾标记不配对（行被切断）：行首 \(heads.sorted()) / 行尾 \(tails.sorted())"
            )
            for number in heads {
                seen[number, default: 0] += 1
            }
        }

        // 文本守恒：40 行都在，且每行只出现一次。
        let expected = Set((1...40).map { String(format: "%02d", $0) })
        #expect(
            Set(seen.keys) == expected,
            "代码行缺失：\(Set(seen.keys).symmetricDifference(expected).sorted())"
        )
        #expect(
            seen.values.allSatisfy { $0 == 1 },
            "代码行被重复渲染（硬切落在行中间）：\(seen.filter { $0.value > 1 }.sorted { $0.key < $1.key })"
        )
    }

    // MARK: - 端到端：跨页表格

    /// 10 行表格高约 1100pt > 内容区约 728.5pt：切点必须落在 `tr` 边界上，页面文本不出现半行。
    @Test("10 行超高表格跨页时切在 tr 边界上")
    func oversizedTableSplitsAtRowBoundaries() async throws {
        _ = NSApplication.shared

        let paginated = try await PDFPaginator().paginate(
            html: Self.longTableHTML(),
            pageSetup: Self.pageSetup
        )
        let document = paginated.document

        #expect(paginated.usedBlockLayout, "内容块边界采集应成功，实际走了等分回退")
        #expect(
            document.pageCount >= 2,
            "10 行表格放不进一页，应切多页，实际 \(document.pageCount) 页"
        )

        // 硬切时第一页正好切在内容区高度；tr 边界（行高约 111pt）不会与之重合。
        if paginated.pageOffsets.count > 1 {
            #expect(
                abs(paginated.pageOffsets[1] - Self.contentHeight) > 1,
                "第二页起点 \(paginated.pageOffsets[1]) 等于内容区高度 \(Self.contentHeight)，说明仍在按内容区高度硬切"
            )
        }

        var seen: [String: Int] = [:]
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index), "缺少第 \(index + 1) 页")
            let text = page.string ?? ""
            let rows = Self.marks(in: text, prefix: "ROW-", digits: 2)
            let values = Self.marks(in: text, prefix: "VAL-", digits: 2)
            #expect(
                rows == values,
                "第 \(index + 1) 页表格行首尾标记不配对（行被切断）：行首 \(rows.sorted()) / 行尾 \(values.sorted())"
            )
            #expect(
                Self.marks(in: text, prefix: "CELL-", digits: 2) == rows,
                "第 \(index + 1) 页同一 tr 的两个单元格被分到了两页"
            )
            for number in rows {
                seen[number, default: 0] += 1
            }
        }

        // 10 行都在，且每行只出现一次。
        let expected = Set((1...10).map { String(format: "%02d", $0) })
        #expect(
            Set(seen.keys) == expected,
            "表格行缺失：\(Set(seen.keys).symmetricDifference(expected).sorted())"
        )
        #expect(
            seen.values.allSatisfy { $0 == 1 },
            "表格行被重复渲染（切点不在 tr 边界上）：\(seen.filter { $0.value > 1 }.sorted { $0.key < $1.key })"
        )
    }

    // MARK: - 测试素材

    /// 抽取 `LINE-01` 这类标记的编号（前缀后紧跟固定 `digits` 位数字）。
    private static func marks(in text: String, prefix: String, digits: Int) -> Set<String> {
        var result: Set<String> = []
        var rest = Substring(text)
        while let range = rest.range(of: prefix) {
            let tail = rest[range.upperBound...]
            let number = tail.prefix(digits)
            if number.count == digits, number.allSatisfy(\.isNumber) {
                result.insert(String(number))
            }
            rest = tail
        }
        return result
    }

    /// 40 行代码块：每行 `LINE-xx TAIL-xx`，CSS 16pt 字号 / 22pt 行高
    /// （WebKit 按 4/3 换算成 CSS px，约 29.3pt 行距）→ 整块约 1189pt。
    private static func longCodeHTML() -> String {
        var code = ""
        for line in 1...40 {
            let number = String(format: "%02d", line)
            code += "LINE-\(number) TAIL-\(number)\n"
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { margin: 0; }
        pre { margin: 0; padding: 8px 10px; background: #f6f8fa; border-radius: 6px;
              font-family: Menlo, monospace; font-size: 16pt; line-height: 22pt;
              white-space: pre; }
        </style></head><body><pre>\(code)</pre></body></html>
        """
    }

    /// 10 行表格：每行高约 111pt（90pt 单元格 + 内边距 + 边框）→ 整表约 1110pt。
    private static func longTableHTML() -> String {
        var rows = ""
        for row in 1...10 {
            let number = String(format: "%02d", row)
            rows += "<tr><td><div class=\"cell\">ROW-\(number) VAL-\(number)</div></td>"
            rows += "<td><div class=\"cell\">CELL-\(number)</div></td></tr>\n"
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { margin: 0; font-family: -apple-system, sans-serif; font-size: 11pt; }
        table { border-collapse: collapse; width: 100%; }
        td { border: 1px solid #cccccc; padding: 10px; }
        .cell { height: 90px; line-height: 90px; font-size: 16pt; }
        </style></head><body><table><tbody>\(rows)</tbody></table></body></html>
        """
    }

    // MARK: - 图片块（限高后不再硬切）

    /// 图片块高度等于内容区高度：它前面还有一段文字时，图片应整体推到下一页，
    /// 而不是从中间被切断。
    ///
    /// 构造：内容区 700；段落 0–300，图片 300–1000（高 700，恰好一页）。
    /// 期望两页：0–300（段落）、300–1000（整张图片，未被切）。
    @Test("图片块放不下当前页剩余空间时整体推到下一页")
    func imageBlockMovesToNextPageWhole() {
        let blocks = [
            ContentBlock(top: 0, bottom: 300, tag: "p"),
            ContentBlock(top: 300, bottom: 1000, tag: "img"),
        ]

        let plan = PDFPaginationPlanner.plan(
            blocks: blocks,
            totalHeight: 1000,
            contentHeight: 700,
            maxPages: 10
        )

        #expect(plan.usedBlocks)
        #expect(plan.slices.count == 2, "应切成两页，实际 \(plan.slices.count) 页")
        #expect(plan.slices.first?.top == 0)
        #expect(plan.slices.first?.height == 300, "第一页应只放段落，实际 \(String(describing: plan.slices.first?.height))")
        #expect(plan.slices.last?.top == 300, "第二页应从图片顶边开始，实际 \(String(describing: plan.slices.last?.top))")
        #expect(plan.slices.last?.height == 700, "第二页应完整容纳 700 高的图片，实际 \(String(describing: plan.slices.last?.height))")
    }

    /// 未限高的超高图片（外部 HTML）：没有内部切点，仍按内容区高度硬切——
    /// 这是保留的已知限制，用测试固定住，避免「图片永不切断」的误解。
    @Test("未限高的超高图片仍按内容区高度硬切")
    func oversizedImageStillHardCuts() {
        let blocks = [ContentBlock(top: 0, bottom: 1400, tag: "img")]

        let plan = PDFPaginationPlanner.plan(
            blocks: blocks,
            totalHeight: 1400,
            contentHeight: 700,
            maxPages: 10
        )

        #expect(plan.slices.count == 2)
        #expect(plan.slices.map(\.height) == [700, 700])
    }
}
