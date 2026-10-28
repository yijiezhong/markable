import Testing
import Foundation
@testable import Markable

/// T012：live-preview 属性映射 + 行内语法识别。
@Suite("LivePreview & InlineSyntax")
struct LivePreviewTests {
    @Test("光标所在段落保持源码态，其余为渲染态")
    func cursorParagraphStaysSource() {
        let text = "# 标题\n\n第二段 **粗体** 文本\n"
        let styled = InlineSyntax.ranges(in: text) + BlockSyntax.ranges(in: text)
        let ns = text as NSString
        // 光标放在第二段的 "粗体" 附近
        let cursor = ns.range(of: "粗体")
        let plan = LivePreview.plan(text: text, styled: styled, cursor: cursor)

        // 光标段落 = 第二段（含 "第二段"）
        let sourceText = ns.substring(with: plan.sourceParagraph)
        #expect(sourceText.contains("第二段"))

        // 渲染态范围不得与光标段落相交
        for r in plan.renderedRanges {
            #expect(NSIntersectionRange(r, plan.sourceParagraph).length == 0)
        }
    }

    @Test("识别粗体与行内代码")
    func detectsBoldAndCode() {
        let ranges = InlineSyntax.ranges(in: "a **b** c `d` e")
        #expect(ranges.contains { $0.kind == .bold })
        #expect(ranges.contains { $0.kind == .code })
    }

    @Test("标题按层级识别")
    func detectsHeadings() {
        let ranges = BlockSyntax.ranges(in: "# H1\n## H2\n")
        let levels = ranges.compactMap { if case .heading(let l) = $0.kind { return l } else { return nil } }
        #expect(levels == [1, 2])
    }

    @Test("代码块跨行识别")
    func detectsCodeBlock() {
        let ranges = BlockSyntax.ranges(in: "前\n```swift\nlet a = 1\n```\n后\n")
        #expect(ranges.contains { $0.kind == .codeBlock })
    }
}
