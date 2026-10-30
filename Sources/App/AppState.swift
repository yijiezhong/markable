import Combine
import Foundation
import SwiftUI

/// 应用级视图状态：由 `MarkableApp` 持有并注入环境，供**菜单栏 / 工具栏 / 场景**共同读写。
///
/// 为什么要外置：SwiftUI 的 `.commands` 定义在 App 层，读不到 `DocumentScene` 内部
/// 的 `@State`。把"菜单需要显示勾选或读写"的状态集中到这里（movable 的 `store` 同思路），
/// 菜单与界面才不会各说各话。
@MainActor
final class AppState: ObservableObject {
    /// 共享实例：App、AppDelegate、窗口管理器、菜单栏都读写同一份状态。
    static let shared: AppState = {
        let state = AppState()
        state.observeCommands()
        return state
    }()

    private var cancellables = Set<AnyCancellable>()
    private var isObservingCommands = false

    private let settings: SettingsStore

    /// 主题偏好：system / light / dark。
    @Published var theme: String {
        didSet { settings.themePreference = theme }
    }
    /// 正文字号（11–24）。
    @Published var fontSize: Double {
        didSet { settings.fontSize = fontSize }
    }
    /// 视图缩放（0.5–3.0；1.0 = 实际大小）。
    ///
    /// 与 `fontSize` 相互独立：字号决定排版基准，缩放把比例乘到渲染字号上，
    /// 行宽随窗口重排（不会左右溢出）；导出不受影响。
    @Published var zoom: Double {
        didSet { settings.zoom = zoom }
    }
    /// 缩放上下限。
    nonisolated static let zoomRange: ClosedRange<Double> = 0.5...3.0

    /// 参考阅读宽度（点）。「缩放至窗口大小」以此为准：
    /// 窗口越宽字号越大、越窄越小，保持每行的视觉字数密度稳定。
    nonisolated static let referenceReadingWidth: Double = 800

    /// 纯函数：按方向计算下一档缩放（direction > 0 放大，< 0 缩小，0 原样收敛到范围内）。
    nonisolated static func steppedZoom(from current: Double, direction: Int) -> Double {
        guard direction != 0 else {
            return min(zoomRange.upperBound, max(zoomRange.lowerBound, current))
        }
        let factor = direction > 0 ? 1.1 : 1.0 / 1.1
        return min(zoomRange.upperBound, max(zoomRange.lowerBound, current * factor))
    }

    /// 纯函数：「缩放至窗口大小」的目标缩放。
    nonisolated static func fitZoom(forWidth width: Double) -> Double {
        guard width > 0 else { return 1.0 }
        return min(zoomRange.upperBound, max(zoomRange.lowerBound, width / referenceReadingWidth))
    }

    /// 排版参数。
    @Published var typography: Typography {
        didSet { settings.typography = typography }
    }
    /// 无序列表渲染成项目符号（`•`）；关闭时保留 Markdown 标记（默认）。
    @Published var bulletLists: Bool {
        didSet { settings.bulletLists = bulletLists }
    }
    /// 文件变化时自动刷新（默认开）。
    @Published var autoReload: Bool {
        didSet { settings.autoReload = autoReload }
    }
    /// 导出纸张。
    @Published var paper: PageSetup.Paper {
        didSet { settings.paperRaw = paper.rawValue }
    }
    /// 页边距（毫米）。
    @Published var marginMM: Double {
        didSet { settings.marginMM = marginMM }
    }
    /// 导出 PDF 页眉模板。
    @Published var pdfHeader: String {
        didSet { settings.pdfHeader = pdfHeader }
    }
    /// 导出 PDF 页脚模板。
    @Published var pdfFooter: String {
        didSet { settings.pdfFooter = pdfFooter }
    }
    /// 导出 PDF 是否插入目录页。
    @Published var includeTOC: Bool {
        didSet { settings.pdfIncludeTOC = includeTOC }
    }
    /// 导出 PDF 时是否强制走内置通道（md2pdf 的版式固定，内置通道才用这里的纸张/页眉页脚）。
    @Published var forceBuiltinPDFExport: Bool {
        didSet { settings.forceBuiltinPDFExport = forceBuiltinPDFExport }
    }
    /// 侧栏当前面板。
    @Published var sidebarMode: SidebarMode {
        didSet { settings.sidebarModeRaw = sidebarMode.rawValue }
    }
    /// 侧栏是否收起（菜单「隐藏侧边栏」）。
    @Published var sidebarHidden = false
    /// 文档内查找选项（菜单里可勾选）。
    @Published var findOptions = SearchOptions()
    /// 最近打开的文件（菜单「打开最近」）。
    @Published var recentPaths: [String] {
        didSet { settings.recentPaths = recentPaths }
    }

    /// `settings` 可注入（测试用临时 UserDefaults suite，避免污染真实偏好）。
    init(settings: SettingsStore = SettingsStore()) {
        self.settings = settings
        theme = settings.themePreference
        fontSize = settings.fontSize
        zoom = settings.zoom
        typography = settings.typography
        bulletLists = settings.bulletLists
        autoReload = settings.autoReload
        paper = PageSetup.Paper.from(settings.paperRaw)
        marginMM = settings.marginMM
        pdfHeader = settings.pdfHeader
        pdfFooter = settings.pdfFooter
        includeTOC = settings.pdfIncludeTOC
        forceBuiltinPDFExport = settings.forceBuiltinPDFExport
        sidebarMode = SidebarMode(rawValue: settings.sidebarModeRaw ?? "") ?? .outline
        recentPaths = settings.recentPaths
    }

    /// 订阅命令总线，处理**纯状态类**命令（主题/字号/排版/纸张/侧栏/查找选项）。
    /// 这样菜单与工具栏不依赖文档窗口是否存在；也让这些命令可被单元测试覆盖。
    func observeCommands() {
        guard !isObservingCommands else { return }
        isObservingCommands = true
        AppCommandBus.shared.$pending
            .compactMap { $0?.command }
            .sink { [weak self] command in
                Task { @MainActor in _ = self?.handleStateCommand(command) }
            }
            .store(in: &cancellables)
    }

    /// 处理纯状态命令；返回是否已处理（未处理者交给 `DocumentScene`）。
    @discardableResult
    func handleStateCommand(_ command: AppCommand) -> Bool {
        switch command {
        case .setTheme(let value): theme = value
        case .zoomIn: zoomIn()
        case .zoomOut: zoomOut()
        case .resetZoom: resetZoom()
        case .toggleLineWrap: typography.lineWrap.toggle()
        case .applyPreset(let preset): applyPreset(preset)
        case .setFontFamily(let family): typography.family = family
        case .adjustLineSpacing(let delta): adjustLineSpacing(by: delta)
        case .adjustParagraphSpacing(let delta): adjustParagraphSpacing(by: delta)
        case .toggleFirstLineIndent:
            typography.firstLineIndent = typography.firstLineIndent >= 1.5 ? 0 : 2
        case .toggleHeadingNumbering: typography.headingNumbering.toggle()
        case .toggleCodeLineNumbers: typography.codeLineNumbers.toggle()
        case .setPaper(let value): paper = value
        case .adjustMargin(let delta): adjustMargin(by: delta)
        case .toggleTOCPage: includeTOC.toggle()
        case .setSidebar(let mode):
            sidebarMode = mode
            sidebarHidden = false
        case .toggleSidebarHidden: sidebarHidden.toggle()
        case .toggleFindOption(let kind):
            switch kind {
            case .caseSensitive: findOptions.caseSensitive.toggle()
            case .wholeWord: findOptions.wholeWord.toggle()
            case .isRegex: findOptions.isRegex.toggle()
            }
        default:
            return false
        }
        return true
    }

    /// 记入最近打开（去重、置顶、最多 10 条）。
    func addRecent(_ path: String) {
        var list = recentPaths.filter { $0 != path }
        list.insert(path, at: 0)
        recentPaths = Array(list.prefix(10))
    }

    func clearRecents() { recentPaths = [] }

    /// 导出配置（UI 设置，未经 front matter 覆盖）。
    var baseExportConfig: ExportConfig {
        ExportConfig(
            title: "未命名",
            pageSetup: PageSetup(paper: paper, marginMM: marginMM),
            stamp: currentStamp,
            includeTOC: includeTOC
        )
    }

    /// 有效页眉/页脚（都为空时为 nil）。
    var currentStamp: PDFStamp? {
        let value = PDFStamp(header: pdfHeader, footer: pdfFooter)
        return value.isEnabled ? value : nil
    }

    // MARK: - 便捷动作（菜单与工具栏共用）

    /// 放大（×1.1，上限 3.0）。
    func zoomIn() { zoom = Self.steppedZoom(from: zoom, direction: 1) }

    /// 缩小（÷1.1，下限 0.5）。
    func zoomOut() { zoom = Self.steppedZoom(from: zoom, direction: -1) }

    /// 实际大小。
    func resetZoom() { zoom = 1.0 }

    func adjustMargin(by delta: Double) {
        marginMM = min(60, max(0, marginMM + delta))
    }

    func adjustLineSpacing(by delta: Double) {
        typography.lineSpacing = min(24, max(0, typography.lineSpacing + delta))
    }

    func adjustParagraphSpacing(by delta: Double) {
        typography.paragraphSpacing = min(24, max(0, typography.paragraphSpacing + delta))
    }

    /// 当前排版参数与哪个预设完全一致（菜单/工具栏据此显示勾选）。
    var currentPreset: Typography.Preset {
        Typography.Preset.allCases.first { Typography.preset($0) == typography } ?? .standard
    }

    func applyPreset(_ preset: Typography.Preset) {
        typography = Typography.preset(preset)
    }
}
