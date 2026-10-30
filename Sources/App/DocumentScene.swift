import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import PDFKit

/// 侧栏模式。
enum SidebarMode: String, CaseIterable, Identifiable {
    case outline = "大纲"
    case files = "文件"
    var id: String { rawValue }
}

/// 文档场景：侧栏（大纲/文件）+ 编辑器 + 导出 + 打开/保存（含冲突提示）。
struct DocumentScene: View {
    /// 初始文档（由窗口管理器传入；nil = 空白标签页，走"恢复上次阅读"）。
    var initialURL: URL? = nil
    /// 本视图所属窗口的标识（由窗口管理器分配，用于定向命令）。
    var windowID: UUID = UUID()

    @State var document = Document()
    @State private var selection = NSRange(location: 0, length: 0)
    @State var selectedText = ""
    @State var lastMtime: Date?
    @State var lastFileSize = 0
    @State var reloadToken = UUID()
    @State var showQuickOpen = false
    @State var quickQuery = ""
    @State var showSearch = false
    @State var searchQuery = ""
    @State var searchResults: [String] = []
    @State var scrollRequest: ScrollRequest?
    /// 标题跳转游标：连续点「上一个/下一个标题」时按标题推进。
    @State var headingCursor: Int?
    @State var batchReport: BatchReport?
    @State var isBatching = false
    /// 导出结果提示（md2pdf / 回退内置）。
    @State var exportNotice: String?
    @State var showHeaderSheet = false
    @State var showFindSheet = false
    @State var findQuery = ""
    @State var findMatches: [SearchMatch] = []
    @State var findMatchIndex = 0
    @State var lintIssues: [Lint.Issue] = []
    @State var showLintSheet = false
    @State var pager = ScrollViewBox()
    /// 大纲缓存：由 `.task(id:)` 在后台解析，避免每次 body 求值都扫描全文。
    @State private var outlineItems: [OutlineItem] = []
    @ObservedObject var urlBus = URLCommandBus.shared
    @EnvironmentObject var app: AppState
    @ObservedObject private var appCommandBus = AppCommandBus.shared
    private let fileTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private let storeUI = DocumentStoreUI()
    let store = FileDocumentStore()
    let settings = SettingsStore()

    /// 主内容：侧栏 + 编辑器 + 状态栏。
    ///
    /// 从 `body` 里拆出来（而不是内联）是为了降低类型推断复杂度——
    /// CI 上的编译器版本曾对单个 `body` 报「unable to type-check in reasonable time」。
    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if !app.sidebarHidden {
                    sidebar
                        .frame(width: 220)
                    Divider()
                }
                editor
            }
            Divider()
            statusBar
        }
    }

    /// 编辑器（TextKit 2 渲染）。
    private var editor: some View {
        MarkdownTextView(
            text: $document.content,
            selection: $selection,
            selectedText: $selectedText,
            baseDirectory: document.path?.deletingLastPathComponent(),
            // 放大 / 缩小：把缩放乘到排版字号上，行宽随窗口重排（不会左右溢出）。
            fontSize: CGFloat(app.fontSize * app.zoom),
            typography: app.typography,
            bulletLists: app.bulletLists,
            reloadToken: reloadToken,
            scrollRequest: scrollRequest,
            scrollViewBox: pager
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 工具栏第 1 组（`@ToolbarContentBuilder` 每组元素数需 ≤ 10，故分组）。
@ToolbarContentBuilder
    private var toolbarGroup1: some ToolbarContent {

            ToolbarItem(id: "open", placement: .navigation) {
                Button { openDocument() } label: { Label("打开", systemImage: "folder") }
                    .help("打开 Markdown 文档（⌘O）")
            }

            ToolbarItem(id: "reload", placement: .navigation) {
                Button { reloadFromDisk() } label: {
                    Label("重新载入", systemImage: "arrow.clockwise")
                }
                .help("从磁盘重新载入并重新渲染（⌘R）")
            }

            ToolbarItem(id: "quickOpen", placement: .navigation) {
                Button { quickQuery = ""; showQuickOpen = true } label: {
                    Label("快速打开", systemImage: "text.magnifyingglass")
                }
                .help("快速打开（⇧⌘O）")
            }

            ToolbarItem(id: "prevHeading", placement: .navigation) {
                Button { jumpToAdjacentHeading(-1) } label: { Label("上一个标题", systemImage: "chevron.up") }
                    .help("跳到上一个标题（⌘↑）")
            }

            ToolbarItem(id: "nextHeading", placement: .navigation) {
                Button { jumpToAdjacentHeading(1) } label: { Label("下一个标题", systemImage: "chevron.down") }
                    .help("跳到下一个标题（⌘↓）")
            }

            // ── 右侧 · 阅读：查找（高频） ──
            ToolbarItem(id: "find", placement: .primaryAction) {
                Button { findQuery = ""; findMatches = []; showFindSheet = true } label: {
                    Label("查找", systemImage: "magnifyingglass")
                }
                .help("文档内查找：正则 / 整词 / 大小写")
            }

            // ── 右侧 · 显示与缩放 ──
            ToolbarItem(id: "zoomOut", placement: .primaryAction) {
                Button { app.zoomOut() } label: {
                    Label("缩小", systemImage: "minus.magnifyingglass")
                }
                .help("缩小（⌘-）")
            }
    }

    /// 工具栏第 2 组（`@ToolbarContentBuilder` 每组元素数需 ≤ 10，故分组）。
@ToolbarContentBuilder
    private var toolbarGroup2: some ToolbarContent {

            ToolbarItem(id: "actualSize", placement: .primaryAction) {
                Button { app.resetZoom() } label: {
                    Label("实际大小", systemImage: "1.magnifyingglass")
                }
                .help("实际大小（⌘0）")
                .disabled(abs(app.zoom - 1.0) < 0.001)
            }
            ToolbarItem(id: "zoomToFit", placement: .primaryAction) {
                Button { zoomToFitWindow() } label: {
                    Label("缩放至窗口大小", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
                }
                .help("缩放至窗口大小（⌘9）")
            }
            ToolbarItem(id: "zoomIn", placement: .primaryAction) {
                Button { app.zoomIn() } label: {
                    Label("放大", systemImage: "plus.magnifyingglass")
                }
                .help("放大（⌘+）")
            }
            ToolbarItem(id: "theme", placement: .primaryAction) {
                Menu {
                    ForEach([("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")], id: \.0) { value, title in
                        Button(app.theme == value ? "✓ \(title)" : title) { app.theme = value }
                    }
                } label: {
                    Label(themeTitle, systemImage: "circle.lefthalf.filled")
                }
                .help("主题")
            }
            ToolbarItem(id: "preset", placement: .primaryAction) {
                Menu {
                    ForEach(Typography.Preset.allCases) { preset in
                        Button(app.currentPreset == preset ? "✓ \(preset.title)" : preset.title) {
                            app.applyPreset(preset)
                        }
                    }
                } label: {
                    Label(app.currentPreset.title, systemImage: "textformat")
                }
                .help("版式")
            }

            // ── 右侧 · 检查 ──
            ToolbarItem(id: "lint", placement: .primaryAction) {
                Button { showLintSheet = true } label: {
                    Label(lintIssues.isEmpty ? "体检通过" : "体检 \(lintIssues.count)",
                          systemImage: lintIssues.isEmpty ? "checkmark.seal" : "exclamationmark.triangle")
                }
                .help("文档体检结果")
            }

            // ── 右侧 · 导出与分享（流程末端） ──
            ToolbarItem(id: "export", placement: .primaryAction) {
                // 导出相关的入口统一收进这一个下拉，工具栏不再平铺 6 个按钮。
                Menu {
                    Button("导出 PDF…") { exportPDFViaPanel() }
                    Menu("导出 HTML") {
                        Button("含样式") { exportHTML(styled: true) }
                        Button("纯内容（无样式）") { exportHTML(styled: false) }
                    }
                    Button("导出图片（PNG，逐页）…") { exportPNG() }
                    Divider()
                    Menu("批量导出") {
                        ForEach(BatchFormat.allCases) { format in
                            Button(format.rawValue) { batchExport(format) }
                        }
                    }
                    .disabled(isBatching)
                    Divider()
                    Button("分享…") { share() }
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .help("导出 PDF / HTML / 图片，或分享")
            }

        
    }

    var body: some View { panels }

    /// 面板与弹窗（sheet / alert）。
    private var panels: some View {
        lifecycle
        .sheet(isPresented: $showQuickOpen) { quickOpenSheet }
        .sheet(isPresented: $showSearch) { searchSheet }
        .sheet(isPresented: $showHeaderSheet) { headerFooterSheet }
        .sheet(isPresented: $showFindSheet) { findSheet }
        .sheet(isPresented: $showLintSheet) { lintSheet }
        .onChange(of: document.content) { _, _ in refreshLint() }
        .onChange(of: urlBus.queue) { _, queue in
            guard let first = queue.first else { return }
            defer { urlBus.consume(first.id) }
            // URL 命令同样只作用于当前标签页
            guard DocumentWindowManager.shared.activeWindowID == windowID else { return }
            execute(first.command)
        }
        .onAppear { urlBus.ready() }
        .onReceive(NotificationCenter.default.publisher(for: .markableOpenInWindow)) { note in
            guard let id = note.userInfo?["id"] as? UUID, id == windowID,
                  let url = note.userInfo?["url"] as? URL else { return }
            // 通知已送达：清掉待打开队列，避免视图重建时重复加载旧文件。
            _ = DocumentWindowManager.shared.consumePendingURL(for: windowID)
            load(url)
        }
        .onChange(of: appCommandBus.pending) { _, incoming in
            guard let command = incoming?.command else { return }
            // 多标签页时，菜单/工具栏命令只作用于当前聚焦的标签页
            guard DocumentWindowManager.shared.activeWindowID == windowID else { return }
            execute(command)
        }
        .alert("批量导出完成", isPresented: batchReportPresented) {
            Button("好") { batchReport = nil }
        } message: {
            Text(batchReport?.summary ?? "")
        }
        .alert("导出完成", isPresented: exportNoticePresented) {
            Button("好") { exportNotice = nil }
        } message: {
            Text(exportNotice ?? "")
        }
        .task(id: document.content) {
            // 大纲在后台解析；编辑时 300ms 防抖（大文档不在主线程扫描全文）
            let text = document.content
            try? await Task.sleep(for: .milliseconds(300))
            let items = await Task.detached { MarkdownEngine().outline(of: text) }.value
            outlineItems = items
        }    }

    /// 事件与生命周期（命令总线、URL 命令、文件变化、定时器）。
    private var lifecycle: some View {
        windowed
        .task {
            // 已由「打开通知」加载过（启动期打开文件）时不要覆盖。
            if document.path != nil { return }
            if let initialURL {
                load(initialURL)
                return
            }
            // 冷启动时打开事件可能晚于视图挂载：先查一次，再等一小段复查。
            if let pending = DocumentWindowManager.shared.consumePendingURL(for: windowID) {
                load(pending)
                return
            }
            try? await Task.sleep(for: .milliseconds(180))
            if document.path != nil { return }
            if let pending = DocumentWindowManager.shared.consumePendingURL(for: windowID) {
                load(pending)
                return
            }
            restoreLastDocument()
        }
        .onAppear { applyTheme(app.theme) }
        .onChange(of: app.theme) { _, value in applyTheme(value) }
        .onReceive(fileTimer) { _ in checkExternalChange() }
    }

    /// 窗口外观：尺寸、标题、工具栏。
    private var windowed: some View {
        content
        .frame(minWidth: 960, minHeight: 620)
        .navigationTitle(document.path?.lastPathComponent ?? "未命名")
        .toolbar {
            toolbarGroup1
            toolbarGroup2
        }
    }

    // MARK: - 菜单 / 工具栏命令

    /// 执行菜单或工具栏发出的命令（`.commands` 在 App 层，读不到本视图的 @State，
    /// 因此统一经 `AppCommandBus` 投递到这里）。
    /// 命令总线分发：按「文档 / 导出 / 导航 / 纯状态」分组，避免单个 30+ 分支的巨型 switch
    /// （swiftlint cyclomatic_complexity）。
    private func execute(_ command: AppCommand) {
        switch command {
        case .newWindow, .openDocument, .quickOpen, .openRecent, .clearRecent,
             .reloadFile, .lintDocument:
            executeDocumentCommand(command)
        case .share, .exportPDF, .exportHTML, .exportPNG, .batchExport, .pdfOptions, .printDocument:
            executeExportCommand(command)
        case .zoomToFit, .findDocument, .crossFileSearch,
             .previousHeading, .nextHeading, .scrollToTop, .scrollToBottom,
             .findNext, .findPrevious,
             .findUsingSelection, .showSystemFindBar:
            executeNavigationCommand(command)
        case .setTheme, .zoomIn, .zoomOut, .resetZoom, .toggleLineWrap,
             .applyPreset, .setFontFamily,
             .adjustLineSpacing, .adjustParagraphSpacing, .toggleFirstLineIndent,
             .toggleHeadingNumbering, .toggleCodeLineNumbers, .setPaper, .adjustMargin,
             .toggleTOCPage, .setSidebar, .toggleSidebarHidden, .toggleFindOption,
             .toggleToolbarShown:
            executeChromeCommand(command)
        }
    }

    /// 文档命令：打开 / 最近 / 重载 / 文档体检。
    private func executeDocumentCommand(_ command: AppCommand) {
        switch command {
        case .newWindow:
            break   // 由 App 层创建窗口
        case .openDocument: openDocument()
        case .quickOpen: quickQuery = ""; showQuickOpen = true
        case .openRecent(let url): DocumentWindowManager.shared.open(url)
        case .clearRecent: app.clearRecents()
        case .reloadFile: reloadFromDisk()
        case .lintDocument:
            refreshLint()
            showLintSheet = true
        default:
            break
        }
    }

    /// 导出命令：PDF / HTML / PNG / 批量 / 打印 / 分享 / PDF 选项。
    private func executeExportCommand(_ command: AppCommand) {
        switch command {
        case .share: share()
        case .exportPDF: exportPDFViaPanel()
        case .exportHTML(let styled): exportHTML(styled: styled)
        case .exportPNG: exportPNG()
        case .batchExport(let format): batchExport(format)
        case .pdfOptions: showHeaderSheet = true
        case .printDocument: printDocument()
        default:
            break
        }
    }

    /// 导航命令：缩放适配、查找、标题/段落跳转、滚动。
    private func executeNavigationCommand(_ command: AppCommand) {
        switch command {
        case .zoomToFit: zoomToFitWindow()
        case .findDocument: findQuery = ""; findMatches = []; showFindSheet = true
        case .crossFileSearch: searchQuery = ""; searchResults = []; showSearch = true
        case .previousHeading: jumpToAdjacentHeading(-1)
        case .nextHeading: jumpToAdjacentHeading(1)
        case .scrollToTop: pager.scrollToTop()
        case .scrollToBottom: pager.scrollToBottom()
        case .findNext: advanceFind(1)
        case .findPrevious: advanceFind(-1)
        case .findUsingSelection: findUsingSelection()
        case .showSystemFindBar: showSystemFindBar()
        default:
            break
        }
    }

    /// 纯状态命令：主题 / 缩放 / 折行 / 排版 / 纸张 / 侧栏 / 查找选项 / 工具栏。
    /// 这些由 `AppState` 统一处理，这里只需要「不响应」或交给系统标准动作。
    private func executeChromeCommand(_ command: AppCommand) {
        switch command {
        case .toggleToolbarShown: NSApp.keyWindow?.toggleToolbarShown(nil)
        default:
            break
        }
    }

    /// 工具栏「主题」按钮上显示的当前值。
    private var themeTitle: String {
        switch app.theme {
        case "light": return "浅色"
        case "dark": return "深色"
        default: return "跟随系统"
        }
    }

    private var batchReportPresented: Binding<Bool> {
        Binding(get: { batchReport != nil }, set: { if !$0 { batchReport = nil } })
    }

    /// 导出结果提示的显示绑定。
    private var exportNoticePresented: Binding<Bool> {
        Binding(get: { exportNotice != nil }, set: { if !$0 { exportNotice = nil } })
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("", selection: $app.sidebarMode) {
                ForEach(SidebarMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(6)
            Divider()
            switch app.sidebarMode {
            case .outline:
                OutlinePanel(items: outlineItems, numbered: app.typography.headingNumbering) { item in
                    jumpToHeading(item)
                }
            case .files:
                FilesPanel(directory: document.path?.deletingLastPathComponent()) { url in
                    if let opened = try? store.open(path: url) { document = opened }
                }
            }
        }
    }

    // MARK: - 主题

    private var statusBar: some View {
        let stats = TextStats.compute(document.content)
        return HStack(spacing: 12) {
            if selectedText.isEmpty {
                Text("字数 \(stats.words)")
                Text("句数 \(stats.sentences)")
                Text("字符 \(stats.characters)")
                Text("约 \(stats.readingMinutes) 分钟")
            } else {
                let sel = TextStats.compute(selectedText)
                Text("选区 \(sel.words) 字")
                Text("选区 \(sel.characters) 字符")
                Text("全文 \(stats.words) 字")
            }
            Spacer()
            if lintIssues.isEmpty {
                Text("体检通过").foregroundStyle(.secondary)
            } else {
                Button {
                    showLintSheet = true
                } label: {
                    Text("⚠︎ \(lintIssues.count) 处提示").foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("点击查看文档体检结果")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    /// 重算文档体检（内容变化时调用；避免每次重绘都跑）。
    func refreshLint() {
        lintIssues = Lint.check(document.content)
    }

    private func applyTheme(_ value: String) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

}
