import AppKit
import Testing
@testable import Markable

/// 技术债清理的回归测试：列表项目符号开关、引用竖线、数学占位、Mermaid 不支持提示、快照目录。
@MainActor
@Suite("DebtFixes")
struct DebtFixesTests {
    private func render(_ source: String, bulletLists: Bool = false) -> NSTextStorage {
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.textContainer?.containerSize = NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        LivePreviewController().apply(to: textView, source: source, baseDirectory: nil,
                                      readOnly: true, fontSize: 14, typography: Typography(),
                                      bulletLists: bulletLists)
        return textView.textStorage!
    }

    private func attachmentCount(_ storage: NSTextStorage) -> Int {
        var count = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if value != nil { count += 1 }
        }
        return count
    }

    @Test("默认保留无序列表标记（-）")
    func bulletListsOffKeepsMarker() {
        let storage = render("- 苹果\n- 香蕉\n")
        #expect(storage.string.contains("- 苹果"))
        #expect(!storage.string.contains("•"))
    }

    @Test("开启项目符号后 - 变为 •")
    func bulletListsOnUsesBullet() {
        let storage = render("- 苹果\n- 香蕉\n", bulletLists: true)
        #expect(storage.string.contains("• 苹果"))
        #expect(!storage.string.contains("- 苹果"))
    }

    @Test("任务列表开启项目符号后不再显示短横线")
    func taskListWithoutDash() {
        let storage = render("- [ ] 未完成\n- [x] 已完成\n", bulletLists: true)
        let text = storage.string
        #expect(text.contains("☐ 未完成"))
        #expect(text.contains("☑ 已完成"))
        #expect(!text.contains("- "))
    }

    @Test("引用块每行插入左侧竖线（文本字符，随行高）")
    func blockquoteHasBarGlyph() {
        let storage = render("> 一级引用\n> 二级引用\n")
        // 引用内软换行按既有行为接排，只需一个行首竖线
        let bars = storage.string.filter { $0 == "│" }.count
        #expect(bars >= 1, "引用行首应有竖线字符，实际 \(bars)")
    }

    @Test("数学公式未命中缓存时先显示占位，不闪现源码")
    func mathPlaceholderBeforeRender() {
        let storage = render("行内公式 $\\uniqueDebtFixMath_{42}$ 与正文。")
        let text = storage.string
        #expect(text.contains("⋯"), "未渲染完成的公式应显示占位")
        #expect(!text.contains("uniqueDebtFixMath"), "占位期间不应显示公式源码")
    }

    @Test("Mermaid 渲染失败给出回退提示")
    func unsupportedMermaidHint() {
        // zenuml 现在有自研渲染器：只给首行（没有消息）会渲染失败，走「回退源码」分支。
        let storage = render("```mermaid\nzenuml\n```\n")
        #expect(storage.string.contains("已回退源码"), "Mermaid 渲染失败应回退源码并给出提示")
    }

    @Test("快照目录可配置，默认落在 .build/snapshots")
    func snapshotDirectory() {
        #expect(SnapshotSupport.outputDirectory.path.contains("snapshots"))
    }
}
