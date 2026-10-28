import Testing
import AppKit
import SwiftUI
@testable import Markable

/// 离屏渲染设置窗口的三个分页，供人工/Agent 检查"上对齐 + 高度自适应"的效果。
/// 不属于功能测试，目的是可视化验证（设置窗口需 ⌘, 打开，无法在无头环境点开）。
@Suite("SettingsSnapshot")
struct SettingsSnapshotTests {
    @Test @MainActor func renderPanes() throws {
        _ = NSApplication.shared
        let outputDir = try SnapshotSupport.prepareOutputDirectory()

        for tab in 0..<3 {
            let view = SettingsView(initialTab: tab).environmentObject(AppState.shared)
            let hosting = NSHostingView(rootView: view)
            hosting.layoutSubtreeIfNeeded()
            let size = hosting.fittingSize           // 由 SettingsView 内部的 frame(width:height:) 决定
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()

            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                Issue.record("bitmap 创建失败 (tab \(tab))")
                continue
            }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                Issue.record("PNG 编码失败 (tab \(tab))")
                continue
            }
            let out = outputDir.appendingPathComponent("settings-tab\(tab).png")
            try png.write(to: out)
            print("SETTINGS_SNAPSHOT tab\(tab) \(Int(size.width))x\(Int(size.height)) -> \(out.path)")
            #expect(!png.isEmpty)
        }
    }
}
