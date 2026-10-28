import Foundation
import Testing
@testable import Markable

/// 外部文件变化 → 是否重新载入的判定（自动刷新 / 强制刷新）。
@Suite("DocumentReloadPolicy")
struct DocumentReloadPolicyTests {
    private let old = Date(timeIntervalSince1970: 1_000)
    private let new = Date(timeIntervalSince1970: 2_000)

    @Test("强制刷新总是重载")
    func forceAlwaysReloads() {
        #expect(DocumentReloadPolicy.shouldReload(
            force: true, lastMtime: old, currentMtime: old,
            lastSize: 10, currentSize: 10, contentChanged: false
        ))
    }

    @Test("mtime 与 size 都没变 → 不重载")
    func unchangedSkips() {
        #expect(!DocumentReloadPolicy.shouldReload(
            lastMtime: old, currentMtime: old,
            lastSize: 10, currentSize: 10, contentChanged: true
        ))
    }

    @Test("mtime 变化但内容相同 → 不重载")
    func sameContentSkips() {
        #expect(!DocumentReloadPolicy.shouldReload(
            lastMtime: old, currentMtime: new,
            lastSize: 10, currentSize: 10, contentChanged: false
        ))
    }

    @Test("mtime / size 变化且内容变化 → 重载")
    func changedReloads() {
        #expect(DocumentReloadPolicy.shouldReload(
            lastMtime: old, currentMtime: new,
            lastSize: 10, currentSize: 12, contentChanged: true
        ))
    }

    @Test("文件不可读（currentMtime 为 nil）→ 不重载")
    func missingFileSkips() {
        #expect(!DocumentReloadPolicy.shouldReload(
            lastMtime: old, currentMtime: nil,
            lastSize: 10, currentSize: 0, contentChanged: true
        ))
    }
}
