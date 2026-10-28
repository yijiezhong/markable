import Testing
import Foundation
@testable import Markable

/// 纸张 / 页边距设置：CSS `@page` 规则与导出 HTML 的注入。
@Suite("PageSetup")
struct PageSetupTests {
    @Test("A4 默认规则")
    func a4Default() {
        let setup = PageSetup()
        #expect(setup.cssRule == "@page { size: A4; margin: 20mm; }")
    }

    @Test("各纸张关键字")
    func paperKeywords() {
        #expect(PageSetup(paper: .a3, marginMM: 15).cssRule == "@page { size: A3; margin: 15mm; }")
        #expect(PageSetup(paper: .letter, marginMM: 30).cssRule == "@page { size: letter; margin: 30mm; }")
        #expect(PageSetup(paper: .legal, marginMM: 10).cssRule == "@page { size: legal; margin: 10mm; }")
    }

    @Test("流式不约束纸张尺寸")
    func flowOmitsSize() {
        #expect(PageSetup(paper: .flow, marginMM: 20).cssRule == "@page { margin: 20mm; }")
    }

    @Test("注入导出 HTML")
    func injectedIntoHTML() {
        let html = HtmlRenderer().html(from: "# 标题\n", title: "t", pageSetup: .init(paper: .a5, marginMM: 25))
        #expect(html.contains("@page { size: A5; margin: 25mm; }"))
    }

    @Test("不传设置时不注入 @page")
    func absentWhenNil() {
        let html = HtmlRenderer().html(from: "# 标题\n", title: "t")
        #expect(!html.contains("@page"))
    }

    @Test("纸张点尺寸（A4 纵向）")
    func pointSize() {
        let size = PageSetup.Paper.a4.pointSize
        #expect(abs(size.width - 595.28) < 0.1)
        #expect(abs(size.height - 841.89) < 0.1)
    }

    @Test("内容区尺寸扣除四边页边距")
    func contentSize() {
        let setup = PageSetup(paper: .a4, marginMM: 20)
        let margin = CGFloat(20) * 72.0 / 25.4
        let paper = PageSetup.Paper.a4.pointSize
        #expect(abs(setup.contentSize.width - (paper.width - margin * 2)) < 0.01)
        #expect(abs(setup.contentSize.height - (paper.height - margin * 2)) < 0.01)

        // 边距变大 → 内容区变小；流式纸张与其他纸张一样按点尺寸计算。
        #expect(setup.contentSize.height > PageSetup(paper: .a4, marginMM: 40).contentSize.height)
        #expect(PageSetup(paper: .flow, marginMM: 20).contentSize.width > 0)
        // 极端边距不会得到负尺寸。
        #expect(PageSetup(paper: .a5, marginMM: 500).contentSize.width > 0)
    }
}
