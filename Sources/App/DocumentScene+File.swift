import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import PDFKit

/// `DocumentScene` 的文件操作：打开、启动恢复、载入、重载与外部修改检测。
/// （自 `DocumentScene.swift` 机械拆分，逻辑未改。）
extension DocumentScene {
    // MARK: - 文件

    func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // 交给窗口管理器：同一文件→切到它的标签、有空标签→用它、否则**新开标签页**。
        // 不能直接 `load`，否则会顶掉当前标签页里的文档。
        DocumentWindowManager.shared.open(url)
    }

    /// 启动时恢复：**仅在没有任何显式指定文件时**才回到"上次阅读"。
    /// 优先级：命令行参数里的 `.md` ＞（Finder / URL 的打开请求，由 URLCommandBus 处理）＞ 上次阅读。
    func restoreLastDocument() {
        guard document.path == nil else { return }

        // 1) 命令行参数里的 .md（显式指定）
        let args = CommandLine.arguments.dropFirst()
        if let path = args.first(where: { $0.hasSuffix(".md") }),
           FileManager.default.fileExists(atPath: path) {
            load(URL(fileURLWithPath: path))
            return
        }

        // 2) 有来自 Finder / markable:// 的打开请求 → 交给它，不用"上次阅读"覆盖
        guard !urlBus.hasPendingOpen else { return }

        // 3) 真正空启动 → 恢复上次阅读
        guard let path = settings.lastOpenedPath,
              FileManager.default.fileExists(atPath: path) else { return }
        load(URL(fileURLWithPath: path))
    }

    /// 打开文件并记录到历史。
    func load(_ url: URL, preserveScroll: Bool = false) {
        guard let opened = try? store.open(path: url) else { return }
        let previousOffset = preserveScroll ? currentScrollOffset() : nil
        document = opened
        selectedText = ""
        settings.lastOpenedPath = url.path
        lastMtime = FileDocumentStore.modificationDate(of: url)
        lastFileSize = fileSize(at: url)
        app.addRecent(url.path)
        // 告诉窗口管理器：本标签页现在显示哪个文档
        NotificationCenter.default.post(
            name: .markableWindowDidShowDocument, object: nil,
            userInfo: ["id": windowID, "url": url]
        )
        if let previousOffset {
            restoreScroll(previousOffset)
        }
    }

    /// 文件字节数；读不到时 0。
    private func fileSize(at url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// 当前滚动偏移（刷新后恢复阅读位置用）。
    private func currentScrollOffset() -> CGFloat? {
        pager.scrollView?.contentView.bounds.origin.y
    }

    /// 重新渲染后恢复滚动位置：clamp 到新内容高度，等一次布局再滚。
    private func restoreScroll(_ offset: CGFloat) {
        DispatchQueue.main.async {
            guard let scrollView = pager.scrollView,
                  let clip = scrollView.contentView as NSClipView? else { return }
            let height = clip.bounds.height
            let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - height)
            let y = min(max(0, offset), maxY)
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    /// 菜单 / 工具栏 / ⌘R：强制从磁盘重新载入并重渲染（即使内容未变）。
    func reloadFromDisk() {
        guard let path = document.path else { return }
        load(path, preserveScroll: true)
        reloadToken = UUID()   // 内容相同也强制重新应用样式
    }

    /// 外部修改检测：mtime/size 变化且内容不同时自动重排（保持阅读位置）。
    func checkExternalChange() {
        guard app.autoReload, let path = document.path else { return }
        guard let currentMtime = FileDocumentStore.modificationDate(of: path) else { return }
        let currentSize = fileSize(at: path)
        guard DocumentReloadPolicy.shouldReload(
            lastMtime: lastMtime,
            currentMtime: currentMtime,
            lastSize: lastFileSize,
            currentSize: currentSize,
            contentChanged: true
        ) else { return }
        // 内容没变（touch / 编辑器写回相同内容）→ 只更新记录，不重排
        guard let opened = try? store.open(path: path), opened.content != document.content else {
            lastMtime = currentMtime
            lastFileSize = currentSize
            return
        }
        lastMtime = currentMtime
        lastFileSize = currentSize
        load(path, preserveScroll: true)
    }
}
