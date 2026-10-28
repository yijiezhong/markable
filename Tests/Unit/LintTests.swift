import Testing
import Foundation
@testable import Markable

/// 文档体检：14 类确定性规则。
@Suite("Lint")
struct LintTests {
    private func messages(_ text: String) -> [String] {
        Lint.check(text).map(\.message)
    }
    private func has(_ text: String, _ needle: String) -> Bool {
        messages(text).contains { $0.contains(needle) }
    }

    @Test("干净文档无提示")
    func clean() {
        #expect(Lint.check("# 标题\n\n正文。\n").isEmpty)
    }

    @Test("① 行尾单个空格")
    func trailingSpace() {
        #expect(has("正文 \n", "行尾多了一个空格"))
        // 两个空格是硬换行标记，不算问题
        #expect(!has("正文  \n", "行尾多了一个空格"))
    }

    @Test("② 连续空行")
    func blankLines() {
        #expect(has("A\n\n\n\nB\n", "连续"))
    }

    @Test("③ 超长句")
    func longSentence() {
        let long = String(repeating: "字", count: 320)
        #expect(has(long + "。\n", "超长句"))
    }

    @Test("④ 行内数学定界符为奇数")
    func oddDollar() {
        #expect(has("价格是 $5 元\n", "行内数学定界符"))
        #expect(!has("价格是 $5$ 元\n", "行内数学定界符"))
    }

    @Test("⑤ 块级数学定界不配对")
    func blockMath() {
        #expect(has("\\[ x = 1\n", "块级数学定界符"))
    }

    @Test("⑥ 代码围栏未闭合")
    func fenceUnclosed() {
        #expect(has("```\ncode\n", "代码围栏"))
    }

    @Test("⑦ 行内代码反引号未闭合")
    func inlineCode() {
        #expect(has("这是 `code 未闭合\n", "行内代码反引号"))
    }

    @Test("⑧ 未定义的脚注引用")
    func undefinedFootnote() {
        #expect(has("引用[^missing]。\n", "未定义的脚注"))
    }

    @Test("⑨ 未被引用的脚注定义")
    func unusedFootnote() {
        #expect(has("[^unused]: 定义。\n", "未被引用"))
    }

    @Test("⑩ 未定义的引用式链接")
    func undefinedRefLink() {
        #expect(has("[文字][missing]\n", "未定义的链接"))
    }

    @Test("⑪ 未被引用的链接定义（脚注定义不算）")
    func unusedRefLink() {
        #expect(has("[ref]: https://example.com\n", "未被引用"))
        // 脚注定义不应被当作"链接定义"报未引用
        #expect(!messages("[^note]: 脚注内容。\n").contains { $0.contains("链接定义") })
    }

    @Test("交叉引用标签不算未定义链接")
    func crossReferenceLabels() {
        let text = "# 结论 [sec]\n\n见 [结论][sec]。\n"
        #expect(!has(text, "未定义的链接"))
    }

    @Test("⑫ 标题层级跳跃")
    func headingJump() {
        #expect(has("# 一级\n\n### 三级\n", "标题层级跳跃"))
        #expect(!has("# 一级\n\n## 二级\n", "标题层级跳跃"))
    }

    @Test("⑬ 空链接目标")
    func emptyLinkTarget() {
        #expect(has("见 [文字]()\n", "目标为空"))
    }

    @Test("⑭ 图片缺少替代文本")
    func imageNoAlt() {
        #expect(has("![](img.png)\n", "缺少替代文本"))
        #expect(!has("![替代](img.png)\n", "缺少替代文本"))
    }

    @Test("代码围栏内的内容不体检")
    func skipFenceContent() {
        let text = "```\nprice is $5\n![](x.png)\n```\n"
        let found = Lint.check(text)
        #expect(!found.contains { $0.message.contains("行内数学") })
        #expect(!found.contains { $0.message.contains("替代文本") })
    }

    @Test("行号定位")
    func lineNumbers() {
        let issues = Lint.check("第一行\n第二行 \n")
        #expect(issues.contains { $0.line == 2 })
    }
}
