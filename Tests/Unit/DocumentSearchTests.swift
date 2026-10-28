import Testing
import Foundation
@testable import Markable

/// 文档内查找：大小写 / 整词 / 正则 / 行号。
@Suite("DocumentSearch")
struct DocumentSearchTests {
    private let text = """
    Swift is fast.
    swift is safe.
    Ordering is important.
    """

    @Test("默认不区分大小写")
    func caseInsensitive() {
        let matches = DocumentSearch.matches(in: text, query: "swift")
        #expect(matches.count == 2)
        #expect(matches[0].line == 1)
        #expect(matches[1].line == 2)
    }

    @Test("区分大小写")
    func caseSensitive() {
        let matches = DocumentSearch.matches(in: text, query: "swift", options: SearchOptions(caseSensitive: true))
        #expect(matches.count == 1)
        #expect(matches[0].line == 2)
    }

    @Test("整词匹配排除子串")
    func wholeWord() {
        // "Ordering" 含 "order" 子串；整词模式下不应命中。
        let loose = DocumentSearch.matches(in: text, query: "order")
        #expect(loose.count == 1)
        let strict = DocumentSearch.matches(in: text, query: "order", options: SearchOptions(wholeWord: true))
        #expect(strict.isEmpty)
    }

    @Test("正则匹配")
    func regex() {
        let matches = DocumentSearch.matches(in: text, query: "sw\\w+", options: SearchOptions(isRegex: true))
        #expect(matches.count == 2)      // 默认不区分大小写：Swift 与 swift 各一次
    }

    @Test("字面量特殊字符不当作正则")
    func literalMetacharacters() {
        let sample = "a.b and axb"
        let matches = DocumentSearch.matches(in: sample, query: "a.b")
        #expect(matches.count == 1)      // 只有 a.b，不含 axb
    }

    @Test("查找循环索引（⌘G / ⇧⌘G）")
    func nextIndexWrap() {
        #expect(DocumentSearch.nextIndex(current: 0, count: 3, direction: 1) == 1)
        #expect(DocumentSearch.nextIndex(current: 2, count: 3, direction: 1) == 0)   // 末尾回绕
        #expect(DocumentSearch.nextIndex(current: 0, count: 3, direction: -1) == 2)  // 反向回绕
        #expect(DocumentSearch.nextIndex(current: 0, count: 0, direction: 1) == 0)   // 无结果
    }

    @Test("空查询返回空")
    func empty() {
        #expect(DocumentSearch.matches(in: text, query: "").isEmpty)
    }
}
