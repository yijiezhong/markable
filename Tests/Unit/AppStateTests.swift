import Testing
import Foundation
@testable import Markable

/// 菜单/工具栏共用的应用状态与命令总线。
@MainActor
@Suite("AppState")
struct AppStateTests {
    /// 用临时 UserDefaults suite，避免污染真实偏好。
    private func makeState() -> AppState {
        let defaults = UserDefaults(suiteName: "markable.test.\(UUID().uuidString)")!
        return AppState(settings: SettingsStore(defaults: defaults))
    }

    @Test("页边距 / 行距 / 段间距的边界")
    func adjustments() {
        let app = makeState()
        app.marginMM = 55
        app.adjustMargin(by: 10)
        #expect(app.marginMM == 60)
        app.marginMM = 3
        app.adjustMargin(by: -10)
        #expect(app.marginMM == 0)

        app.typography.lineSpacing = 20
        app.adjustLineSpacing(by: 10)
        #expect(app.typography.lineSpacing == 24)
        app.typography.paragraphSpacing = 1
        app.adjustParagraphSpacing(by: -10)
        #expect(app.typography.paragraphSpacing == 0)
    }

    @Test("版式预设套用到排版参数")
    func presets() {
        let app = makeState()
        app.typography = Typography.preset(.academic)
        #expect(app.typography.family == .serif)
        #expect(app.typography.headingNumbering == true)
        app.typography = Typography.preset(.technical)
        #expect(app.typography.family == .mono)
        #expect(app.typography.headingNumbering == false)
    }

    @Test("状态写入设置存储（持久化生效）")
    func persistence() {
        let defaults = UserDefaults(suiteName: "markable.test.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        let app = AppState(settings: settings)

        app.theme = "dark"
        app.paper = .a3
        app.marginMM = 25
        app.includeTOC = true
        app.sidebarMode = .files
        app.typography.headingNumbering = true

        #expect(settings.themePreference == "dark")
        #expect(settings.paperRaw == PageSetup.Paper.a3.rawValue)
        #expect(settings.marginMM == 25)
        #expect(settings.pdfIncludeTOC == true)
        #expect(settings.sidebarModeRaw == SidebarMode.files.rawValue)
        #expect(settings.typography.headingNumbering == true)
    }

    @Test("自动刷新默认开，且可持久化")
    func autoReloadPersistence() {
        let defaults = UserDefaults(suiteName: "markable.test.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        let app = AppState(settings: settings)
        #expect(app.autoReload == true, "自动刷新默认应开启")
        app.autoReload = false
        #expect(settings.autoReload == false)
        let reloaded = AppState(settings: SettingsStore(defaults: defaults))
        #expect(reloaded.autoReload == false)
    }

    @Test("页眉页脚为空时不盖章")
    func stamp() {
        let app = makeState()
        app.pdfHeader = ""
        app.pdfFooter = ""
        #expect(app.currentStamp == nil)
        app.pdfFooter = "第 {page} 页"
        #expect(app.currentStamp?.footer == "第 {page} 页")
    }

    @Test("命令总线驱动的菜单纯状态项生效（回归：曾因未订阅总线而全部无反应）")
    func commandBusDrivesState() {
        let app = makeState()
        app.observeCommands()

        AppCommandBus.shared.send(.zoomIn)
        #expect(app.zoom > 1.0)

        AppCommandBus.shared.send(.setTheme("dark"))
        #expect(app.theme == "dark")

        AppCommandBus.shared.send(.setSidebar(.files))
        #expect(app.sidebarMode == .files)
        #expect(app.sidebarHidden == false)

        AppCommandBus.shared.send(.toggleSidebarHidden)
        #expect(app.sidebarHidden == true)

        AppCommandBus.shared.send(.applyPreset(.academic))
        #expect(app.typography.family == .serif)
        #expect(app.typography.headingNumbering == true)

        AppCommandBus.shared.send(.setPaper(.a3))
        #expect(app.paper == .a3)

        AppCommandBus.shared.send(.adjustMargin(5))
        #expect(app.marginMM == 25)

        AppCommandBus.shared.send(.toggleTOCPage)
        #expect(app.includeTOC == true)

        AppCommandBus.shared.send(.toggleFindOption(.isRegex))
        #expect(app.findOptions.isRegex == true)

        // 需要视图上下文的命令不由 AppState 处理
        #expect(app.handleStateCommand(.exportPDF) == false)
        #expect(app.handleStateCommand(.reloadFile) == false)
    }

    @Test("命令总线按序投递")
    func commandBus() {
        let bus = AppCommandBus()
        #expect(bus.pending == nil)
        bus.send(.exportPDF)
        let first = bus.pending
        #expect(first?.command == .exportPDF)
        bus.send(.zoomIn)
        #expect(bus.pending?.command == .zoomIn)
        #expect(bus.pending!.id > first!.id)
    }

    @Test("强制内置导出开关持久化到独立 suite")
    func forceBuiltinPDFExportPersists() {
        let defaults = UserDefaults(suiteName: "markable.test.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)

        let app = AppState(settings: settings)
        #expect(app.forceBuiltinPDFExport == false, "默认应走 md2pdf 优先策略")

        app.forceBuiltinPDFExport = true
        #expect(settings.forceBuiltinPDFExport == true)

        let reopened = AppState(settings: SettingsStore(defaults: defaults))
        #expect(reopened.forceBuiltinPDFExport == true, "重开设置应保留开关")
    }
}
