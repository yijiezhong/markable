import AppKit
import WebKit

/// 用 `WKWebView` + **本地 KaTeX** 把 LaTeX 渲染成 `NSImage`（离线、**异步**）。
/// - WebView 挂在一个隐藏 window 上（离屏、无 window 时 WebKit 不渲染）；
/// - 全程 `async`，不阻塞主线程；结果缓存，进行中去重。
@MainActor
final class MathRenderer {
    static let shared = MathRenderer()

    private var cache: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    private lazy var window: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderOut(nil)
        return window
    }()

    private lazy var webView: WKWebView = {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }()

    /// 已缓存则直接返回。
    func cachedImage(tex: String, display: Bool) -> NSImage? {
        cache[Self.key(tex, display)]
    }

    /// 是否正在渲染（避免重复排队）。
    func isRendering(tex: String, display: Bool) -> Bool {
        inFlight.contains(Self.key(tex, display))
    }

    /// 异步渲染一段 LaTeX（已缓存/进行中则返回 nil）。
    func image(tex: String, display: Bool) async -> NSImage? {
        let key = Self.key(tex, display)
        if let cached = cache[key] { return cached }
        if inFlight.contains(key) { return nil }
        guard let base = resourceBase else { return nil }

        inFlight.insert(key)
        defer { inFlight.remove(key) }

        if webView.superview == nil {
            window.contentView?.addSubview(webView)
        }

        let html = makeHTML(tex: tex, display: display)
        webView.loadHTMLString(html, baseURL: base)

        // 等加载完成
        for _ in 0..<150 {
            if !webView.isLoading { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        // 读公式位置与尺寸（含位置偏移，避免裁切）
        guard
            let sizeString = try? await webView.evaluateJavaScript("JSON.stringify(window.__rect || {x:0,y:0,w:0,h:0})") as? String,
            let data = sizeString.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Int],
            let x = obj["x"], let y = obj["y"], let width = obj["w"], let height = obj["h"],
            width > 0, height > 0
        else { return nil }

        // 加 padding，避免贴边裁切
        let rect = NSRect(
            x: max(0, CGFloat(x) - 3),
            y: max(0, CGFloat(y) - 3),
            width: CGFloat(width) + 6,
            height: CGFloat(height) + 6
        )
        // 快照区域不能超出 webView
        webView.frame = NSRect(
            x: 0, y: 0,
            width: max(webView.frame.width, rect.maxX),
            height: max(webView.frame.height, rect.maxY)
        )
        try? await Task.sleep(nanoseconds: 30_000_000)

        let config = WKSnapshotConfiguration()
        config.rect = rect
        let snapshot = try? await webView.takeSnapshot(configuration: config)
        if let snapshot { cache[key] = snapshot }
        return snapshot
    }

    // MARK: - 资源与 HTML

    private var resourceBase: URL? {
        if let url = Bundle.module.resourceURL?.appendingPathComponent("KaTeX"),
           FileManager.default.fileExists(atPath: url.appendingPathComponent("katex.min.js").path) {
            return url
        }
        let fallback = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/KaTeX")
        return FileManager.default.fileExists(atPath: fallback.appendingPathComponent("katex.min.js").path)
            ? fallback : nil
    }

    private func makeHTML(tex: String, display: Bool) -> String {
        let json = Self.jsonString(tex)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <link rel="stylesheet" href="katex.min.css">
        <script src="katex.min.js"></script>
        <style>html,body{margin:0;padding:0;background:transparent}
        #m{display:inline-block;padding:1px}</style></head>
        <body><span id="m"></span>
        <script>
          try { katex.render(\(json), document.getElementById('m'), {displayMode: \(display ? "true" : "false"), throwOnError: false}); } catch (e) {}
          var r = document.getElementById('m').getBoundingClientRect();
          window.__rect = { x: Math.floor(r.left), y: Math.floor(r.top), w: Math.ceil(r.width), h: Math.ceil(r.height) };
        </script></body></html>
        """
    }

    private static func key(_ tex: String, _ display: Bool) -> String {
        "\(display ? "D" : "I"):\(tex)"
    }

    private static func jsonString(_ s: String) -> String {
        let data = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
        return String(data: data, encoding: .utf8) ?? "\"\""
    }
}
