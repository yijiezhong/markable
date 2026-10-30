import AppKit
import SwiftUI

extension Notification.Name {
    /// 请求某个窗口（按 `windowID`）打开文档。`userInfo` = ["id": UUID, "url": URL]
    static let markableOpenInWindow = Notification.Name("markable.openInWindow")
    /// 某窗口已显示某文档（由场景上报，管理器据此跟踪标签页内容）。
    /// `userInfo` = ["id": UUID, "url": URL]
    static let markableWindowDidShowDocument = Notification.Name("markable.windowDidShowDocument")
}

/// 文档窗口管理：**所有文档共用一个窗口，每个文档一个标签页**（标签在窗口上方）。
///
/// **所有文档窗口都由本类创建**（首窗与后续标签页），不与 SwiftUI 的场景窗口混用：
/// 混用会让"SwiftUI 场景窗口"和"手动 NSWindow"同处一个标签组，所有权冲突曾导致
/// `objc_release` 野指针崩溃。打开新文件时用 `addTabbedWindow` 并入同一标签组。
@MainActor
final class DocumentWindowManager: NSObject {
    static let shared = DocumentWindowManager()

    private struct Entry {
        var id: UUID
        var window: NSWindow
        var url: URL?            // nil = 空文档（尚未打开任何文件）
    }

    /// 所有文档窗口共用的标签标识 —— `addTabbedWindow` 只在标识相同时才合并。
    private static let tabbingIdentifier = NSWindow.TabbingIdentifier("markable.document")

    private let settings = SettingsStore()
    private var entries: [Entry] = []
    /// 视图尚未挂载时收到的打开请求（启动早期的 OFD 事件 / 通知先于 SwiftUI 视图到达）。
    /// `DocumentScene` 首次挂载时消费，避免「App 没运行时双击文件 → 空白标签页」。
    private var pendingURLs: [UUID: URL] = [:]


    /// 当前"活跃"标签页：key → main → 第一个（菜单命令据此只作用于当前标签）。
    var activeWindowID: UUID? {
        entries.first { $0.window.isKeyWindow }?.id
            ?? entries.first { $0.window.isMainWindow }?.id
            ?? entries.first?.id
    }

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidShowDocument(_:)),
            name: .markableWindowDidShowDocument, object: nil
        )
    }


    // MARK: - 打开文档

    /// 打开一个文档：同一文件 → 切到它的标签；有空标签 → 用它；否则**新开标签页**。
    /// 决策逻辑抽在 `WindowTabPolicy`（纯函数，单测覆盖）。
    func open(_ url: URL) {
        let target = url.standardizedFileURL

        switch WindowTabPolicy.decide(existingURLs: entries.map(\.url), opening: target) {
        case .switchTo(let index):
            entries[index].window.makeKeyAndOrderFront(nil)          // 已打开 → 切过去
        case .reuseEmpty(let index):
            let entry = entries[index]
            entries[index].url = target
            pendingURLs[entry.id] = target
            NotificationCenter.default.post(
                name: .markableOpenInWindow, object: nil,
                userInfo: ["id": entry.id, "url": target]
            )
            entry.window.makeKeyAndOrderFront(nil)
        case .newTab:
            newTab(url: target)                                       // 否则新开标签页
        }
    }

    /// 取出并清除某个窗口的待打开 URL（视图首次挂载时调用）。
    func consumePendingURL(for id: UUID) -> URL? {
        defer { pendingURLs[id] = nil }
        return pendingURLs[id]
    }

    /// 打开设置窗口（⌘, 等效）——供菜单与 `markable://settings` 使用。
    /// SwiftUI 的 `Settings` 场景在启动时就已建好窗口（我们只是把它藏起来），
    /// 所以优先直接显示它；找不到时再退回 `showSettingsWindow:`。
    func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("Settings") == true }) {
            window.title = "设置"          // 固定标题，不随分页变化
            window.tabbingMode = .disallowed   // 绝不与文档窗口合并标签组（否则窗口所有权冲突会崩）
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    /// 统一建窗（首窗 / 新标签页共用），并登记。
    private func makeWindow(id: UUID, url: URL?) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.isRestorable = false
        window.tabbingMode = .preferred
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.contentMinSize = NSSize(width: 960, height: 620)
        window.setFrameAutosaveName("markable.document")
        window.contentView = NSHostingView(
            rootView: DocumentScene(initialURL: url, windowID: id)
                .environmentObject(AppState.shared)
        )
        entries.append(Entry(id: id, window: window, url: url))
        return window
    }

    /// 启动时的第一个窗口（走"恢复上次阅读"或空白）。
    func makeInitialWindow() {
        guard entries.isEmpty else { return }
        let window = makeWindow(id: UUID(), url: nil)
        if settings.windowMaximized, !isMaximized(window),
           let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            window.setFrame(visible, display: true)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// 新建标签页（`url` 为 nil 时是空白标签）。
    func newTab(url: URL? = nil) {
        // 宿主只从**文档窗口**里选。`NSApp.keyWindow` 可能是设置窗口 / 帮助窗口 / 保存面板，
        // 它们的 `tabbingIdentifier` 与文档窗口不同；把文档窗口并进它们的标签组会造成
        // 窗口所有权冲突 → `objc_release` 野指针崩溃。
        // （已实测复现：设置窗口为 key 时打开文件即崩。）
        let host = entries.first { $0.window.isKeyWindow }?.window
            ?? entries.first { $0.window.isMainWindow }?.window
            ?? entries.last?.window
        let window = makeWindow(id: UUID(), url: url)
        if let host, host !== window {
            host.addTabbedWindow(window, ordered: .above)             // 并入标签组
            showTabBarIfNeeded(for: window)                           // 顶部标签栏显示出来
            let inheritMaximized = isMaximized(host)                  // 继承宿主的最大化
            window.makeKeyAndOrderFront(nil)
            if inheritMaximized { maximizeWhenVisible(window) }
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// 关闭当前标签页（⌘W / 菜单「关闭标签页」）。
    /// key / main 是文档窗口时关闭该标签；否则关闭 key 窗口（设置 / 帮助等），
    /// 与系统 ⌘W 的直觉一致。
    func closeCurrentTab() {
        let target = entries.first { $0.window.isKeyWindow }?.window
            ?? entries.first { $0.window.isMainWindow }?.window
            ?? NSApp.keyWindow
        target?.performClose(nil)
    }

    /// 窗口是否已铺满屏幕可见区域（＝最大化）。
    /// 不依赖 `isZoomed`：用 `setFrame` 铺满时 `isZoomed` 仍为 false，自洽判断更可靠。
    private func isMaximized(_ window: NSWindow) -> Bool {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return false }
        return abs(window.frame.width - visible.width) < 2 && abs(window.frame.height - visible.height) < 2
    }

    /// 窗口显示后（等 SwiftUI 布局稳定）再铺满可见区域。
    private func maximizeWhenVisible(_ window: NSWindow) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard window.isVisible, let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
            window.setFrame(visible, display: true)
        }
    }

    /// 标签数 > 1 且标签栏当前不可见时，把它显示出来
    /// （系统偏好设为"手动"时不会自动显示）。
    private func showTabBarIfNeeded(for window: NSWindow) {
        guard let group = window.tabGroup, group.windows.count > 1, !group.isTabBarVisible else { return }
        window.toggleTabBar(nil)
    }

    // MARK: - 通知

    /// 场景上报"本窗口现在显示哪个文档"，据此跟踪标签内容。
    @objc private func windowDidShowDocument(_ note: Notification) {
        guard let id = note.userInfo?["id"] as? UUID,
              let url = note.userInfo?["url"] as? URL,
              let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].url = url.standardizedFileURL
    }

    /// 已关闭的文档窗口（**刻意保留强引用**）。
    ///
    /// macOS 27 上，承载 `NSHostingView` 的文档窗口一旦被释放，就会在 AppKit/SwiftUI 的拆除路径里
    /// 触发 `objc_release` 野指针崩溃。已逐一实测确认必崩的写法：直接 `contentView = NSHostingView`
    /// + 关闭释放、关闭后延迟 2 秒释放、`NSHostingController` 托管 + 关闭释放、辅助功能(AX)触发。
    /// 而**关闭后保留强引用**则稳定不崩。因此这里保留引用到进程结束：代价是这部分内存不归还，
    /// 但这是目前唯一能避免崩溃的做法（崩溃的代价远大于内存）。
    private var closedWindows: [NSWindow] = []

    @objc private func windowWillClose(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        guard let index = entries.firstIndex(where: { $0.window === window }) else { return }
        // 记住"关闭前是否最大化"，下次启动据此决定
        settings.windowMaximized = isMaximized(window)
        closedWindows.append(window)      // 保命：绝不在关闭时释放（见上）
        entries.remove(at: index)
    }
}
