import Foundation
import Testing
@testable import Markable

/// 打开文档时的标签页决策：同文件切标签 / 空标签复用 / 新开标签。
@Suite("WindowTabPolicy")
struct WindowTabPolicyTests {
    private let a = URL(fileURLWithPath: "/tmp/markable-tab-a.md")
    private let b = URL(fileURLWithPath: "/tmp/markable-tab-b.md")

    @Test("已打开的文件 → 切到已有标签")
    func switchToExisting() {
        let decision = WindowTabPolicy.decide(
            existingURLs: [a, b, nil],
            opening: URL(fileURLWithPath: "/tmp/./markable-tab-b.md")   // 标准化后与 b 相同
        )
        #expect(decision == .switchTo(index: 1))
    }

    @Test("没有空标签时才新开")
    func newTabWhenNoEmpty() {
        let decision = WindowTabPolicy.decide(existingURLs: [a, b], opening: URL(fileURLWithPath: "/tmp/c.md"))
        #expect(decision == .newTab)
    }

    @Test("有空标签 → 复用第一个空标签")
    func reuseEmpty() {
        let decision = WindowTabPolicy.decide(existingURLs: [a, nil, nil], opening: b)
        #expect(decision == .reuseEmpty(index: 1))
    }

    @Test("空窗口列表 → 新开标签")
    func emptyList() {
        let decision = WindowTabPolicy.decide(existingURLs: [], opening: a)
        #expect(decision == .newTab)
    }
}
