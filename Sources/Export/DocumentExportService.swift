import AppIntents
import Foundation

/// 导出格式（App Intents 与内部导出共用）。
enum ExportFormatOption: String, CaseIterable, Identifiable, AppEnum {
    case pdf
    case html

    var id: String { rawValue }
    var pathExtension: String { rawValue }

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "导出格式")
    static let caseDisplayRepresentations: [ExportFormatOption: DisplayRepresentation] = [
        .pdf: "PDF",
        .html: "HTML",
    ]
}

/// 导出/统计的**可测服务层**：App Intents 只是它的薄封装。
enum DocumentExportService {
    enum ServiceError: LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "无法读取文件：\(name)"
            }
        }
    }

    /// 把 `source` 处的 Markdown 导出到 `destination`（`format` 决定 PDF / HTML），返回目标路径。
    @MainActor
    @discardableResult
    static func export(
        markdownAt source: URL,
        to destination: URL,
        format: ExportFormatOption,
        pageSetup: PageSetup = PageSetup()
    ) async throws -> URL {
        guard let markdown = try? String(contentsOf: source, encoding: .utf8) else {
            throw ServiceError.unreadable(source.lastPathComponent)
        }
        let title = source.deletingPathExtension().lastPathComponent
        let html = HtmlRenderer().html(
            from: markdown, title: title, pageSetup: pageSetup,
            baseDirectory: source.deletingLastPathComponent()
        )

        switch format {
        case .html:
            try html.write(to: destination, atomically: true, encoding: .utf8)
        case .pdf:
            // 与菜单导出同一策略：有 md2pdf 时产出 A4 交付件，否则回退内置分页。
            _ = try await PDFDelivery.export(
                markdownURL: source, to: destination, title: title, pageSetup: pageSetup
            )
        }
        return destination
    }

    /// 默认输出路径：与源文件同目录、同名，扩展名随格式。
    static func defaultDestination(for source: URL, format: ExportFormatOption) -> URL {
        source.deletingPathExtension().appendingPathExtension(format.pathExtension)
    }

    /// 统计结果的一行中文描述。
    static func statsLine(markdownAt source: URL) throws -> String {
        guard let content = try? String(contentsOf: source, encoding: .utf8) else {
            throw ServiceError.unreadable(source.lastPathComponent)
        }
        let stats = TextStats.compute(content)
        return "字数 \(stats.words) ・ 字符 \(stats.characters) ・ 约 \(stats.readingMinutes) 分钟"
    }
}
