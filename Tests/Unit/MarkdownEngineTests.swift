import Testing
import Foundation
@testable import Markable

/// T011：Markdown 往返保真（解析 → 序列化）。
@Suite("MarkdownEngine")
struct MarkdownEngineTests {
    @Test("标题往返保真")
    func roundTripKeepsHeading() {
        let engine = MarkdownEngine()
        let source = "# 标题\n\n正文 **粗体** 与 `code`。\n"
        let out = engine.roundTrip(source)
        #expect(out.contains("# 标题"))
        #expect(out.contains("正文"))
        #expect(out.contains("**粗体**"))
        #expect(out.contains("`code`"))
    }

    @Test("空文档往返为空")
    func roundTripEmpty() {
        let engine = MarkdownEngine()
        #expect(engine.roundTrip("").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("大纲提取标题与层级")
    func outlineExtractsHeadings() {
        let engine = MarkdownEngine()
        let items = engine.outline(of: "# A\n\n## B\n\n### C\n")
        #expect(items.map(\.title) == ["A", "B", "C"])
        #expect(items.map(\.level) == [1, 2, 3])
    }
}
