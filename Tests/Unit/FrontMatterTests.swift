import Testing
import Foundation
@testable import Markable

/// front matter：解析、剥离，以及"不被当成 setext 标题"的回归。
@Suite("FrontMatter")
struct FrontMatterTests {
    private let doc = """
    ---
    title: 标题
    paper: a4
    ---
    # 真标题

    正文
    """

    @Test("解析键值（键小写）")
    func parse() {
        let values = FrontMatter.parse(doc)
        #expect(values["title"] == "标题")
        #expect(values["paper"] == "a4")
    }

    @Test("剥离 front matter 得到正文")
    func strip() {
        let body = MarkdownEngine.strippingFrontMatter(doc)
        #expect(body.hasPrefix("# 真标题"))
        #expect(!body.contains("title: 标题"))
    }

    @Test("无 front matter 时原样返回")
    func noFrontMatter() {
        #expect(MarkdownEngine.strippingFrontMatter("# 标题\n") == "# 标题\n")
    }

    @Test("大纲不含 front matter（回归：--- 曾被当作 setext 下划线）")
    func outlineSkipsFrontMatter() {
        let items = MarkdownEngine().outline(of: doc)
        #expect(items.count == 1)
        #expect(items[0].title == "真标题")
    }

    @Test("HTML 导出不含 front matter")
    func htmlExcludesFrontMatter() {
        let html = HtmlRenderer().html(from: doc, title: "t")
        #expect(!html.contains("title: 标题"))
        #expect(html.contains("真标题"))
    }

    @Test("文件开头的 front matter 仍被识别为 frontMatter 块")
    func leadingFrontMatterStillDetected() {
        let text = "---\ntitle: 标题\n---\n# 正文\n"
        let frontMatter = BlockSyntax.ranges(in: text).filter { $0.kind == .frontMatter }
        #expect(frontMatter.count == 1)
        #expect(frontMatter.first?.range.location == 0)
    }

    @Test("文档中部的 --- 是分割线，不能被当成 front matter（回归：摘要曾被整段隐藏）")
    func middleDashesAreNotFrontMatter() {
        let text = """
        # 标题

        > 引用

        ---

        ## 摘要

        正文内容

        ---

        ## 下一节
        """
        let frontMatter = BlockSyntax.ranges(in: text).filter { $0.kind == .frontMatter }
        #expect(frontMatter.isEmpty, "中部的 --- 不应产生 frontMatter 块")
    }
}
