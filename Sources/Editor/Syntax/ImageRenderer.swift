import AppKit

/// 图片渲染与本地路径解析（FR-002 图片；边界：失效/远程路径给可辨识占位）。
///
/// 约束：阅读器**不联网**——远程图片不同步抓取，画一个占位标出 URL；
/// 本地缺失同样给占位（保留 alt 文本可辨）。
enum ImageRenderer {
    /// 图片来源分类。
    enum Source: Equatable {
        case local(URL)
        case remote(String)
        case missing(String)
    }

    /// 最大显示宽度（点）。超过则等比缩小，避免超宽图片撑爆视图。
    private static let maxDisplayWidth: CGFloat = 640

    /// 判定图片路径属于本地 / 远程 / 缺失。
    static func classify(_ rawPath: String, relativeTo base: URL?) -> Source {
        let trimmed = rawPath.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("data:") {
            return .remote(trimmed)
        }
        if trimmed.hasPrefix("/") {
            return FileManager.default.fileExists(atPath: trimmed) ? .local(URL(fileURLWithPath: trimmed)) : .missing(trimmed)
        }
        if let base {
            let candidate = base.appendingPathComponent(trimmed)
            if FileManager.default.fileExists(atPath: candidate.path) { return .local(candidate) }
        }
        let direct = URL(fileURLWithPath: trimmed)
        if direct.isFileURL, FileManager.default.fileExists(atPath: direct.path) { return .local(direct) }
        return .missing(trimmed)
    }

    /// 本地图片 → 附件（超宽等比缩小）。
    static func attachment(forLocal url: URL) -> NSTextAttachment? {
        guard let image = NSImage(contentsOf: url), image.size.width > 0 else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = image
        let width = image.size.width
        if width > maxDisplayWidth {
            let scale = maxDisplayWidth / width
            attachment.bounds = CGRect(x: 0, y: 0, width: maxDisplayWidth, height: image.size.height * scale)
        }
        return attachment
    }

    /// 占位附件：浅灰圆角底 + 一行提示文字（远程 / 缺失 / 读取失败）。
    static func placeholderAttachment(text: String) -> NSTextAttachment {
        let font = NSFont.systemFont(ofSize: 11)
        let padded = " \(text) "
        let textSize = (padded as NSString).size(withAttributes: [.font: font])
        let size = NSSize(width: max(80, textSize.width + 12), height: max(22, textSize.height + 10))

        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        NSColor.quaternaryLabelColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()
        (padded as NSString).draw(
            at: NSPoint(x: 6, y: (size.height - textSize.height) / 2),
            withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        )
        image.unlockFocus()

        let attachment = NSTextAttachment()
        attachment.image = image
        return attachment
    }

    // MARK: - 兼容旧接口

    /// 解析本地图片路径（相对路径以文档目录为基准）；远程/缺失返回 nil。
    static func resolveLocalImage(_ rawPath: String, relativeTo base: URL?) -> URL? {
        if case .local(let url) = classify(rawPath, relativeTo: base) { return url }
        return nil
    }

    static func attachment(forImageAt url: URL) -> NSTextAttachment? {
        attachment(forLocal: url)
    }

    /// 供单元测试：占位附件的显示尺寸大于 0。
    static func placeholderSize(text: String) -> NSSize {
        placeholderAttachment(text: text).image?.size ?? .zero
    }
}
