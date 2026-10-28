// make-icon.swift —— 生成 Markable 的应用图标（1024×1024 PNG）。
// 用法：swift scripts/make-icon.swift <输出.png>
//
// 设计：macOS 风格圆角矩形（留白 + 半径按 Big Sur 规范），深蓝→青蓝渐变，
// 中央白色衬线感 "M" 与一条书脊线，表达"Markdown 阅读器"。

import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("用法：swift make-icon.swift <输出.png>\n".utf8))
    exit(2)
}
let outputPath = arguments[1]

let canvas: CGFloat = 1024
// Big Sur+ 规范：图标主体约 824×824，居中，圆角半径约 185
let inset: CGFloat = 100
let body = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
let radius: CGFloat = body.width * 0.2237

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else {
    FileHandle.standardError.write(Data("无法创建位图\n".utf8))
    exit(1)
}

guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write(Data("无法创建绘图上下文\n".utf8))
    exit(1)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

// 圆角矩形裁剪
let clip = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
clip.addClip()

// 渐变底：深蓝 → 青蓝
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.101, green: 0.286, blue: 0.796, alpha: 1),   // #1A49CB
    NSColor(srgbRed: 0.055, green: 0.647, blue: 0.914, alpha: 1),   // #0EA5E9
])!
gradient.draw(in: body, angle: -70)

// 顶部高光
NSColor.white.withAlphaComponent(0.12).setFill()
NSBezierPath(roundedRect: body.insetBy(dx: 0, dy: body.height * 0.62), xRadius: radius, yRadius: radius).fill()

// 书脊：左侧一条半透明竖条
NSColor.white.withAlphaComponent(0.22).setFill()
let spine = CGRect(x: body.minX + body.width * 0.13,
                   y: body.minY + body.height * 0.20,
                   width: body.width * 0.055,
                   height: body.height * 0.60)
NSBezierPath(roundedRect: spine, xRadius: spine.width / 2, yRadius: spine.width / 2).fill()

// 字母 "M"
let letter = "M"
let font = NSFont.systemFont(ofSize: body.height * 0.52, weight: .bold)
let attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.white,
]
let textSize = (letter as NSString).size(withAttributes: attributes)
let textOrigin = NSPoint(
    x: body.midX - textSize.width / 2 + body.width * 0.04,
    y: body.midY - textSize.height / 2 + body.height * 0.01
)
(letter as NSString).draw(at: textOrigin, withAttributes: attributes)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("PNG 编码失败\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outputPath))
print("已生成图标：\(outputPath)")
