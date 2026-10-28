import AppKit
import WebKit

/// 帮助窗口：应用内展示随包分发的 `help.html`，并在顶部提供**搜索**。
///
/// 为什么自己带搜索：macOS 27 的「帮助」菜单搜索框不再索引第三方应用内容
/// （系统自带应用也已不再提供任何 `.help`，传统 Help Book 机制已废弃），
/// 因此搜索必须在应用内实现。搜索由 `help.html` 内嵌的 `__search/__next` 完成：
/// 输入即高亮全部匹配，回车跳到下一个。
@MainActor
final class HelpWindowController: NSObject, NSWindowDelegate, NSSearchFieldDelegate {
    static let shared = HelpWindowController()

    private var window: NSWindow?
    private var webView: WKWebView?
    private var searchField: NSSearchField?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            window.makeFirstResponder(searchField)
            return
        }

        let webView = WKWebView()
        self.webView = webView

        let search = NSSearchField()
        search.placeholderString = "搜索帮助内容（输入即高亮，回车跳到下一个）"
        search.sendsWholeSearchString = false
        search.sendsSearchStringImmediately = true
        search.delegate = self
        search.target = self
        search.action = #selector(searchFieldSubmitted(_:))
        self.searchField = search

        let bar = NSView()
        search.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(search)
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            search.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            search.topAnchor.constraint(equalTo: bar.topAnchor, constant: 10),
            search.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -10),
        ])

        let separator = NSBox()
        separator.boxType = .separator

        let stack = NSStackView(views: [bar, separator, webView])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill
        bar.setContentHuggingPriority(.required, for: .vertical)
        separator.setContentHuggingPriority(.required, for: .vertical)
        webView.setContentHuggingPriority(.defaultLow, for: .vertical)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Markable 帮助"
        window.isRestorable = false
        // 关闭窗口时**不要**释放（WKWebView 的释放路径会导致 objc_release 野指针崩溃）
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed   // 绝不与文档窗口合并标签组（不同 tabbingIdentifier 混用会崩）
        window.contentMinSize = NSSize(width: 540, height: 380)
        window.contentView = stack
        window.delegate = self
        window.center()
        self.window = window

        if let url = Self.helpFileURL() {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.loadHTMLString(
                "<html><meta charset=\"utf-8\"><body style=\"font-family:-apple-system;padding:32px\">"
                + "<h1>帮助文件缺失</h1><p>请重新安装 Markable。</p></body></html>",
                baseURL: nil
            )
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(search)
    }

    // MARK: - 搜索

    /// 边输边高亮。
    func controlTextDidChange(_ obj: Notification) {
        runSearch(advance: false)
    }

    /// 回车：跳到下一个匹配。
    @objc private func searchFieldSubmitted(_ sender: NSSearchField) {
        runSearch(advance: true)
    }

    private func runSearch(advance: Bool) {
        guard let webView, let searchField else { return }
        let query = searchField.stringValue
        let js: String
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            js = "window.__clearSearch && window.__clearSearch(); 0"
        } else if advance {
            js = "window.__next && window.__next();"
        } else {
            js = "window.__search && window.__search(\(Self.javaScriptLiteral(query)));"
        }
        webView.evaluateJavaScript(js) { _, _ in }
    }

    private static func javaScriptLiteral(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        var literal = String(decoding: data, as: UTF8.self)
        literal.removeFirst()   // 去掉外层 "["
        literal.removeLast()    // 去掉外层 "]"
        return literal
    }

    // MARK: - 帮助文件位置

    /// 优先 SwiftPM 资源包内的 `Help/help.html`，其次可执行文件同级（打包成 .app 时）。
    private static func helpFileURL() -> URL? {
        if let url = Bundle.module.url(forResource: "help", withExtension: "html", subdirectory: "Help"),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if let url = Bundle.module.url(forResource: "help", withExtension: "html"),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Help/help.html"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/Resources/Help/help.html"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 关窗时只停止加载，**保留**窗口与 `WKWebView` 的强引用（释放会崩）。
    func windowWillClose(_ notification: Notification) {
        webView?.stopLoading()
    }
}
