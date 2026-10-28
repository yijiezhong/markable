import AppKit
import Foundation
import PDFKit

/// 批量导出格式。
enum BatchFormat: String, CaseIterable, Identifiable {
    case pdf = "PDF"
    case html = "HTML"
    case png = "PNG"
    var id: String { rawValue }
}

/// 批量导出结果（单个失败不中断）。
struct BatchReport: Equatable {
    struct Failure: Equatable {
        var path: String
        var reason: String
    }
    var succeeded: [String] = []
    var failed: [Failure] = []
    var total: Int { succeeded.count + failed.count }
    var summary: String {
        failed.isEmpty
            ? "成功导出 \(succeeded.count) 个文件。"
            : "成功 \(succeeded.count) 个，失败 \(failed.count) 个（共 \(total) 个）。"
    }
}

/// 批量导出：把一个目录（递归）下的全部 `.md` 导出为 PDF / HTML / PNG，
/// 保持相对目录结构；单个文件失败只记录、不中断整体。
@MainActor
final class BatchExporter {
    /// 递归收集目录下的 `.md` 文件（按路径排序，保证稳定顺序）。
    nonisolated static func markdownFiles(under root: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension.lowercased() == "md" {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// `file` 相对 `root` 的目录（用于在输出根下还原结构）。
    nonisolated static func relativeDirectory(of file: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return "" }
        let relative = String(filePath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let dir = (relative as NSString).deletingLastPathComponent
        return dir == "." ? "" : dir
    }

    /// 执行批量导出。
    func export(
        sourceRoot: URL,
        files: [URL],
        outputRoot: URL,
        format: BatchFormat,
        pageSetup: PageSetup,
        stamp: PDFStamp? = nil,
        includeTOC: Bool = false,
        preferBuiltin: Bool = false
    ) async -> BatchReport {
        var report = BatchReport()
        let fm = FileManager.default

        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            let relDir = Self.relativeDirectory(of: file, under: sourceRoot)
            var destDir = outputRoot
            if !relDir.isEmpty { destDir = outputRoot.appendingPathComponent(relDir) }

            do {
                try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

                guard let markdown = try? String(contentsOf: file, encoding: .utf8) else {
                    throw ExportError.writeFailed(file.path)
                }
                let title = file.lastPathComponent
                let outline = MarkdownEngine().outline(of: markdown)

                switch format {
                case .html:
                    let html = HtmlRenderer().html(
                        from: markdown, title: title, pageSetup: pageSetup,
                        baseDirectory: file.deletingLastPathComponent()
                    )
                    let dest = destDir.appendingPathComponent("\(name).html")
                    try html.write(to: dest, atomically: true, encoding: .utf8)

                case .pdf:
                    let dest = destDir.appendingPathComponent("\(name).pdf")
                    // 批量也走统一交付策略：有 md2pdf 用 A4，否则回退内置。
                    _ = try await PDFDelivery.export(
                        markdownURL: file, to: dest, title: title,
                        pageSetup: pageSetup, stamp: stamp, includeTOC: includeTOC,
                        preferBuiltin: preferBuiltin
                    )

                case .png:
                    let html = HtmlRenderer().html(
                        from: markdown, title: title, pageSetup: pageSetup,
                        baseDirectory: file.deletingLastPathComponent()
                    )
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("markable-batch-\(UUID().uuidString).pdf")
                    defer { try? fm.removeItem(at: tmp) }
                    _ = try await PDFExporter().export(
                        html: html, outline: outline, to: tmp,
                        pageSetup: pageSetup, stamp: stamp, title: title, includeTOC: includeTOC
                    )
                    guard let doc = PDFDocument(url: tmp) else { throw ExportError.renderFailed }
                    let pageDir = destDir.appendingPathComponent(name)
                    try fm.createDirectory(at: pageDir, withIntermediateDirectories: true)
                    for index in 0..<doc.pageCount {
                        guard let page = doc.page(at: index) else { continue }
                        let bounds = page.bounds(for: .mediaBox)
                        let image = page.thumbnail(of: NSSize(width: bounds.width * 2, height: bounds.height * 2), for: .mediaBox)
                        guard let tiff = image.tiffRepresentation,
                              let rep = NSBitmapImageRep(data: tiff),
                              let png = rep.representation(using: .png, properties: [:]) else { continue }
                        try png.write(to: pageDir.appendingPathComponent(String(format: "page-%03d.png", index + 1)))
                    }
                }
                report.succeeded.append(file.path)
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                report.failed.append(.init(path: file.path, reason: reason))
            }
        }
        return report
    }
}
