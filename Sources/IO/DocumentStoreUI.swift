import Foundation
import AppKit

/// 文件操作 + 冲突提示（T027）。
/// 冲突时**不写入**并提示用户（FR-007、宪法 I）。
@MainActor
final class DocumentStoreUI {
    private let store: FileDocumentStore

    init(store: FileDocumentStore = FileDocumentStore()) {
        self.store = store
    }

    /// 保存文档。成功返回 true 并更新 document；冲突或失败返回 false。
    @discardableResult
    func save(_ document: inout Document, to url: URL) -> Bool {
        let expected = document.externalModifiedAt
            .map { Int64($0.timeIntervalSince1970 * 1000) }
            ?? FileDocumentStore.mtimeMs(of: url)
        do {
            let outcome = try store.save(document, to: url, expectedMtimeMs: expected)
            switch outcome {
            case .saved:
                document.savedContent = document.content
                document.path = url
                return true
            case .conflict(let currentMtimeMs):
                presentConflict(currentMtimeMs: currentMtimeMs)
                return false
            }
        } catch {
            presentError(error)
            return false
        }
    }

    private func presentConflict(currentMtimeMs: Int64) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "文件已被外部修改"
        alert.informativeText = "磁盘上的文件在编辑期间发生了变化。为避免覆盖，本次保存已取消。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "保存失败"
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
