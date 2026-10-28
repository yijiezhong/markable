import Foundation

/// `markable://` 命令型 URL。
///
/// 形式：`markable://<action>?path=…&output=…&format=…`
/// - `open`    ：打开 `path`
/// - `export`  ：把 `path` 导出为 `output`（`format` = `pdf`（默认）/`html`）
/// - `settings`：打开设置窗口（`markable://settings`）
///
/// 例：`markable://open?path=%2Ftmp%2Fa.md`
///     `markable://export?path=/tmp/a.md&output=/tmp/a.pdf`
struct URLCommand: Equatable {
    enum Action: String {
        case open, export, settings
    }

    var action: Action
    var path: String?
    var output: String?
    var format: String?

    /// 解析 `markable://` URL；非本 scheme 或无法识别返回 nil。
    static func parse(_ url: URL) -> URLCommand? {
        guard url.scheme?.lowercased() == "markable" else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? {
            let raw = items.first { $0.name.lowercased() == name }?.value
            guard let raw, !raw.isEmpty else { return nil }
            return raw
        }

        // action 可来自 host（`markable://open?...`）或查询参数（`markable://?action=open`）
        let actionText = (components?.host.flatMap { $0.isEmpty ? nil : $0 } ?? value("action") ?? "").lowercased()
        guard let action = Action(rawValue: actionText) else { return nil }

        return URLCommand(
            action: action,
            path: value("path"),
            output: value("output"),
            format: value("format")?.lowercased()
        )
    }

    /// 展开 `~` 并转成文件 URL。
    static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}

/// 传入命令的投递箱（窗口加载完成前也能收到命令行传入的 URL）。
/// 用**队列**逐条投递，避免同一帧内多条命令互相覆盖。
@MainActor
final class URLCommandBus: ObservableObject {
    struct Incoming: Equatable {
        var id: Int
        var command: URLCommand
    }

    static let shared = URLCommandBus()
    @Published private(set) var queue: [Incoming] = []

    private var counter = 0
    private var isReady = false
    private var waiting: [URLCommand] = []

    /// 投递一条命令（若界面尚未就绪则暂存，就绪后按序入队）。
    func send(_ command: URLCommand) {
        guard isReady else { waiting.append(command); return }
        enqueue(command)
    }

    /// 界面就绪：冲刷暂存命令。
    func ready() {
        isReady = true
        let queued = waiting
        waiting.removeAll()
        for command in queued { enqueue(command) }
    }

    /// 是否还有**尚未执行**的打开请求（来自 Finder / `markable://` / 命令行）。
    /// 「恢复上次阅读」据此让步：有显式指定文件时不覆盖它。
    var hasPendingOpen: Bool {
        func isOpen(_ command: URLCommand) -> Bool { command.action == .open }
        return queue.contains { isOpen($0.command) } || waiting.contains(where: isOpen)
    }

    /// 已消费一条：从队列移除。
    func consume(_ id: Int) {
        queue.removeAll { $0.id == id }
    }

    private func enqueue(_ command: URLCommand) {
        counter += 1
        queue.append(Incoming(id: counter, command: command))
    }
}
