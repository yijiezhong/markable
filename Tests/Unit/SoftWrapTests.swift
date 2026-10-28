import Testing
import Foundation
@testable import Markable

/// 软换行接排（Markdown 段落内单换行的语义）。
@Suite("SoftWrap")
struct SoftWrapTests {
    /// 应用接排后的文本（模拟替换阶段）。
    private func wrapped(_ text: String) -> String {
        var result = text
        for join in SoftWrap.joins(in: text).sorted(by: { $0.range.location > $1.range.location }) {
            let ns = result as NSString
            guard join.range.location + join.range.length <= ns.length else { continue }
            result = ns.replacingCharacters(in: join.range, with: join.replacement)
        }
        return result
    }

    @Test("英文段落内换行接成空格")
    func englishParagraph() {
        #expect(wrapped("hello\nworld\n") == "hello world\n")
    }

    @Test("中文段落内换行不插空格")
    func cjkParagraph() {
        #expect(wrapped("这是一段\n中文文字\n") == "这是一段中文文字\n")
    }

    @Test("空行分段不接排")
    func paragraphBreak() {
        #expect(wrapped("第一段\n\n第二段\n") == "第一段\n\n第二段\n")
    }

    @Test("标题后不接排")
    func afterHeading() {
        #expect(wrapped("# 标题\n正文\n") == "# 标题\n正文\n")
    }

    @Test("列表项各自成行")
    func listItems() {
        #expect(wrapped("- 一\n- 二\n") == "- 一\n- 二\n")
    }

    @Test("引用块续行接排（保留 > 前缀于首行）")
    func blockquote() {
        #expect(wrapped("> 引用第一行\n> 引用第二行\n") == "> 引用第一行引用第二行\n")
    }

    @Test("引用块与普通段落不混接")
    func quoteThenParagraph() {
        #expect(wrapped("> 引用\n正文\n") == "> 引用\n正文\n")
    }

    @Test("硬换行（行尾两空格）保留")
    func hardBreak() {
        #expect(wrapped("第一行  \n第二行\n") == "第一行  \n第二行\n")
    }

    @Test("代码围栏内不接排")
    func fencedCode() {
        let text = "```\nline1\nline2\n```\n"
        #expect(wrapped(text) == text)
    }

    @Test("续行前导缩进被吃掉")
    func leadingIndent() {
        #expect(wrapped("hello\n    world\n") == "hello world\n")
    }

    @Test("front matter 不接排")
    func frontMatter() {
        let text = "---\ntitle: 标题\npaper: a4\n---\n正文\n"
        #expect(wrapped(text) == text)
    }

    @Test("HTML 注释不接排")
    func htmlComment() {
        let text = "<!--\n多行\n注释\n-->\n正文\n"
        #expect(wrapped(text) == text)
    }

    @Test("块级数学不接排")
    func blockMath() {
        let text = "$$\na = b\nc = d\n$$\n"
        #expect(wrapped(text) == text)
    }
}
