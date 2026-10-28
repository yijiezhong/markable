import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import PDFKit

/// `DocumentScene` 的命令处理：`markable://` URL 命令、缩放、大纲/段落跳转。
/// （自 `DocumentScene.swift` 机械拆分，逻辑未改。）
extension DocumentScene {

    // MARK: - 缩放（参考「预览」的缩放项）

    /// 缩放至窗口大小：按窗口内容宽度与参考阅读宽度（800pt）的比例缩放。
    /// 窄窗口字号变小、宽窗口字号变大，保持每行视觉字数密度稳定（字号缩放 + 自动折行模型）。
    func zoomToFitWindow() {
        guard let width = pager.scrollView?.contentView.bounds.width, width > 0 else {
            app.resetZoom()
            return
        }
        app.zoom = AppState.fitZoom(forWidth: Double(width))
    }


    // MARK: - 命令型 URL（markable://）

    /// 执行 `markable://` 命令。
    func execute(_ command: URLCommand) {
        switch command.action {
        case .open:
            guard let path = command.path else { return }
            // 与 Finder / 菜单「打开…」一致：走窗口管理器（同文件切标签、空标签复用、否则新开标签页）。
            DocumentWindowManager.shared.open(URLCommand.fileURL(path))
        case .settings:
            DocumentWindowManager.shared.showSettings()
        case .export:
            guard let path = command.path else { return }
            let source = URLCommand.fileURL(path)
            let output = command.output.map { URLCommand.fileURL($0) }
                ?? source.deletingPathExtension().appendingPathExtension(command.format == "html" ? "html" : "pdf")
            exportViaURL(source: source, output: output, format: command.format ?? "pdf")
        }
    }

    /// 从 URL 命令触发的导出（打开源文件后按当前配置导出到指定路径）。
    private func exportViaURL(source: URL, output: URL, format: String) {
        Task { @MainActor in
            guard let opened = try? store.open(path: source) else { return }
            document = opened
            selectedText = ""
            let config = exportConfig
            let html = makeHtmlRenderer().html(from: opened.content, title: config.title, pageSetup: config.pageSetup)
            if format == "html" {
                try? html.write(to: output, atomically: true, encoding: .utf8)
                return
            }
            // PDF：与菜单导出同一策略（md2pdf 优先，失败/缺失回退内置）
            _ = try? await PDFDelivery.export(
                markdownURL: source, to: output, title: config.title,
                pageSetup: config.pageSetup, stamp: config.stamp, includeTOC: config.includeTOC,
                preferBuiltin: app.forceBuiltinPDFExport
            )
        }
    }

    // MARK: - 大纲跳转

    func jumpToHeading(_ item: OutlineItem) {
        scrollRequest = ScrollRequest(search: item.title)
    }

    /// 跳到上一个（direction < 0）/ 下一个（direction > 0）标题。
    ///
    /// 只读 TextKit 2 视图里 `visibleTopCharacterIndex()` 不可靠（本机实测恒为 nil/0），
    /// 所以用游标推进：第一次按可见位置（拿不到就按 0）校准，之后连续点击按标题序号 ±1。
    /// 这样一来连点「下一个标题」会依次前进，不会每次都选中同一个。
    func jumpToAdjacentHeading(_ direction: Int) {
        let titles = MarkdownEngine().outline(of: document.content).map(\.title)
        guard !titles.isEmpty else { return }
        let rendered = pager.renderedText() ?? document.content
        let ns = rendered as NSString

        var base = headingCursor ?? 0
        if !titles.indices.contains(base) {
            let anchor = pager.visibleTopCharacterIndex() ?? 0
            var positions: [(title: String, location: Int)] = []
            for title in titles {
                let range = ns.range(of: title)
                if range.location != NSNotFound { positions.append((title, range.location)) }
            }
            positions.sort { $0.location < $1.location }
            base = max(0, positions.lastIndex { $0.location <= anchor + 8 } ?? 0)
        }
        let next = min(max(0, base + direction), titles.count - 1)
        headingCursor = next
        scrollRequest = ScrollRequest(search: titles[next])
    }


}
