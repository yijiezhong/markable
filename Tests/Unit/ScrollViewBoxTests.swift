import Testing
import Foundation
@testable import Markable

/// 空格翻屏的偏移计算（⇧空格向上）。
@Suite("ScrollViewBox")
struct ScrollViewBoxTests {
    @Test("向下翻约一屏")
    func pageDown() {
        let y = ScrollViewBox.pagedOffset(current: 0, height: 1000, maxY: 5000, direction: 1)
        #expect(y == 920)      // 1000 * 0.92
    }

    @Test("向上翻回顶部")
    func pageUp() {
        let y = ScrollViewBox.pagedOffset(current: 920, height: 1000, maxY: 5000, direction: -1)
        #expect(y == 0)
    }

    @Test("到达底部后不再越界")
    func clampBottom() {
        let y = ScrollViewBox.pagedOffset(current: 4800, height: 1000, maxY: 5000, direction: 1)
        #expect(y == 5000)
    }

    @Test("高度为 0 时保持不动")
    func zeroHeight() {
        #expect(ScrollViewBox.pagedOffset(current: 123, height: 0, maxY: 5000, direction: 1) == 123)
    }
}
