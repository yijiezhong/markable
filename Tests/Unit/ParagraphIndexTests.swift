import Testing
import Foundation
@testable import Markable

/// 段落索引：⌥↑ / ⌥↓ 的跳转目标。
@Suite("ParagraphIndex")
struct ParagraphIndexTests {
    private let text = "第一段\n\n第二段\n第二段续行\n\n第三段\n"

    @Test("按空行切分，给出每个段落起点")
    func starts() {
        #expect(ParagraphIndex.starts(in: text) == [0, 5, 16])
    }

    @Test("下一段 / 上一段")
    func target() {
        #expect(ParagraphIndex.target(in: text, from: 0, direction: 1) == 5)
        #expect(ParagraphIndex.target(in: text, from: 10, direction: 1) == 16)
        #expect(ParagraphIndex.target(in: text, from: 10, direction: -1) == 5)
    }

    @Test("边界：首段之前 / 末段之后没有目标")
    func boundaries() {
        #expect(ParagraphIndex.target(in: text, from: 0, direction: -1) == nil)
        #expect(ParagraphIndex.target(in: text, from: 999, direction: 1) == nil)
    }

    @Test("空文本无段落")
    func empty() {
        #expect(ParagraphIndex.starts(in: "").isEmpty)
        #expect(ParagraphIndex.target(in: "", from: 0, direction: 1) == nil)
    }
}
