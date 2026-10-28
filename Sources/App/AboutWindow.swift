import AppKit
import SwiftUI

/// 「关于」窗口（自定义）。
///
/// 为什么不用系统的 `orderFrontStandardAboutPanel`：标准面板把 credits 固定放在
/// 版本号下方，无法把版权行提到第二行，也无法单独指定颜色/字重。
/// 这里用 SwiftUI 自绘一版，按「图标 → 应用名 → 版本 → 说明 → © 钟义杰」排列。
@MainActor
final class AboutWindowController: NSObject {
    static let shared = AboutWindowController()

    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: AboutView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 320),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "关于 Markable"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.backgroundColor = .white
        window.contentViewController = hosting
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct AboutView: View {
    /// 应用图标（无 bundle 直接运行时可退回一个占位图形）。
    private var appIcon: Image {
        if let icon = NSApp.applicationIconImage {
            return Image(nsImage: icon)
        }
        return Image(systemName: "book")
    }

    var body: some View {
        // 版式（自上而下）：图标 → Markable（24pt 加粗）→ 版本号 → 说明 → © 钟义杰（最后一行）。
        // 其余文字统一 16pt 常规；窗口固定浅色底，文字纯黑。
        VStack(spacing: 10) {
            appIcon
                .resizable()
                .interpolation(.high)
                .frame(width: 84, height: 84)

            Text("Markable")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.black)

            Text("版本 \(AppVersion.short) (\(AppVersion.build))")
                .font(.system(size: 16))
                .foregroundColor(.black)

            Text("纯粹的Markdown阅读器")
                .font(.system(size: 16))
                .foregroundColor(.black)

            Text("© 钟义杰")
                .font(.system(size: 16))
                .foregroundColor(.black)
        }
        .padding(.horizontal, 40)
        .padding(.top, 26)
        .padding(.bottom, 26)
        .fixedSize()
        .background(Color.white)
    }
}
