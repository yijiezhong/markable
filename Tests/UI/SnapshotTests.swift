import Testing
import AppKit
@testable import Markable

/// 离屏渲染快照：把 Markable 的渲染结果画成 PNG，供人工/Agent 查看观感。
/// 不属于功能测试；目的是"可视化验证"。
@Suite("Snapshot")
struct SnapshotTests {
    @Test @MainActor func boldMarkersHiddenOnRealFile() throws {
        _ = NSApplication.shared
        let text = "# 标题\n\n> **调研日期**：2026-01-01\n> **资料来源**：某处\n\n正文 **粗体** 与 *斜体*，以及 `代码`。\n"
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.frame = NSRect(x: 0, y: 0, width: 760, height: 600)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        LivePreviewController().apply(to: textView, source: text, baseDirectory: nil)

        guard let storage = textView.textStorage else { return }
        // 回归断言：渲染结果里**不应有可见的 `**` 标记**（长度可能因接排等替换而改变，
        // 故按渲染后的文本查找标记位置，而不是用源偏移）。
        let rendered = storage.string as NSString
        var offenders: [String] = []
        var searchRange = NSRange(location: 0, length: rendered.length)
        while searchRange.length > 0 {
            let found = rendered.range(of: "**", options: [], range: searchRange)
            if found.location == NSNotFound { break }
            let attrs = storage.attributes(at: found.location, effectiveRange: nil)
            if (attrs[.foregroundColor] as? NSColor) != NSColor.clear {
                offenders.append(rendered.substring(with: found))
            }
            let next = found.location + found.length
            searchRange = NSRange(location: next, length: rendered.length - next)
        }
        #expect(offenders.isEmpty, "未隐藏的粗体标记：\(offenders.prefix(5))")
    }

    @Test @MainActor func renderSnapshotPNG() throws {
        _ = NSApplication.shared
        let markdown: String
        // 真实文档快照需要本机私有文件；未设置环境变量时跳过（避免把个人路径写进仓库）。
        let realFile = ProcessInfo.processInfo.environment["MARKABLE_SNAPSHOT_FILE"] ?? ""
        if let data = FileManager.default.contents(atPath: realFile), let text = String(data: data, encoding: .utf8) {
            markdown = text
        } else {
            markdown = "# 一级标题\n\n正文包含 **粗体**、*斜体*、`行内代码` 与 [链接](https://example.com)。\n"
        }

        let width: CGFloat = 760
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.drawsBackground = true
        textView.backgroundColor = .white
        textView.textColor = .black
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: width - 24, height: CGFloat.greatestFiniteMagnitude)
        textView.string = markdown
        // 模拟"刚打开文件"：光标在文档开头（否则 NSTextView 默认插入点在文末，
        // 会让"最后一段"被当作光标段落而不渲染）。
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        LivePreviewController().apply(to: textView, source: markdown, baseDirectory: nil)

        if let lm = textView.layoutManager, let tc = textView.textContainer {
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc)
            textView.frame = NSRect(x: 0, y: 0, width: width, height: max(240, used.height + 48))
        }

        guard let rep = textView.bitmapImageRepForCachingDisplay(in: textView.bounds) else {
            Issue.record("bitmap 创建失败")
            return
        }
        textView.cacheDisplay(in: textView.bounds, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else {
            Issue.record("PNG 编码失败")
            return
        }
        let out = try SnapshotSupport.prepareOutputDirectory()
            .appendingPathComponent("markable-snapshot.png")
        try png.write(to: out)
        print("SNAPSHOT_FILE=\(out.path) bytes=\(png.count)")
        #expect(!png.isEmpty)
    }
}
