import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 导出菜单（T031）：把当前文档导出为带书签的 PDF，含进度与错误处理。
@MainActor
struct ExportMenu: View {
    let markdown: String
    let config: ExportConfig
    /// Markdown 源文件路径；用于解析 HTML 里的相对图片路径（未保存文档为 nil）。
    var sourceURL: URL? = nil

    @State private var isExporting = false
    @State private var errorMessage: String?

    var body: some View {
        Button("导出 PDF") { export() }
            .disabled(isExporting)
            .alert("导出失败", isPresented: isErrorPresented) {
                Button("好") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private var isErrorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(config.title).pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExporting = true
        Task {
            do {
                let html = HtmlRenderer().html(
                    from: markdown, title: config.title, pageSetup: config.pageSetup,
                    baseDirectory: sourceURL?.deletingLastPathComponent()
                )
                let outline = MarkdownEngine().outline(of: markdown)
                _ = try await PDFExporter().export(html: html, outline: outline, to: url,
                                                   pageSetup: config.pageSetup, stamp: config.stamp,
                                                   title: config.title, includeTOC: config.includeTOC)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isExporting = false
        }
    }
}
