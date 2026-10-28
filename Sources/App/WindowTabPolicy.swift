import Foundation

/// 打开文档时的标签页决策（纯函数，便于单测）。
///
/// 与 `DocumentWindowManager.open` 的约定一致：
/// 1. 文件已打开 → 切到已有标签；
/// 2. 存在空标签（尚未打开文件）→ 复用它；
/// 3. 否则 → 新标签页。
///
/// 为什么单独抽出来：窗口决策藏在 `NSWindow` 生命周期里，过去只能靠人工点验；
/// 抽成纯函数后「同文件切标签 / 空标签复用 / 新开」这三条规则可以被测试守住。
enum WindowTabPolicy {
    enum Decision: Equatable {
        case switchTo(index: Int)
        case reuseEmpty(index: Int)
        case newTab
    }

    static func decide(existingURLs: [URL?], opening url: URL) -> Decision {
        let target = url.standardizedFileURL
        if let index = existingURLs.firstIndex(where: { $0?.standardizedFileURL == target }) {
            return .switchTo(index: index)
        }
        if let index = existingURLs.firstIndex(where: { $0 == nil }) {
            return .reuseEmpty(index: index)
        }
        return .newTab
    }
}
