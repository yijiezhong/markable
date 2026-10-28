import Testing
import Foundation
@testable import Markable

/// 标题编号算法（大纲面板与渲染器共用）。
@Suite("HeadingNumbering")
struct HeadingNumberingTests {
    @Test("顺序编号")
    func sequential() {
        #expect(HeadingNumbering.numbers(levels: [1, 2, 2, 3, 1]) == ["1", "1.1", "1.2", "1.2.1", "2"])
    }

    @Test("回到上层后深层计数重置")
    func reset() {
        #expect(HeadingNumbering.numbers(levels: [1, 2, 1, 2]) == ["1", "1.1", "2", "2.1"])
    }

    @Test("越界层级被夹到 1...6")
    func clamp() {
        #expect(HeadingNumbering.numbers(levels: [0, 9]).count == 2)
    }

    @Test("空输入")
    func empty() {
        #expect(HeadingNumbering.numbers(levels: []).isEmpty)
    }
}
