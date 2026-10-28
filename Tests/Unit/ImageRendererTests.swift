import Testing
import Foundation
import AppKit
@testable import Markable

/// 图片渲染：来源分类与占位附件。
@Suite("ImageRenderer")
struct ImageRendererTests {
    @Test("远程 URL 归类为 remote")
    func remote() {
        if case .remote(let url) = ImageRenderer.classify("https://example.com/a.png", relativeTo: nil) {
            #expect(url == "https://example.com/a.png")
        } else {
            Issue.record("应归为 remote")
        }
    }

    @Test("不存在的相对路径归类为 missing")
    func missing() {
        let base = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)")
        if case .missing = ImageRenderer.classify("nope.png", relativeTo: base) {
            // ok
        } else {
            Issue.record("应归为 missing")
        }
    }

    @Test("存在的本地文件归类为 local")
    func local() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("img-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 写一个 1x1 PNG
        let url = dir.appendingPathComponent("dot.png")
        try Self.onePixelPNG().write(to: url)
        if case .local(let resolved) = ImageRenderer.classify("dot.png", relativeTo: dir) {
            #expect(resolved.lastPathComponent == "dot.png")
        } else {
            Issue.record("应归为 local")
        }
    }

    @Test("占位附件有正的显示尺寸")
    func placeholder() {
        let size = ImageRenderer.placeholderSize(text: "🌐 https://example.com/a.png")
        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    private static func onePixelPNG() -> Data {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return Data() }
        return png
    }
}
