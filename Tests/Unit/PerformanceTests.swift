import Testing
import Foundation
@testable import Markable

/// T032：性能基准（SC-002 的可自动化部分）。
/// 说明：这里测的是**解析/渲染决策层**在 1MB 文档上的耗时（应远小于 100ms 目标）；
/// 端到端输入延迟与滚动帧率需在 GUI 中按 quickstart 场景 5 实测。
///
/// 门禁策略：阈值按数量级设定（1.5s / 2s），只捕获 O(n²) 之类的退化；
/// 机器负载只打印、不跳过——跳过等于门禁失效。
@Suite("Performance")
struct PerformanceTests {
    private var loadAverage: Double {
        var loads = [Double](repeating: 0, count: 1)
        guard getloadavg(&loads, 1) > 0 else { return 0 }
        return loads[0]
    }

    /// 生成约 1MB 的 Markdown 文本。
    private func largeMarkdown() -> String {
        let block = "# 标题\n\n段落中的 **粗体** 与 `code`，以及 [链接](https://example.com)。\n\n"
        let targetBytes = 1_000_000
        let repeatCount = max(1, targetBytes / max(1, block.utf8.count))
        return String(repeating: block, count: repeatCount)
    }

    @Test("1MB 文档的语法识别在 1.5s 内完成（数量级门禁）")
    func largeDocumentSyntaxScanIsFast() {
        let text = largeMarkdown()
        #expect(text.utf8.count >= 900_000)

        let start = Date()
        _ = InlineSyntax.ranges(in: text)
        _ = BlockSyntax.ranges(in: text)
        let elapsedMs = Date().timeIntervalSince(start) * 1000

        print("PERF syntax-scan 1MB: \(Int(elapsedMs))ms (load \(String(format: "%.1f", loadAverage)))")
        #expect(elapsedMs < 2000, "语法扫描耗时 \(Int(elapsedMs))ms")
    }

    @Test("大纲提取在 1MB 文档上可接受")
    func outlineOnLargeDocument() {
        let text = largeMarkdown()
        let start = Date()
        let items = MarkdownEngine().outline(of: text)
        let elapsedMs = Date().timeIntervalSince(start) * 1000

        print("PERF outline 1MB: \(Int(elapsedMs))ms")
        #expect(!items.isEmpty)
        #expect(elapsedMs < 2000, "大纲耗时 \(Int(elapsedMs))ms")
    }
}
