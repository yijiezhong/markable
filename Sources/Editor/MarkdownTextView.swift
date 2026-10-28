import SwiftUI
import AppKit

/// 滚动/定位请求：`id` 保证重复点击同一目标也能重新触发定位。
struct ScrollRequest: Equatable {
    var id = UUID()
    var search: String
}

/// 持有文本滚动视图的弱引用：供"跳到上/下一个标题"定位可见位置，以及**空格翻屏**。
@MainActor
final class ScrollViewBox {
    weak var scrollView: NSScrollView?

    /// 翻屏的目标纵向偏移（纯函数，便于测试）。
    nonisolated static func pagedOffset(current: CGFloat, height: CGFloat, maxY: CGFloat, direction: Int) -> CGFloat {
        guard height > 0 else { return current }
        let target = current + CGFloat(direction) * height * 0.92
        return min(max(0, target), max(0, maxY))
    }

    /// `direction` > 0 向下翻一屏，< 0 向上翻一屏（空格 / ⇧空格）。
    func page(by direction: Int) {
        guard let scrollView, let clip = scrollView.contentView as NSClipView? else { return }
        let height = clip.bounds.height
        guard height > 0 else { return }
        let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - height)
        let y = Self.pagedOffset(current: clip.bounds.origin.y, height: height, maxY: maxY, direction: direction)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// 滚到文档最前（⌘↑）。
    func scrollToTop() {
        guard let scrollView, let clip = scrollView.contentView as NSClipView? else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: 0))
        scrollView.reflectScrolledClipView(clip)
    }

    /// 滚到文档最后（⌘↓）。
    func scrollToBottom() {
        guard let scrollView, let clip = scrollView.contentView as NSClipView? else { return }
        let height = clip.bounds.height
        let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - height)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: maxY))
        scrollView.reflectScrolledClipView(clip)
    }

    /// 滚动到指定**字符位置**（段落跳转用）。
    func scrollToCharacter(_ index: Int) {
        guard let scrollView, let textView = scrollView.documentView as? NSTextView,
              let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return }
        let length = (textView.string as NSString).length
        guard length > 0 else { return }
        let location = min(max(0, index), length - 1)
        guard let start = contentManager.location(contentManager.documentRange.location, offsetBy: location) else { return }
        layoutManager.ensureLayout(for: NSTextRange(location: start))
        guard let fragment = layoutManager.textLayoutFragment(for: start) else { return }
        guard let clip = scrollView.contentView as NSClipView? else { return }
        let y = max(0, fragment.layoutFragmentFrame.minY + textView.textContainerOrigin.y - 10)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// 当前可见区域**顶部**对应的字符下标（用于"跳到上一个/下一个标题"）。
    func visibleTopCharacterIndex() -> Int? {
        guard let scrollView, let textView = scrollView.documentView as? NSTextView,
              let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return nil }
        let point = NSPoint(x: 0, y: textView.visibleRect.minY + 1 - textView.textContainerOrigin.y)
        guard let fragment = layoutManager.textLayoutFragment(for: point),
              let element = fragment.textElement,
              let range = element.elementRange else { return nil }
        return contentManager.offset(from: contentManager.documentRange.location, to: range.location)
    }

    /// 当前渲染后的文本（含隐藏标记），用于按标题文本定位。
    func renderedText() -> String? {
        (scrollView?.documentView as? NSTextView)?.string
    }
}

/// 阅读器用的 `NSTextView`：把**空格**变成"向下翻一屏"、**⇧空格**变成"向上翻一屏"
/// （只读模式下空格本无作用；这是阅读器的通用滚动约定）。
final class ReaderTextView: NSTextView {
    /// +1 下翻 / -1 上翻
    var onPageScroll: ((Int) -> Void)?

    /// 复制 / 拖拽 / 服务：只输出**读者看得见的内容**。
    ///
    /// `copy(_:)` 与拖拽复制最终都经由 `writeSelection(to:types:)` 写剪贴板，
    /// 因此在这里统一拦截：隐藏的 Markdown 标记、代码行号、附件占位符（U+FFFC）
    /// 全部剔除，渲染竖线还原成 `>`，表格重排成 TSV。净化后的内容同时写纯文本与 RTF。
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let storage = textStorage,
              let cleaned = CopyFormatted.cleanedSelection(in: storage, range: selectedRange()) else {
            return super.writeSelection(to: pboard, types: types)
        }
        return QuoteBarCopy.write(cleaned, to: pboard)
    }

    /// 单类型写入（服务菜单 / 旧式文本系统路径）：与多类型写入共用同一份净化逻辑。
    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let storage = textStorage,
              let cleaned = CopyFormatted.cleanedSelection(in: storage, range: selectedRange()) else {
            return super.writeSelection(to: pboard, type: type)
        }
        return QuoteBarCopy.write(cleaned, to: pboard)
    }

    override func keyDown(with event: NSEvent) {
        // PageDown / PageUp：与空格一致地翻一屏
        if event.keyCode == 121 { onPageScroll?(1); return }    // PageDown
        if event.keyCode == 116 { onPageScroll?(-1); return }   // PageUp

        if event.charactersIgnoringModifiers == " " {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.isEmpty {
                onPageScroll?(1)
                return
            }
            if flags == .shift {
                onPageScroll?(-1)
                return
            }
        }
        super.keyDown(with: event)
    }
}

/// 只读阅读器的文本视图（TextKit 2）。渲染器从**源文本**重建视图。
struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var selectedText: String
    var baseDirectory: URL?
    var fontSize: CGFloat = 14
    var typography: Typography = Typography()
    /// 无序列表渲染成项目符号（`•`）；关闭时保留 Markdown 标记。
    var bulletLists: Bool = false
    /// 强制重渲染令牌：内容相同也重新应用样式（「强制刷新」用）。
    var reloadToken: UUID = UUID()
    var scrollRequest: ScrollRequest?
    var scrollViewBox: ScrollViewBox?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ReaderTextView(usingTextLayoutManager: true)
        textView.isEditable = false           // 纯阅读器
        textView.isSelectable = true          // 可选/可复制
        textView.isRichText = true
        textView.allowsUndo = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        if let container = textView.textContainer {
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.delegate = context.coordinator
        textView.usesFindBar = true                 // ⌘F 系统查找栏
        textView.isIncrementalSearchingEnabled = true

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.update(parent: self)
        textView.onPageScroll = { [weak coordinator = context.coordinator] direction in
            coordinator?.scrollPage(by: direction)
        }
        context.coordinator.applyIfNeeded()
        context.coordinator.observeResize(scrollView: scrollView)
        scrollViewBox?.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(parent: self)
        context.coordinator.syncWidth(nsView)
        context.coordinator.applyIfNeeded()
        context.coordinator.applyScrollIfNeeded()
        scrollViewBox?.scrollView = nsView
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private var parent: MarkdownTextView
        weak var textView: NSTextView?
        private let controller = LivePreviewController()
        private var lastSource: String?
        private var lastFontSize: CGFloat = 0
        private var lastTypography = Typography()
        private var lastBulletLists = false
        private var lastReloadToken: UUID?
        private var lastContainerWidth: CGFloat = 0
        private var lastScrollID: UUID?
        private var resizeObserver: NSObjectProtocol?

        init(_ parent: MarkdownTextView) {
            self.parent = parent
            super.init()
        }

        deinit {
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
            }
        }

        func update(parent: MarkdownTextView) { self.parent = parent }

        /// 监听滚动视图尺寸变化：窗口变宽/变窄时让文本宽度跟着走（否则窄窗口会横向溢出、无法折行）。
        func observeResize(scrollView: NSScrollView) {
            scrollView.contentView.postsFrameChangedNotifications = true
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                guard let self, let scrollView else { return }
                self.syncWidth(scrollView)
            }
        }

        /// 把文本视图与文本容器宽度同步到可见区域宽度；宽度变化时重新渲染（表格列宽随之重算）。
        func syncWidth(_ scrollView: NSScrollView) {
            guard let textView, let container = textView.textContainer else { return }
            let width = max(240, scrollView.contentView.bounds.width)
            guard abs(textView.frame.width - width) > 0.5 else { return }
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            applyIfNeeded()
        }

        /// 源文本 / 字号 / 排版 / 可用宽度变化时才重建视图。
        func applyIfNeeded() {
            guard let textView else { return }
            let source = parent.text
            let size = parent.fontSize
            let typo = parent.typography
            let bullets = parent.bulletLists
            let token = parent.reloadToken
            let width = textView.textContainer?.containerSize.width ?? 0
            if source == lastSource, size == lastFontSize, typo == lastTypography,
               bullets == lastBulletLists, token == lastReloadToken,
               abs(width - lastContainerWidth) < 1 {
                return
            }
            lastSource = source
            lastFontSize = size
            lastTypography = typo
            lastBulletLists = bullets
            lastReloadToken = token
            lastContainerWidth = width
            controller.apply(
                to: textView, source: source, baseDirectory: parent.baseDirectory,
                readOnly: true, fontSize: size, typography: typo, bulletLists: bullets
            )
        }

        /// 空格 / ⇧空格：按屏翻动。
        func scrollPage(by direction: Int) {
            parent.scrollViewBox?.page(by: direction)
        }

        /// 在渲染文本中查找定位目标，跳过 `{{TOC}}` 生成的目录条目
        /// （目录里也有同名标题，直接查找会跳到目录而不是正文标题）。
        private func locatedRange(for search: String, in textView: NSTextView) -> NSRange? {
            let ns = textView.string as NSString
            var searchRange = NSRange(location: 0, length: ns.length)
            while searchRange.length > 0 {
                let range = ns.range(of: search, options: [], range: searchRange)
                guard range.location != NSNotFound else { return nil }
                let attributes = textView.textStorage?.attributes(at: range.location, effectiveRange: nil) ?? [:]
                if attributes[.markableTOC] == nil { return range }
                let next = range.location + max(1, range.length)
                guard next < ns.length else { return nil }
                searchRange = NSRange(location: next, length: ns.length - next)
            }
            return nil
        }

        /// 定位请求：在渲染后的文本里查找目标文字，选中并滚动到可见处。
        func applyScrollIfNeeded() {
            guard let textView, let request = parent.scrollRequest, request.id != lastScrollID else { return }
            lastScrollID = request.id
            guard let range = locatedRange(for: request.search, in: textView) else {
                return
            }
            textView.setSelectedRange(range)
            // 延迟到下一轮 runloop：`updateNSView` 里此时 SwiftUI 的布局还没落定，
            // 直接滚动会被随后的布局覆盖（表现为「定位命中但画面不动」）。
            DispatchQueue.main.async {
                textView.scrollRangeToVisible(range)
            }
        }

        /// 内部锚点跳转：`markable-anchor://scroll?text=…` → 查找并滚动。
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url: URL?
            if let value = link as? URL { url = value }
            else if let value = link as? String { url = URL(string: value) }
            else { url = nil }

            guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }

            // 正文 [[wiki]] 内链 → 打开同目录文件
            if url.scheme == "markable-wiki" {
                if let name = components.queryItems?.first(where: { $0.name == "name" })?.value,
                   let resolved = WikiLinkIndex.resolve(target: name, in: parent.baseDirectory) {
                    Task { @MainActor in
                        URLCommandBus.shared.send(URLCommand(action: .open, path: resolved.path, output: nil, format: nil))
                    }
                }
                return true
            }

            guard url.scheme == "markable-anchor",
                  let search = components.queryItems?.first(where: { $0.name == "text" })?.value else {
                return false
            }
            guard let range = locatedRange(for: search, in: textView) else { return true }
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            let range = textView.selectedRange()
            if parent.selection != range {
                parent.selection = range
            }
            let ns = textView.string as NSString
            let selected: String
            if range.length > 0, range.location + range.length <= ns.length {
                selected = ns.substring(with: range)
            } else {
                selected = ""
            }
            if parent.selectedText != selected {
                parent.selectedText = selected
            }
        }
    }
}
