import Foundation

/// 一次导出用到的全部配置（UI 设置 + front matter 覆盖后的结果）。
struct ExportConfig: Equatable {
    var title: String
    var pageSetup: PageSetup
    var stamp: PDFStamp?
    var includeTOC: Bool

    /// 用 front matter 覆盖：`title` / `paper` / `margin` / `header` / `footer` / `toc`。
    func applying(frontMatter: [String: String]) -> ExportConfig {
        var config = self
        func scalar(_ key: String) -> String? {
            guard let raw = frontMatter[key] else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return trimmed.isEmpty ? nil : trimmed
        }

        if let title = scalar("title") { config.title = title }
        if let paper = scalar("paper"), let parsed = PageSetup.Paper(rawValue: paper.lowercased()) {
            config.pageSetup.paper = parsed
        }
        if let margin = scalar("margin"), let value = Double(margin) {
            config.pageSetup.marginMM = min(100, max(0, value))
        }

        let header = scalar("header") ?? config.stamp?.header ?? ""
        let footer = scalar("footer") ?? config.stamp?.footer ?? ""
        let stamp = PDFStamp(header: header, footer: footer)
        config.stamp = stamp.isEnabled ? stamp : nil

        if let toc = scalar("toc") {
            let flag = toc.lowercased()
            config.includeTOC = (flag == "true" || flag == "yes" || flag == "1" || flag == "on")
        }
        return config
    }
}
