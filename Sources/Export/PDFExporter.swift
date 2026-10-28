import Foundation
import PDFKit

/// 导出结果。
struct ExportReport: Equatable {
    var pdfURL: URL
    var hasOutline: Bool
}

/// PDF 导出（T030）：WKWebView 渲染 HTML → PDFKit 写入书签。
/// 契约见 contracts/native-services.md（`PDFExporter`）。
@MainActor
final class PDFExporter {
    /// 把 HTML 渲染为带书签的 PDF 并写到 `url`。
    ///
    /// 正文渲染走 `PDFPaginator`：按内容块边界切成真正的多页（每页 = 纸张点尺寸），
    /// 不再用 `WKWebView.pdf()` 输出单页长图。目录页 / 页眉页脚 / 书签 / 重装写盘
    /// 逻辑保持不变——它们都基于页面文本层，分页后照常工作。
    func export(
        html: String, outline: [OutlineItem], to url: URL,
        pageSetup: PageSetup? = nil, stamp: PDFStamp? = nil,
        title: String = "", includeTOC: Bool = false
    ) async throws -> ExportReport {
        // 没传纸张设置时按默认 A4（20mm 边距）分页，保证输出是标准 A4 点尺寸。
        let paperSetup = pageSetup ?? PageSetup()
        let paginated = try await PDFPaginator().paginate(html: html, pageSetup: paperSetup)
        let resolvedTitle = title.isEmpty ? url.deletingPathExtension().lastPathComponent : title
        // 标题锚点 → 页索引（0-based，分页文档内；同名取首次出现）。不依赖 PDF 文本层。
        let headingPageIndex = Self.headingPageIndex(
            anchors: paginated.headingAnchors,
            offsets: paginated.pageOffsets
        )
        var document = paginated.document
        var tocInserted = false

        // 目录页：插在最前（先插，后盖章，使 {page} 页码与目录一致）
        if includeTOC, let setup = pageSetup,
           let tocPage = PDFTOC.makePage(outline: outline, title: resolvedTitle, pageSetup: setup,
                                         existing: document, pageIndexByHeading: headingPageIndex) {
            document.insert(tocPage, at: 0)
            tocInserted = true
        }

        // 页眉 / 页脚：逐页盖章（烧进 PDF）
        if let stamp, stamp.isEnabled, let setup = pageSetup,
           let stamped = PDFStamper.stamp(document, header: stamp.header, footer: stamp.footer,
                                          title: resolvedTitle, pageSetup: setup) {
            document = stamped
        }

        // WKWebView 生成的 PDF 若直接接 `outlineRoot` 再 write，PDFKit 会把书签**丢掉**
        // （写前有节点、写后读回为空）。把页面重新装进一个新文档再写盘，书签才会持久化。
        let exported = PDFDocument()
        for index in 0..<document.pageCount {
            if let page = document.page(at: index) {
                exported.insert(page, at: exported.pageCount)
            }
        }
        if !outline.isEmpty {
            exported.outlineRoot = buildOutline(
                outline, in: exported,
                pageIndexByHeading: headingPageIndex,
                tocInserted: tocInserted
            )
        }

        guard exported.write(to: url) else {
            throw ExportError.writeFailed(url.path)
        }
        return ExportReport(pdfURL: url, hasOutline: !outline.isEmpty)
    }

    /// 把标题大纲写入 PDF 书签（一级平铺）。
    ///
    /// 每个节点必须带 `destination`：PDFKit 写盘时会**丢弃没有目标的书签节点**，
    /// 只设 `label` 不会出现在产物里——这曾导致导出 PDF 一个书签都没有。
    /// 目标页面用标题文本在渲染后的 PDF 里回查，查不到则退回首页。
    private func buildOutline(
        _ items: [OutlineItem],
        in document: PDFDocument,
        pageIndexByHeading: [String: Int] = [:],
        tocInserted: Bool = false
    ) -> PDFOutline {
        let root = PDFOutline()
        let firstPage = document.page(at: 0)
        for item in items {
            let node = PDFOutline()
            node.label = item.title
            let key = PDFTextNormalizer.headingKey(item.title)
            if let index = pageIndexByHeading[key],
               let page = document.page(at: index + (tocInserted ? 1 : 0)) {
                // 优先用分页器采集的标题锚点：精确、且绕开中文文本层的部首映射问题
                node.destination = PDFDestination(page: page, at: .zero)
            } else if let selection = PDFTextNormalizer.findSelection(of: item.title, in: document),
                      let page = selection.pages.first {
                // 回退：归一化文本查找（康熙部首 / 兼容汉字 / 空白差异）
                node.destination = PDFDestination(page: page, at: selection.bounds(for: page).origin)
            } else if let page = firstPage {
                node.destination = PDFDestination(page: page, at: .zero)
            }
            root.insertChild(node, at: root.numberOfChildren)
        }
        return root
    }

    /// 标题 → 页索引（0-based，分页文档内）；同名标题取首次出现。
    private static func headingPageIndex(anchors: [HeadingAnchor], offsets: [CGFloat]) -> [String: Int] {
        guard !anchors.isEmpty, !offsets.isEmpty else { return [:] }
        var result: [String: Int] = [:]
        for anchor in anchors {
            let key = PDFTextNormalizer.headingKey(anchor.title)
            guard !key.isEmpty, result[key] == nil else { continue }
            if let index = pageIndex(for: anchor.top, offsets: offsets) {
                result[key] = index
            }
        }
        return result
    }

    /// 二分查找 top 落在哪一页（offsets 升序、0-based；+0.5 容差处理边界）。
    private static func pageIndex(for top: CGFloat, offsets: [CGFloat]) -> Int? {
        var low = 0
        var high = offsets.count - 1
        var result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if offsets[mid] <= top + 0.5 {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}
