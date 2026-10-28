import Foundation

/// 交付级 PDF 通道：**优先本机 `md2pdf`**（A4 分页、苹方子集内嵌、目录书签、页码），
/// 工具缺失或执行失败时回退内置 `PDFExporter`（WKWebView 渲染 + `PDFPaginator` 按内容块边界切 A4 页）。
///
/// 两条通道的版式控制不同，调用方须知：
/// - **md2pdf 通道**：样式、纸张、页边距、页眉页脚、目录书签全部由 md2pdf 的 `style.typ` 决定，
///   本函数的 `pageSetup` / `stamp` / `includeTOC` **不生效**；
/// - **内置回退通道**：上述参数全部生效（纸张/边距/页眉页脚/目录页）。
///
/// 抽成统一入口的原因：菜单导出、`markable://export`、App Intents、批量导出必须走同一策略，
/// 否则会出现「GUI 导出是 A4、URL / 快捷指令导出却是一张长纸」的分裂。
enum PDFDelivery {
    enum Channel: Equatable {
        case md2pdf
        case builtin
    }

    struct Result: Equatable {
        var url: URL
        var channel: Channel
    }

    enum DeliveryError: LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "无法读取文件：\(name)"
            }
        }
    }

    /// Markdown 文件 → PDF。`markdownURL` 必须是磁盘文件（md2pdf 需要文件路径）。
    @MainActor
    static func export(
        markdownURL: URL,
        to destination: URL,
        title: String,
        pageSetup: PageSetup,
        stamp: PDFStamp? = nil,
        includeTOC: Bool = false,
        preferBuiltin: Bool = false
    ) async throws -> Result {
        // preferBuiltin：用户显式要求用内置通道（让纸张/页边距/页眉页脚/目录页生效），
        // 即使本机装了 md2pdf 也不走 md2pdf。
        if !preferBuiltin, Md2PdfBridge.isAvailable,
           let url = try? await Md2PdfBridge.export(markdown: markdownURL, to: destination, title: title) {
            return Result(url: url, channel: .md2pdf)
        }

        guard let markdown = try? String(contentsOf: markdownURL, encoding: .utf8) else {
            throw DeliveryError.unreadable(markdownURL.lastPathComponent)
        }
        let html = HtmlRenderer().html(
            from: markdown, title: title, pageSetup: pageSetup,
            // 相对路径图片以 Markdown 源文件所在目录为基准读入并内联。
            baseDirectory: markdownURL.deletingLastPathComponent()
        )
        let outline = MarkdownEngine().outline(of: markdown)
        let report = try await PDFExporter().export(
            html: html, outline: outline, to: destination,
            pageSetup: pageSetup, stamp: stamp, title: title, includeTOC: includeTOC
        )
        return Result(url: report.pdfURL, channel: .builtin)
    }
}
