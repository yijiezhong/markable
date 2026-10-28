import Foundation

/// 应用设置：全部配置入 UserDefaults（不存储任何凭据）。
final class SettingsStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 上次关闭窗口时是否处于最大化。
    /// 默认 `true`：**首次运行（无记录）默认最大化**；之后沿用上次关闭前的状态。
    var windowMaximized: Bool {
        get { defaults.object(forKey: "markable.windowMaximized") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "markable.windowMaximized") }
    }

    /// 最近打开的文件路径（最多 10 条，供菜单「打开最近」）。
    var recentPaths: [String] {
        get { defaults.stringArray(forKey: "markable.recentPaths") ?? [] }
        set { defaults.set(newValue, forKey: "markable.recentPaths") }
    }

    /// 上次打开的文件路径（用于启动时自动恢复）。
    var lastOpenedPath: String? {
        get { defaults.string(forKey: "markable.lastOpenedPath") }
        set { defaults.set(newValue, forKey: "markable.lastOpenedPath") }
    }

    /// 主题偏好：system / light / dark。
    var themePreference: String {
        get { defaults.string(forKey: "markable.theme") ?? "system" }
        set { defaults.set(newValue, forKey: "markable.theme") }
    }

    /// 侧栏当前面板（SidebarMode.rawValue）。
    var sidebarModeRaw: String? {
        get { defaults.string(forKey: "markable.sidebarMode") }
        set { defaults.set(newValue, forKey: "markable.sidebarMode") }
    }

    /// 导出 PDF 的页眉模板（支持 {title}/{page}/{total}）。
    var pdfHeader: String {
        get { defaults.string(forKey: "markable.pdfHeader") ?? "" }
        set { defaults.set(newValue, forKey: "markable.pdfHeader") }
    }

    /// 导出 PDF 的页脚模板。
    var pdfFooter: String {
        get { defaults.string(forKey: "markable.pdfFooter") ?? "" }
        set { defaults.set(newValue, forKey: "markable.pdfFooter") }
    }

    /// 导出 PDF 时是否在最前插入目录页。
    var pdfIncludeTOC: Bool {
        get { defaults.object(forKey: "markable.pdfIncludeTOC") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "markable.pdfIncludeTOC") }
    }

    /// 导出 PDF 时是否强制使用内置通道（让纸张/页边距/页眉页脚/目录页设置生效）。
    var forceBuiltinPDFExport: Bool {
        get { defaults.object(forKey: "markable.forceBuiltinPDFExport") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "markable.forceBuiltinPDFExport") }
    }

    /// 正文字号。
    var fontSize: Double {
        get { defaults.object(forKey: "markable.fontSize") as? Double ?? 14 }
        set { defaults.set(newValue, forKey: "markable.fontSize") }
    }

    /// 视图缩放（0.5–3.0，1.0 = 实际大小）。
    var zoom: Double {
        get { defaults.object(forKey: "markable.zoom") as? Double ?? 1.0 }
        set { defaults.set(newValue, forKey: "markable.zoom") }
    }

    /// 导出纸张（PageSetup.Paper.rawValue）。
    var paperRaw: String {
        get { defaults.string(forKey: "markable.paper") ?? PageSetup.Paper.a4.rawValue }
        set { defaults.set(newValue, forKey: "markable.paper") }
    }

    /// 页边距（毫米）。
    var marginMM: Double {
        get { defaults.object(forKey: "markable.marginMM") as? Double ?? 20 }
        set { defaults.set(newValue, forKey: "markable.marginMM") }
    }

    /// 排版参数（字体族 / 行距 / 段间距 / 首行缩进）。
    var typography: Typography {
        get {
            guard let data = defaults.data(forKey: "markable.typography"),
                  let value = try? JSONDecoder().decode(Typography.self, from: data) else {
                return Typography()
            }
            return value
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "markable.typography")
            }
        }
    }

    /// 无序列表是否渲染为项目符号（`•`）；默认关闭 = 保留 Markdown 标记。
    var bulletLists: Bool {
        get { defaults.object(forKey: "markable.bulletLists") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "markable.bulletLists") }
    }

    /// 文件变化时自动刷新（默认开）。
    var autoReload: Bool {
        get { defaults.object(forKey: "markable.autoReload") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "markable.autoReload") }
    }
}
