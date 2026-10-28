import AppIntents
import Foundation
import UniformTypeIdentifiers

/// 供 App Intents 复用的错误。
enum MarkableIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case missingFile
    case unreadable(String)
    case unsupported

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .missingFile: return "没有拿到文件路径"
        case .unreadable(let name): return "无法读取文件：\(name)"
        case .unsupported: return "本机系统不支持该功能"
        }
    }
}

// MARK: - 打开

/// 在 Markable 中打开一个 Markdown 文档。
struct OpenDocumentIntent: AppIntent {
    static let title: LocalizedStringResource = "打开 Markdown 文档"
    static let description = IntentDescription("在 Markable 中打开一个 Markdown 文档。")
    static let openAppWhenRun = true

    @Parameter(title: "文档", description: "要打开的 Markdown 文件（.md）")
    var document: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("用 Markable 打开 \(\.$document)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let url = document.fileURL else { throw MarkableIntentError.missingFile }
        await MainActor.run {
            URLCommandBus.shared.send(URLCommand(action: .open, path: url.path, output: nil, format: nil))
        }
        return .result(dialog: "已在 Markable 中打开 \(url.lastPathComponent)")
    }
}

// MARK: - 导出

/// 把 Markdown 文档导出为 PDF / HTML（不需要界面）。
struct ExportDocumentIntent: AppIntent {
    static let title: LocalizedStringResource = "导出 Markdown 文档"
    static let description = IntentDescription("把 Markdown 文档导出为 PDF 或 HTML。")
    static let openAppWhenRun = false

    @Parameter(title: "文档", description: "要导出的 Markdown 文件（.md）")
    var document: IntentFile

    @Parameter(title: "格式", default: .pdf)
    var format: ExportFormatOption

    @Parameter(title: "输出文件", description: "留空则输出到源文件同目录、同名（扩展名随格式）")
    var output: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("把 \(\.$document) 导出为 \(\.$format)") {
            \.$output
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let url = document.fileURL else { throw MarkableIntentError.missingFile }
        let destination = output?.fileURL ?? DocumentExportService.defaultDestination(for: url, format: format)
        let written = try await DocumentExportService.export(markdownAt: url, to: destination, format: format)
        return .result(dialog: "已导出到 \(written.lastPathComponent)")
    }
}

// MARK: - 统计

/// 统计文档字数 / 字符数 / 预计阅读时长。
struct DocumentStatsIntent: AppIntent {
    static let title: LocalizedStringResource = "统计 Markdown 文档"
    static let description = IntentDescription("返回文档的字数、字符数与预计阅读时长。")
    static let openAppWhenRun = false

    @Parameter(title: "文档", description: "要统计的 Markdown 文件（.md）")
    var document: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("统计 \(\.$document)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let url = document.fileURL else { throw MarkableIntentError.missingFile }
        let text: String
        do {
            text = try DocumentExportService.statsLine(markdownAt: url)
        } catch {
            throw MarkableIntentError.unreadable(url.lastPathComponent)
        }
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - 快捷指令短语

/// 注册给「快捷指令 / Siri / 聚焦」的短语。
struct MarkableShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenDocumentIntent(),
            phrases: ["用 \(.applicationName) 打开文档"],
            shortTitle: "打开文档",
            systemImageName: "book"
        )
        AppShortcut(
            intent: ExportDocumentIntent(),
            phrases: ["用 \(.applicationName) 导出文档"],
            shortTitle: "导出文档",
            systemImageName: "square.and.arrow.up"
        )
        AppShortcut(
            intent: DocumentStatsIntent(),
            phrases: ["用 \(.applicationName) 统计文档"],
            shortTitle: "文档统计",
            systemImageName: "number"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .blue
}
