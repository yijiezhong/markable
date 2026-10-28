import Testing
import Foundation
@testable import Markable

/// 交叉引用：标题锚点收集与"引用式定义"判别。
@Suite("CrossReference")
struct CrossReferenceTests {
    @Test("标题末尾 [标签] 作为锚点，且不进标题文本")
    func targets() {
        let text = """
        # 第一章 [ch1]

        正文。

        ## 细节 **重点** [detail]
        """
        let map = CrossReference.targets(in: text)
        #expect(map["ch1"] == "第一章")
        // 标题里的行内标记会被清除，便于按纯文本跳转
        #expect(map["detail"] == "细节 重点")
    }

    @Test("识别引用式链接定义")
    func definition() {
        let text = "[ref]: https://example.com\n\n[文字][ref]\n"
        #expect(CrossReference.hasDefinition("ref", in: text))
        #expect(!CrossReference.hasDefinition("missing", in: text))
    }

    @Test("普通标题不产生锚点")
    func noLabels() {
        #expect(CrossReference.targets(in: "# 只是标题\n").isEmpty)
    }

    @Test("大纲标题去掉末尾交叉引用标签")
    func outlineStripsLabel() {
        let items = MarkdownEngine().outline(of: "# 第一节内容 [sec1]\n")
        #expect(items.first?.title == "第一节内容")
    }
}
