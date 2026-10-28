import AppKit
import SwiftUI

/// 应用入口。
@main
struct MarkableApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var appState = AppState.shared
    private let commandBus = AppCommandBus.shared

    var body: some Scene {
        // 文档窗口**全部由 AppKit 管理**（`DocumentWindowManager`）：一个窗口 + 多个标签页。
        // 这里刻意不声明 `Window`/`WindowGroup` 场景：否则 SwiftUI 会自己创建一个文档窗口，
        // 与手动创建的窗口同处一个标签组，所有权冲突曾导致 objc_release 野指针崩溃。
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
        .commands { fileCommands }
        .commands { editAndFormatCommands }
        .commands { viewCommands }
    }

    private func send(_ command: AppCommand) {
        commandBus.send(command)
    }

    // MARK: - 菜单栏（仿 movable，除编辑）

    @CommandsBuilder
    private var fileCommands: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于 Markable") { showAbout() }
        }
        CommandGroup(replacing: .appSettings) {
            SettingsLink { Text("设置…") }
            // 「帮助」菜单里的项受系统特殊对待、键位不参与匹配，这里在应用菜单再放一个（⌘? 生效）
            Button("Markable 帮助…") { HelpWindowController.shared.show() }
                .keyboardShortcut("/", modifiers: [.command, .shift])   // ⌘?
        }

        // ── 文件 ──
        CommandGroup(replacing: .newItem) {
            Button("新建标签页") { DocumentWindowManager.shared.newTab() }
                .keyboardShortcut("n", modifiers: .command)
            Button("打开…") { send(.openDocument) }
                .keyboardShortcut("o", modifiers: .command)
            Button("快速打开…") { send(.quickOpen) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Menu("打开最近") {
                if appState.recentPaths.isEmpty {
                    Text("没有最近打开的文件")
                } else {
                    ForEach(appState.recentPaths, id: \.self) { path in
                        let url = URL(fileURLWithPath: path)
                        Button(url.lastPathComponent) { send(.openRecent(url)) }
                    }
                    Divider()
                    Button("清除菜单") { send(.clearRecent) }
                }
            }
            Divider()
            Button("分享…") { send(.share) }
        }
        CommandGroup(replacing: .printItem) {
            Button("打印…") { send(.printDocument) }
                .keyboardShortcut("p", modifiers: .command)
        }
        // 只读阅读器没有"保存"，把这个位置让给「关闭标签页」+ 导出
        CommandGroup(replacing: .saveItem) {
            Button("关闭标签页") { DocumentWindowManager.shared.closeCurrentTab() }
                .keyboardShortcut("w", modifiers: .command)   // ⌘W
            Divider()
            Button("导出 PDF…") { send(.exportPDF) }
                .keyboardShortcut("e", modifiers: .command)
        }
        CommandGroup(after: .saveItem) {
            Button("导出 HTML（含样式）…") { send(.exportHTML(styled: true)) }
            Button("导出 HTML（纯内容）…") { send(.exportHTML(styled: false)) }
            Button("导出图片（PNG，逐页）…") { send(.exportPNG) }
            Menu("批量导出") {
                ForEach(BatchFormat.allCases) { format in
                    Button(format.rawValue) { send(.batchExport(format)) }
                }
            }
            Divider()
            Button("重新载入（从磁盘）") { send(.reloadFile) }
                .keyboardShortcut("r", modifiers: .command)
        }

    }

    // MARK: - 菜单：查找 / 主题 / 字号排版 / 纸张

    @CommandsBuilder
    private var editAndFormatCommands: some Commands {
        // ── 查找 ──
        CommandGroup(after: .textEditing) {
            Button("查找…") { send(.findDocument) }
                .keyboardShortcut("f", modifiers: .command)
            Button("查找下一个") { send(.findNext) }
                .keyboardShortcut("g", modifiers: .command)
            Button("查找上一个") { send(.findPrevious) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("使用所选内容查找") { send(.findUsingSelection) }
                .keyboardShortcut("g", modifiers: [.command, .option])
            Button("使用查找面板…") { send(.showSystemFindBar) }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Button("在文件夹中查找…") { send(.crossFileSearch) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("文档体检") { send(.lintDocument) }
        }

        // ── 主题 ──
        CommandMenu("主题") {
            ForEach([("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")], id: \.0) { value, label in
                Button(label) { send(.setTheme(value)) }
            }
        }

        // ── 版式（顶级菜单，与主题平级）──
        CommandMenu("版式") {
            ForEach(Typography.Preset.allCases) { preset in
                Button(preset.title) { send(.applyPreset(preset)) }
            }
        }

        // ── 字号与排版 ──
        CommandMenu("字号与排版") {
            // 缩放（参考「预览」）：放大 / 缩小 / 实际大小 / 适配窗口 / 所选
            Button("放大") { send(.zoomIn) }
                .keyboardShortcut("+", modifiers: .command)
            Button("缩小") { send(.zoomOut) }
                .keyboardShortcut("-", modifiers: .command)
            Button("实际大小") { send(.resetZoom) }
                .keyboardShortcut("0", modifiers: .command)
            Button("缩放至窗口大小") { send(.zoomToFit) }
                .keyboardShortcut("9", modifiers: .command)
            Divider()
            Menu("字体") {
                ForEach(Typography.Family.allCases) { family in
                    Button(appState.typography.family == family ? "✓ \(family.title)" : family.title) {
                        send(.setFontFamily(family))
                    }
                }
            }
            Divider()
            Button(appState.typography.lineWrap ? "✓ 自动折行" : "自动折行") {
                send(.toggleLineWrap)
            }
            Button(appState.typography.firstLineIndent >= 1.5 ? "✓ 首行缩进 2 字" : "首行缩进 2 字") {
                send(.toggleFirstLineIndent)
            }
            Button(appState.typography.headingNumbering ? "✓ 标题编号" : "标题编号") {
                send(.toggleHeadingNumbering)
            }
            Button(appState.typography.codeLineNumbers ? "✓ 代码行号" : "代码行号") {
                send(.toggleCodeLineNumbers)
            }
            Divider()
            Button("行距 +2") { send(.adjustLineSpacing(2)) }
            Button("行距 −2") { send(.adjustLineSpacing(-2)) }
            Button("段间距 +2") { send(.adjustParagraphSpacing(2)) }
            Button("段间距 −2") { send(.adjustParagraphSpacing(-2)) }
        }

    }

    // MARK: - 菜单：视图

    @CommandsBuilder
    private var viewCommands: some Commands {
        // ── 视图：侧栏 ──
        CommandGroup(before: .sidebar) {
            Button("隐藏侧边栏") { send(.toggleSidebarHidden) }
                .keyboardShortcut("j", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            // 不显示勾选：`Commands` 里的 Button title 与 Toggle 状态都在构建时求值，
            // 侧栏切换后菜单不会重建，勾选会停在旧值（实测「侧栏文件、菜单勾大纲」）。
            // 改用纯命令项：点哪个就切到哪个，当前面板由侧栏自身的分段控件显示。
            Button("大纲") { send(.setSidebar(.outline)) }
                .keyboardShortcut("k", modifiers: .command)
            Button("文件") { send(.setSidebar(.files)) }
                .keyboardShortcut("l", modifiers: .command)
        }

        // ── 帮助（官方 `.help` 命令组：把 SwiftUI 自动生成的、点不动的项换成我们自己的）──
        // macOS 会往「帮助」菜单里插入一个搜索框（该搜索框在 macOS 27 上对第三方应用不返回结果）；
        // 由 AppDelegate 把它剥离（见 `configureHelpMenu`）。
        CommandGroup(replacing: .help) {
            Button("Markable 帮助…") { HelpWindowController.shared.show() }
        }

        // ── 视图：工具栏与导航 ──
        CommandGroup(after: .toolbar) {
            Button("隐藏工具栏") { send(.toggleToolbarShown) }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button("显示 / 隐藏标签栏") { NSApp.keyWindow?.toggleTabBar(nil) }
                .keyboardShortcut("b", modifiers: [.command, .option])
            Divider()
            Button("回到开头") { send(.scrollToTop) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("跳到结尾") { send(.scrollToBottom) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("上一个标题") { send(.previousHeading) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("下一个标题") { send(.nextHeading) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
            Button("重新加载文件") { send(.reloadFile) }
                .keyboardShortcut("r", modifiers: .command)
        }

    }

    private func checked(_ kind: FindOptionKind) -> String {
        let on: Bool
        switch kind {
        case .caseSensitive: on = appState.findOptions.caseSensitive
        case .wholeWord: on = appState.findOptions.wholeWord
        case .isRegex: on = appState.findOptions.isRegex
        }
        return on ? "✓ \(kind.title)" : kind.title
    }

    // MARK: - 动作

    private func showAbout() {
        // 自定义窗口：顺序为「图标 → Markable → © Markable（纯黑加粗）→ 说明 → 版本」。
        // 标准 About 面板无法把版权行提到第二行，也无法单独指定颜色/字重。
        AboutWindowController.shared.show()
    }

}

/// 清掉「帮助」菜单里的系统搜索项（一个 view 为 `NSSearchField` 的菜单项）。
@MainActor
final class HelpMenuStripper: NSObject, NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        strip(menu)
    }

    func strip(_ menu: NSMenu) {
        for item in menu.items where item.view is NSSearchField {
            menu.removeItem(item)
        }
    }
}

/// 处理 `markable://` 命令型 URL 与工具栏自定义：
/// - URL：已作为 `.app` 运行且注册了 scheme 时经 Apple Event（`kAEGetURL`）送达；
///   也可直接作为命令行参数传入（`Markable 'markable://open?path=…'`）。
/// - 工具栏：SwiftUI 自建菜单栏时 AppKit 不会自动补「自定义工具栏…」的能力，
///   需要把 `allowsUserCustomization` 打开。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // 应用只声明了 `Settings` 场景，SwiftUI 会在启动时把设置窗口也显示出来。
        // macOS 14 没有公开 API 完全抑制（macOS 15+ 可用 SceneLaunchBehavior.suppressed，
        // 但会放弃 14 兼容）；这里从启动最早时刻起每 10ms 检查一次，首次可见立即
        // 无动画 orderOut，把闪烁压到尽量小，且只隐藏首次（不误关用户主动打开的设置）。
        hideLaunchSettingsWindowIfNeeded()
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        for argument in CommandLine.arguments.dropFirst() {
            guard let url = URL(string: argument), let command = URLCommand.parse(url) else { continue }
            Task { @MainActor in URLCommandBus.shared.send(command) }
        }
    }

    /// Finder 双击 / `open -a Markable file.md` / 拖到 Dock 图标：
    /// 这类打开走 OFD（`odoc`）Apple Event，不是 URL scheme，必须在这里接。
    /// 交给窗口管理器：已打开就切标签页，有空标签就用它，否则**新开标签页**。
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let first = urls.first(where: { $0.isFileURL }) else { return }
        DocumentWindowManager.shared.open(first)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateLegacyDefaultsIfNeeded()
        configureHelpMenu()
        configureSystemEditItemCleanup()
        DocumentWindowManager.shared.makeInitialWindow()
        // 关掉系统窗口恢复：本应用自己决定打开哪篇文档（"恢复上次阅读"或显式指定的文件）。
        // 否则系统恢复的旧窗口会与新建的默认窗口并存 → 出现一个多余的空白「未命名」窗口。
        for window in NSApp.windows {
            window.isRestorable = false
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    private static let helpMenuSink = NSMenu(title: "MarkableHelpMenuSink")
    private static let helpMenuStripper = HelpMenuStripper()
    private var helpMenuObservation: NSKeyValueObservation?

    /// 去掉「编辑」菜单底部的系统项（自动填充 / 开始听写 / 表情与符号）。
    ///
    /// 这三项由 AppKit 在菜单打开前动态插入，SwiftUI 的 `Commands` 删不掉；
    /// 用 `NSMenuDelegate.menuWillOpen` 在显示前清理。SwiftUI 重建菜单会丢掉 delegate，
    /// 所以用低频定时器重新挂载（菜单项很少，开销可忽略）。
    private var systemEditCleanupTimer: Timer?
    private static let systemEditStripper = SystemEditItemStripper()

    private func configureSystemEditItemCleanup() {
        Self.systemEditStripper.attach()
        systemEditCleanupTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            MainActor.assumeIsolated {
                AppDelegate.systemEditStripper.attach()
            }
        }
    }

    /// 去掉「帮助」菜单里的**系统搜索框**（macOS 27 上对第三方应用不返回结果，留着误导用户）。
    /// macOS 会把搜索框插进 `NSApp.helpMenu`；把 `NSApp.helpMenu` 指向一个**不在主菜单里**的菜单
    /// （sink），搜索框就落到那个不可见菜单上；再清掉可见「帮助」菜单里残留的搜索项。
    /// SwiftUI 会在主菜单重建/开菜单时反复把 `helpMenu` 指回真实菜单，故用 KVO 持续纠偏 + 低频定时兜底。
    private func configureHelpMenu() {
        Self.enforceHelpMenu()
        helpMenuObservation = NSApp.observe(\.helpMenu, options: [.new]) { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AppDelegate.enforceHelpMenu() }
            }
        }
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated { AppDelegate.enforceHelpMenu() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    @MainActor
    private static func enforceHelpMenu() {
        if NSApp.helpMenu !== helpMenuSink { NSApp.helpMenu = helpMenuSink }
        guard let help = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "帮助" })?.submenu else { return }
        if help.delegate !== helpMenuStripper { help.delegate = helpMenuStripper }
        helpMenuStripper.strip(help)
    }

    /// 启动期隐藏设置窗口（见 `applicationWillFinishLaunching`）：首次命中即停。
    private var hiddenLaunchSettings = false

    private func hideLaunchSettingsWindowIfNeeded() {
        guard !hiddenLaunchSettings else { return }
        Task { @MainActor in
            for _ in 0..<500 {   // 最多 5 秒（10ms × 500），首次命中立刻结束
                try? await Task.sleep(nanoseconds: 10_000_000)
                guard let window = NSApp.windows.first(
                    where: { $0.identifier?.rawValue.contains("Settings") == true && $0.isVisible }
                ) else { continue }
                hiddenLaunchSettings = true
                window.animationBehavior = .none
                window.orderOut(nil)
                return
            }
        }
    }

    /// 打开文档时不要让 AppKit 另开"无标题"窗口（我们把它作为标签页并入当前窗口）。
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { DocumentWindowManager.shared.newTab() }
        return true
    }

    /// 声明不支持安全状态恢复（见 `applicationDidFinishLaunching` 里的说明）。
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    /// 把 SwiftPM 裸二进制时期（域 `Markable`）的偏好迁移到 bundle 域，避免升级后丢设置。
    private func migrateLegacyDefaultsIfNeeded() {
        let marker = "markable.migratedFromLegacyDomain"
        let current = UserDefaults.standard
        guard !current.bool(forKey: marker) else { return }
        if let legacy = UserDefaults(suiteName: "Markable") {
            let keys = ["markable.lastOpenedPath", "markable.theme", "markable.fontSize",
                        "markable.typography", "markable.paper", "markable.marginMM",
                        "markable.pdfHeader", "markable.pdfFooter", "markable.pdfIncludeTOC",
                        "markable.sidebarMode", "markable.ai.config"]
            for key in keys where current.object(forKey: key) == nil {
                if let value = legacy.object(forKey: key) { current.set(value, forKey: key) }
            }
        }
        current.set(true, forKey: marker)
    }

    /// 让「自定义工具栏…」可用（见 `CommandGroup(after: .toolbar)`）。
    @objc private func windowDidBecomeKey(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        window.toolbar?.allowsUserCustomization = true
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string),
              let command = URLCommand.parse(url) else { return }
        Task { @MainActor in URLCommandBus.shared.send(command) }
    }
}

/// 清理「编辑」菜单里由 AppKit 动态插入的系统项。
@MainActor
final class SystemEditItemStripper: NSObject, NSMenuDelegate {
    private static let blockedTitles: Set<String> = [
        "自动填充", "开始听写…", "开始听写", "表情与符号",
        // App 菜单里的「服务」子菜单：本应用没有可提供的服务，去掉这一项。
        "服务",
    ]

    /// 给主菜单的每个子菜单挂上 delegate（顺带清理一次）。
    func attach() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for item in mainMenu.items {
            guard let submenu = item.submenu else { continue }
            if submenu.delegate !== self { submenu.delegate = self }
            Self.strip(submenu)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        Self.strip(menu)
        Self.applyCheckmarks(to: menu)
    }

    /// 菜单勾选：由 AppKit 在菜单打开前按当前状态设置 `NSMenuItem.state`。
    ///
    /// SwiftUI `Commands` 的 Button 标题与 Toggle 状态都是构建时求值的，状态变化后
    /// 菜单项不会重建（表现为「侧栏已切、菜单仍勾旧项」）。这里每次打开菜单都重算，
    /// 侧栏 / 主题 / 版式三处勾选必然与当前状态一致。
    static func applyCheckmarks(to menu: NSMenu) {
        let state = AppState.shared
        let titles = menu.items.map(\.title)

        // 显示 → 侧栏（大纲 / 文件 / 隐藏侧边栏）
        if titles.contains("大纲"), titles.contains("文件") {
            let hidden = state.sidebarHidden
            let mode = state.sidebarMode
            for item in menu.items {
                switch item.title {
                case "大纲": item.state = (!hidden && mode == .outline) ? .on : .off
                case "文件": item.state = (!hidden && mode == .files) ? .on : .off
                case "隐藏侧边栏": item.state = hidden ? .on : .off
                default: break
                }
            }
        }

        // 版式 → 当前模板
        let presetTitles = Set(Typography.Preset.allCases.map(\.title))
        if titles.contains(where: presetTitles.contains) {
            let current = state.currentPreset.title
            for item in menu.items where presetTitles.contains(item.title) {
                item.state = item.title == current ? .on : .off
            }
        }

        // 主题 → 当前主题
        let themeTitles: [String: String] = ["system": "跟随系统", "light": "浅色", "dark": "深色"]
        if let currentThemeTitle = themeTitles[state.theme] {
            for item in menu.items where themeTitles.values.contains(item.title) {
                item.state = item.title == currentThemeTitle ? .on : .off
            }
        }
    }

    /// 移除被屏蔽的项，并清掉连续 / 结尾分隔线。
    static func strip(_ menu: NSMenu) {
        for item in menu.items.reversed() where blockedTitles.contains(item.title) {
            menu.removeItem(item)
        }
        var previousWasSeparator = false
        for item in menu.items {
            if item.isSeparatorItem, previousWasSeparator {
                menu.removeItem(item)
                continue
            }
            previousWasSeparator = item.isSeparatorItem
        }
        if let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(last)
        }
    }
}
