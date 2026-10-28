import Testing
import Foundation
@testable import Markable

/// front matter 驱动导出设置。
@Suite("ExportConfig")
struct ExportConfigTests {
    private let base = ExportConfig(title: "未命名", pageSetup: PageSetup(), stamp: nil, includeTOC: false)

    @Test("front matter 覆盖标题/纸张/页边距/页脚/目录页")
    func overrides() {
        let fm = FrontMatter.parse("""
        ---
        title: 我的报告
        paper: a3
        margin: 15
        footer: 第 {page} 页
        toc: true
        ---
        # 正文
        """)
        let config = base.applying(frontMatter: fm)
        #expect(config.title == "我的报告")
        #expect(config.pageSetup.paper == .a3)
        #expect(config.pageSetup.marginMM == 15)
        #expect(config.stamp?.footer == "第 {page} 页")
        #expect(config.includeTOC == true)
    }

    @Test("无 front matter 时保持默认")
    func noFrontMatter() {
        let config = base.applying(frontMatter: [:])
        #expect(config == base)
    }

    @Test("页眉与页脚可只给其一")
    func partialStamp() {
        let config = base.applying(frontMatter: ["header": "{title}"])
        #expect(config.stamp?.header == "{title}")
        #expect(config.stamp?.footer == "")
    }

    @Test("非法纸张名忽略")
    func invalidPaper() {
        let config = base.applying(frontMatter: ["paper": "b5"])
        #expect(config.pageSetup.paper == .a4)
    }
}
