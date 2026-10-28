import Foundation

/// 文档查找选项（`SearchOptions` 的字段，供菜单勾选）。
enum FindOptionKind: String, CaseIterable, Identifiable {
    case caseSensitive
    case wholeWord
    case isRegex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .caseSensitive: return "区分大小写"
        case .wholeWord: return "整词"
        case .isRegex: return "正则表达式"
        }
    }
}

/// 菜单 / 工具栏发出的应用级命令。
///
/// `.commands` 定义在 App 层，无法直接调用 `DocumentScene` 的方法，
/// 因此统一经 `AppCommandBus` 投递，由 `DocumentScene` 执行。
enum AppCommand: Equatable {
    // 文件
    case newWindow
    case openDocument
    case quickOpen
    case openRecent(URL)
    case clearRecent
    case share
    case exportPDF
    case exportHTML(styled: Bool)
    case exportPNG
    case batchExport(BatchFormat)
    case pdfOptions
    case printDocument

    // 查找
    case findDocument
    case findNext
    case findPrevious
    case findUsingSelection
    case showSystemFindBar
    case crossFileSearch
    case toggleFindOption(FindOptionKind)

    // 视图 - 侧栏
    case setSidebar(SidebarMode)
    case toggleSidebarHidden

    // 视图 - 工具栏
    case toggleToolbarShown

    // 视图 - 显示
    case setTheme(String)
    /// 放大 / 缩小 / 实际大小（整体视图缩放，不影响字号设置）。
    case zoomIn
    case zoomOut
    case resetZoom
    /// 缩放至窗口大小（按窗口内容宽度适配阅读宽度）。
    case zoomToFit
    /// 自动折行开关（默认开）。
    case toggleLineWrap
    case applyPreset(Typography.Preset)
    case setFontFamily(Typography.Family)
    case adjustLineSpacing(Double)
    case adjustParagraphSpacing(Double)
    case toggleFirstLineIndent
    case toggleHeadingNumbering
    case toggleCodeLineNumbers
    case setPaper(PageSetup.Paper)
    case adjustMargin(Double)
    case toggleTOCPage

    // 导航
    case previousHeading
    case nextHeading
    case scrollToTop
    case scrollToBottom
    case reloadFile
    case lintDocument
}

/// 命令总线：菜单/工具栏 → 场景。
@MainActor
final class AppCommandBus: ObservableObject {
    struct Incoming: Equatable {
        var id: Int
        var command: AppCommand
    }

    static let shared = AppCommandBus()

    @Published private(set) var pending: Incoming?
    private var counter = 0

    func send(_ command: AppCommand) {
        counter += 1
        pending = Incoming(id: counter, command: command)
    }
}
