import SwiftUI
import AppKit

/// 设置窗口（⌘,）：把散落在工具栏里的显示/版式/导出参数收拢到一处。
/// 状态全部来自 `AppState`，与菜单栏、工具栏读写同一份数据。
///
/// 布局：内容**顶端对齐**、行距紧凑，窗口高度**随当前分页内容**变化（不预留大片空白）。
struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @State private var tab: Int

    init(initialTab: Int = 0) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $tab) {
            appearanceTab
                .tabItem { Label("外观", systemImage: "paintbrush") }
                .tag(0)
            typographyTab
                .tabItem {
                    Label {
                        Text("排版")
                    } icon: {
                        // 系统会把 TabView 里的 SF Symbol 替换成它的本地化描述
                        // （`textformat` → 「格式」、`character` → 「字」，包成 NSImage 也一样）。
                        // 这里用 Core Graphics 自绘一个「Aa」图标，不带 SF Symbol 元数据。
                        Image(nsImage: Self.textFormatIcon())
                    }
                }
                .tag(1)
            pageTab
                .tabItem { Label("导出", systemImage: "doc.richtext") }
                .tag(2)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)   // 高度由内容决定（不预留空白）
        .animation(.none, value: tab)
        // SwiftUI 的 TabView 默认拿当前分页的 label 当窗口标题，这里固定为「设置」。
        .onAppear { Self.pinWindowTitle() }
        .onChange(of: tab) { _, _ in
            // 稍后再设一次：TabView 会在本轮更新里写入分页名，需要覆盖它。
            DispatchQueue.main.async { Self.pinWindowTitle() }
        }
    }

    /// 把设置窗口标题固定为「设置」（不随分页变化）。
    /// 自绘「Aa」图标：TabView 会把 SF Symbol 渲染成它的本地化描述文字，
    /// 自绘图片不带符号元数据，因此能正常显示为图标。
    private static func textFormatIcon() -> NSImage {
        let size = NSSize(width: 20, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style,
            ]
            ("Aa" as NSString).draw(in: rect.insetBy(dx: 0, dy: 1), withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func pinWindowTitle() {
        for window in NSApp.windows
        where window.identifier?.rawValue.contains("Settings") == true && window.title != "设置" {
            window.title = "设置"
        }
    }

    /// 供测试/调试：当前分页的自然高度。
    static let paneWidth: CGFloat = 460

    // MARK: - 外观

    private var appearanceTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("主题") {
                Picker("主题", selection: $app.theme) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            row("字号") {
                HStack(spacing: 8) {
                    Slider(value: $app.fontSize, in: 11...24, step: 1).labelsHidden()
                    Text("\(Int(app.fontSize))")
                        .monospacedDigit()
                        .frame(width: 26, alignment: .trailing)
                }
            }
            Divider().padding(.vertical, 2)
            Toggle("文件变化时自动刷新（保持阅读位置）", isOn: $app.autoReload)
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    // MARK: - 排版

    private var typographyTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("版式模板") {
                Menu {
                    ForEach(Typography.Preset.allCases) { preset in
                        Button(app.currentPreset == preset ? "✓ \(preset.title)" : preset.title) {
                            app.applyPreset(preset)
                        }
                    }
                } label: {
                    Text(app.currentPreset.title)      // 不用 Picker：避免长列表滚动定位选中项
                }
            }
            row("字体") {
                Picker("字体", selection: $app.typography.family) {
                    ForEach(Typography.Family.allCases) { family in
                        Text(family.title).tag(family)
                    }
                }
                .labelsHidden()
            }
            row("行距") {
                HStack(spacing: 8) {
                    Slider(value: $app.typography.lineSpacing, in: 0...24, step: 1).labelsHidden()
                    Text("\(Int(app.typography.lineSpacing))").monospacedDigit().frame(width: 26, alignment: .trailing)
                }
            }
            row("段间距") {
                HStack(spacing: 8) {
                    Slider(value: $app.typography.paragraphSpacing, in: 0...24, step: 1).labelsHidden()
                    Text("\(Int(app.typography.paragraphSpacing))").monospacedDigit().frame(width: 26, alignment: .trailing)
                }
            }
            Divider().padding(.vertical, 2)
            Toggle("自动折行（行宽跟随窗口）", isOn: $app.typography.lineWrap)
            Toggle("无序列表显示项目符号（•）", isOn: $app.bulletLists)
            Toggle("首行缩进 2 字", isOn: firstLineIndentBinding)
            Toggle("标题编号（1 / 1.1 / 1.1.1）", isOn: $app.typography.headingNumbering)
            Toggle("代码块行号（复制时自动剔除）", isOn: $app.typography.codeLineNumbers)
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    // MARK: - 导出（纸张由导出选项/内置通道默认 A4）

    private var pageTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("页边距") {
                HStack(spacing: 8) {
                    Slider(value: $app.marginMM, in: 0...60, step: 5).labelsHidden()
                    Text("\(Int(app.marginMM)) mm").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
            }
            Divider().padding(.vertical, 2)
            row("页眉") {
                TextField("支持 {title} / {page} / {total}", text: $app.pdfHeader)
                    .textFieldStyle(.roundedBorder)
            }
            row("页脚") {
                TextField("留空则不显示", text: $app.pdfFooter)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle("导出 PDF 时插入目录页", isOn: $app.includeTOC)
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    // MARK: - 行布局（标签列右对齐，控件左对齐，整体顶端对齐）

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }

    // MARK: - 绑定

    private var firstLineIndentBinding: Binding<Bool> {
        Binding(
            get: { app.typography.firstLineIndent >= 1.5 },
            set: { app.typography.firstLineIndent = $0 ? 2 : 0 }
        )
    }
}
