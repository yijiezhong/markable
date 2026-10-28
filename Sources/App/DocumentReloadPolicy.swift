import Foundation

/// 外部文件变化后是否重新载入（纯函数，便于测试）。
///
/// 规则：
/// - 用户主动「强制刷新」→ 总是重载并重渲染；
/// - 自动刷新 → 只在 mtime/size 变化**且内容确实不同**时重载
///   （避免 `touch` 或编辑器写回相同内容触发无意义重排）。
enum DocumentReloadPolicy {
    static func shouldReload(
        force: Bool = false,
        lastMtime: Date?,
        currentMtime: Date?,
        lastSize: Int,
        currentSize: Int,
        contentChanged: Bool
    ) -> Bool {
        if force { return true }
        guard let lastMtime, let currentMtime else { return false }
        guard currentMtime != lastMtime || currentSize != lastSize else { return false }
        return contentChanged
    }
}
