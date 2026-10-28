import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import PDFKit

/// `DocumentScene` 的导出：HTML / PNG / 批量导出 / PDF / 打印 / 分享与导出配置。
/// （自 `DocumentScene.swift` 机械拆分，逻辑未改。）
extension DocumentScene {
    /// 当前纸张与页边距设置（导出/分享共用）。
    private var pageSetup: PageSetup { PageSetup(paper: app.paper, marginMM: app.marginMM) }

    /// 有效页眉/页脚（都为空时返回 nil）。
    private var stamp: PDFStamp? {
        let value = PDFStamp(header: app.pdfHeader, footer: app.pdfFooter)
        return value.isEnabled ? value : nil
    }

    /// 本次导出配置：UI 设置被文档 front matter 覆盖后的结果。
    var exportConfig: ExportConfig {
        ExportConfig(
            title: document.path?.deletingPathExtension().lastPathComponent ?? "未命名",
            pageSetup: pageSetup,
            stamp: stamp,
            includeTOC: app.includeTOC
        ).applying(frontMatter: FrontMatter.parse(document.content))
    }

    // MARK: - 导出 HTML

    func exportHTML(styled: Bool) {
        let panel = NSSavePanel()
        let config = exportConfig
        panel.nameFieldStringValue = styled ? "\(config.title).html" : "\(config.title)-plain.html"
        panel.allowedContentTypes = [UTType.html]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let html = makeHtmlRenderer().html(from: document.content, title: config.title, pageSetup: config.pageSetup, styled: styled)
        try? html.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - 导出 PNG（逐页）

    func exportPNG() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "选择导出目录"
        guard panel.runModal() == .OK, let dir = panel.url else { return }

        let config = exportConfig
        let markdown = document.content
        Task { @MainActor in
            let html = makeHtmlRenderer().html(from: markdown, title: config.title, pageSetup: config.pageSetup)
            let outline = MarkdownEngine().outline(of: markdown)
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("markable-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard (try? await PDFExporter().export(
                html: html, outline: outline, to: tmp,
                pageSetup: config.pageSetup, stamp: config.stamp,
                title: config.title, includeTOC: config.includeTOC
            )) != nil,
                  let doc = PDFDocument(url: tmp) else { return }
            for index in 0..<doc.pageCount {
                guard let page = doc.page(at: index) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                let size = NSSize(width: bounds.width * 2, height: bounds.height * 2)
                let image = page.thumbnail(of: size, for: .mediaBox)
                guard let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { continue }
                let file = dir.appendingPathComponent(String(format: "page-%03d.png", index + 1))
                try? png.write(to: file)
            }
        }
    }

    // MARK: - 批量导出

    func batchExport(_ format: BatchFormat) {
        let sourcePanel = NSOpenPanel()
        sourcePanel.canChooseDirectories = true
        sourcePanel.canChooseFiles = false
        sourcePanel.prompt = "选择源文件夹"
        guard sourcePanel.runModal() == .OK, let sourceRoot = sourcePanel.url else { return }

        let destPanel = NSOpenPanel()
        destPanel.canChooseDirectories = true
        destPanel.canChooseFiles = false
        destPanel.canCreateDirectories = true
        destPanel.prompt = "选择输出文件夹"
        guard destPanel.runModal() == .OK, let outputRoot = destPanel.url else { return }

        let files = BatchExporter.markdownFiles(under: sourceRoot)
        guard !files.isEmpty else {
            batchReport = BatchReport(succeeded: [], failed: [])
            return
        }

        isBatching = true
        let setup = pageSetup
        Task { @MainActor in
            let report = await BatchExporter().export(
                sourceRoot: sourceRoot, files: files, outputRoot: outputRoot, format: format,
                pageSetup: setup, stamp: stamp, includeTOC: app.includeTOC,
                preferBuiltin: app.forceBuiltinPDFExport
            )
            isBatching = false
            batchReport = report
        }
    }

    // MARK: - 分享（导出临时 PDF → 系统分享面板）

    func share() {
        let config = exportConfig
        let markdown = document.content
        Task { @MainActor in
            let html = makeHtmlRenderer().html(from: markdown, title: config.title, pageSetup: config.pageSetup)
            let outline = MarkdownEngine().outline(of: markdown)
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(config.title).pdf")
            guard (try? await PDFExporter().export(
                html: html, outline: outline, to: tmp,
                pageSetup: config.pageSetup, stamp: config.stamp,
                title: config.title, includeTOC: config.includeTOC
            )) != nil else { return }
            guard let view = NSApp.keyWindow?.contentView else { return }
            NSSharingServicePicker(items: [tmp]).show(relativeTo: .zero, of: view, preferredEdge: .minY)
        }
    }

    /// 菜单「导出 PDF…」：与工具栏的导出菜单同逻辑，但由菜单自己弹保存面板。
    ///
    /// 交付级 PDF 优先走本机 `md2pdf` 工具（A4 分页 + 苹方子集内嵌 + 目录书签 + 页码）；
    /// 工具缺失或执行失败时回退内置 `PDFExporter`（单页长纸 + 标题书签）。
    func exportPDFViaPanel() {
        let config = exportConfig
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(config.title).pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if let source = document.path {
            let title = config.title
            Task { @MainActor in
                do {
                    let result = try await PDFDelivery.export(
                        markdownURL: source, to: url, title: title,
                        pageSetup: config.pageSetup, stamp: config.stamp, includeTOC: config.includeTOC,
                        preferBuiltin: app.forceBuiltinPDFExport
                    )
                    switch result.channel {
                    case .md2pdf:
                        exportNotice = "已用 md2pdf 导出（A4 分页 + 目录书签）：\(url.lastPathComponent)"
                    case .builtin:
                        exportNotice = "已用内置导出（A4 分页，未安装 md2pdf）：\(url.lastPathComponent)"
                    }
                } catch {
                    exportNotice = "导出失败：\(error.localizedDescription)"
                }
            }
            return
        }
        exportWithBuiltin(to: url, config: config)
    }

    /// 内置导出（回退路径）：WKWebView 渲染 + `PDFPaginator` 按内容块边界切 A4 页 + 标题书签。
    private func exportWithBuiltin(to url: URL, config: ExportConfig) {
        let markdown = document.content
        let outline = MarkdownEngine().outline(of: markdown)
        let html = makeHtmlRenderer().html(from: markdown, title: config.title, pageSetup: config.pageSetup)
        Task { @MainActor in
            _ = try? await PDFExporter().export(
                html: html, outline: outline, to: url,
                pageSetup: config.pageSetup, stamp: config.stamp,
                title: config.title, includeTOC: config.includeTOC
            )
        }
    }

    /// 菜单「打印…」：先排成 PDF，再交给系统打印面板（阅读器只读，不直接打印视图）。
    func printDocument() {
        let config = exportConfig
        let markdown = document.content
        let outline = MarkdownEngine().outline(of: markdown)
        let html = makeHtmlRenderer().html(from: markdown, title: config.title, pageSetup: config.pageSetup)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("markable-print-\(UUID().uuidString).pdf")
        Task { @MainActor in
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard (try? await PDFExporter().export(
                html: html, outline: outline, to: tmp,
                pageSetup: config.pageSetup, stamp: config.stamp,
                title: config.title, includeTOC: config.includeTOC
            )) != nil, let doc = PDFDocument(url: tmp) else { return }
            let info = NSPrintInfo.shared
            if let operation = doc.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: true) {
                operation.showsPrintPanel = true
                operation.run()
            }
        }
    }

    /// 导出用 HTML 渲染器：代码字体风格跟随正文字体族（衬线正文 → 衬线代码字体）。
    /// 同时带上文档目录，用于把相对路径图片读入并内联（未保存文档为 nil，图片退化为 alt）。
    func makeHtmlRenderer() -> HtmlRenderer {
        var renderer = HtmlRenderer()
        renderer.codeStyle = CodeTypography.style(for: app.typography.family)
        renderer.baseDirectory = document.path?.deletingLastPathComponent()
        return renderer
    }

}
