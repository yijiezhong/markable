import Foundation
import Markdown
import UniformTypeIdentifiers

/// 把 Markdown 渲染为用于导出的 HTML（T029）。
/// 遍历 swift-markdown 的 AST，输出基础 HTML（供 WKWebView 生成 PDF）。
///
/// 图片采用**自包含**策略：本地图片读入后内联成 `data:` URI，HTML 不依赖任何外部文件。
/// 原因：`WKWebView.loadHTMLString` 的 `about:blank` 页面无法读取 `file://` 资源
/// （传 `baseURL` 目录也会被 WebKit 拒绝），不内联的话 PDF 里就只剩 alt 文字。
/// 副作用是 HTML 文件变大，但换来「导出的 HTML 离线可移植、PDF 有图」。
struct HtmlRenderer {
    /// 代码字体风格（跟随正文字体族）。衬线正文用 Courier New + 宋体，否则 SF Mono + 苹方。
    var codeStyle: CodeTypography.Style = .sans

    /// 单张图片内联上限。超过上限不内联、只输出 alt 文本，避免超大图把 HTML / PDF 撑爆。
    /// 实例属性（而非 static）便于测试注入小上限。
    var maxInlineImageBytes = 8 * 1024 * 1024

    /// 相对图片路径的解析基准（Markdown 文件所在目录）。
    /// 只影响「能否找到图片」，不写进 HTML。
    var baseDirectory: URL?

    func html(
        from markdown: String,
        title: String,
        pageSetup: PageSetup? = nil,
        styled: Bool = true,
        baseDirectory: URL? = nil
    ) -> String {
        // 剥掉 front matter：否则 `---` 会把 YAML 当成 setext 标题渲染出来。
        // swift-markdown 不支持脚注：`[^1]: 内容` 会被当成引用式链接定义（链接目标变成脚注正文），
        // 因此先把定义行摘出来，正文渲染完再在末尾生成脚注区。
        let (content, footnotes) = Self.extractFootnotes(markdown)
        let document = Markdown.Document(parsing: MarkdownEngine.strippingFrontMatter(content))
        // 用局部副本携带图片解析基准，避免把 baseDirectory 做成跨调用共享状态。
        var working = self
        working.baseDirectory = baseDirectory ?? self.baseDirectory
        let body = working.render(document) + working.footnotesHTML(footnotes)
        let escapedTitle = escape(title)
        guard styled else {
            return """
            <!doctype html>
            <html><head><meta charset="utf-8">
            <title>\(escapedTitle)</title>
            </head>
            <body>\(body)</body></html>
            """
        }
        let pageRule = pageSetup.map { "\n          \($0.cssRule)" } ?? ""
        // 图片上限：不得高于内容区，否则分页时会被拦腰硬切。
        // 预留 40pt 给段落上下外边距（`p` 默认 1em 上下），避免「图片刚好一页高 + 段落边距」又超高。
        let contentHeight = (pageSetup ?? PageSetup()).contentSize.height
        let maxImageHeight = max(100, contentHeight - 40)
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <title>\(escapedTitle)</title>
        <style>\(pageRule)
          body { font-family: -apple-system, "PingFang SC", sans-serif; font-size: 11pt; line-height: 1.7; color: #1f2329; margin: 0; }
          h1,h2,h3,h4 { color: #1d4ed8; }
          code, pre { font-family: \(codeStyle.cssLatinFamily); font-size: 9.5pt; }
          code .code-cjk, pre .code-cjk { font-family: \(codeStyle.cssChineseFamily); letter-spacing: \(codeStyle.cssLetterSpacing); }
          pre { background: #f5f6f7; padding: 8px; border-radius: 6px; }
          blockquote { color: #6e6e73; border-left: 3px solid #cbd5e1; margin-left: 0; padding-left: 10px; }
          table { border-collapse: collapse; } td, th { border: 1px solid #cbd5e1; padding: 4px 6px; }
          img { max-width: 100%; height: auto; max-height: \(String(format: "%.0f", maxImageHeight))px; }
          .remote-image { color: #6e6e73; }
          .unsafe-link { color: inherit; }
          thead th { background: #f5f6f7; }
          input[type=checkbox] { margin-right: 6px; }
          li:has(input[type=checkbox]) { list-style: none; }
          li > p:has(input[type=checkbox]) { margin: 0.15em 0; }
          .footnotes { margin-top: 18px; font-size: 9.5pt; color: #6e6e73; }
          .footnotes ol { padding-left: 22px; }
          .footnotes a { text-decoration: none; }
          sup { font-size: 0.7em; vertical-align: super; }
        </style></head>
        <body>\(body)</body></html>
        """
    }

    private func render(_ markup: Markup) -> String {
        switch markup {
        case let heading as Heading:
            return "<h\(heading.level)>\(renderChildren(heading))</h\(heading.level)>"
        case let paragraph as Paragraph:
            return "<p>\(renderChildren(paragraph))</p>"
        case let text as Text:
            return textHTML(text.string)
        case let strong as Strong:
            return "<strong>\(renderChildren(strong))</strong>"
        case let emphasis as Emphasis:
            return "<em>\(renderChildren(emphasis))</em>"
        case let code as InlineCode:
            return "<code>\(codeHTML(code.code))</code>"
        case let block as CodeBlock:
            return "<pre><code>\(codeHTML(block.code))</code></pre>"
        case let link as Link:
            return linkHTML(link)
        case let image as Image:
            return imageHTML(image)
        case let list as UnorderedList:
            return "<ul>\(list.children.map(render).joined())</ul>"
        case let list as OrderedList:
            return "<ol>\(list.children.map(render).joined())</ol>"
        case let item as ListItem:
            let box = checkboxHTML(item.checkbox)
            guard !box.isEmpty else { return "<li>\(renderChildren(item))</li>" }
            // 任务项：把复选框放进第一个段落内部，否则 <input> 与 <p> 各自成块，
            // PDF / HTML 里会出现「☐ 换行 待办事项」的错位。
            if let first = item.child(at: 0), first is Paragraph {
                var html = "<li><p>\(box)\(renderChildren(first))</p>"
                for index in 1..<item.childCount {
                    if let child = item.child(at: index) {
                        html += render(child)
                    }
                }
                html += "</li>"
                return html
            }
            return "<li>\(box)\(renderChildren(item))</li>"
        case let quote as BlockQuote:
            return "<blockquote>\(renderChildren(quote))</blockquote>"
        case is ThematicBreak:
            return "<hr>"
        case let table as Table:
            return tableHTML(table)
        default:
            return renderChildren(markup)
        }
    }

    private func renderChildren(_ markup: Markup) -> String {
        markup.children.map(render).joined()
    }

    // MARK: - 表格 / 任务复选框 / 脚注

    /// 链接 → `<a href>`，但**过滤危险 scheme**。
    ///
    /// 导出的 HTML 会被浏览器直接打开，若把 Markdown 里的 `javascript:` / `data:` / `vbscript:`
    /// 原样写进 `href`，点击就会执行脚本——违背「阅读器不执行脚本」的定位。
    /// 只放行 http / https / mailto / tel / file、锚点与相对路径；其余只保留文字。
    private func linkHTML(_ link: Link) -> String {
        let destination = link.destination ?? ""
        guard Self.isSafeLinkDestination(destination) else {
            return "<span class=\"unsafe-link\">\(renderChildren(link))</span>"
        }
        return "<a href=\"\(escape(destination))\">\(renderChildren(link))</a>"
    }

    /// 判断链接目标是否可以安全写进 `href`。
    static func isSafeLinkDestination(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("#") || trimmed.hasPrefix("/") || trimmed.hasPrefix("./") || trimmed.hasPrefix("../") {
            return true
        }
        guard let scheme = URLComponents(string: trimmed)?.scheme?.lowercased() else {
            return true   // 无 scheme 的相对路径
        }
        return ["http", "https", "mailto", "tel", "file"].contains(scheme)
    }

    /// GFM 表格 → 真正的 `<table>`（含 `<thead>` / `<tbody>`、列对齐、合并单元格）。
    ///
    /// 此前 `Table` 走 `default` 分支，最终退化成 `renderChildren`，单元格文本会连成一串
    /// （`名称数量甲1乙2`），内置 PDF / HTML 导出里表格结构完全丢失。
    private func tableHTML(_ table: Table) -> String {
        let alignments = table.columnAlignments

        func cellHTML(_ cell: Table.Cell, isHeader: Bool, column: Int) -> String {
            let tag = isHeader ? "th" : "td"
            var attributes = ""
            if cell.colspan > 1 { attributes += " colspan=\"\(cell.colspan)\"" }
            if cell.rowspan > 1 { attributes += " rowspan=\"\(cell.rowspan)\"" }
            if column < alignments.count, let alignment = alignments[column] {
                attributes += " style=\"text-align: \(Self.cssValue(for: alignment))\""
            }
            return "<\(tag)\(attributes)>\(renderChildren(cell))</\(tag)>"
        }

        var html = "<table><thead><tr>"
        for (column, cell) in table.head.cells.enumerated() {
            html += cellHTML(cell, isHeader: true, column: column)
        }
        html += "</tr></thead><tbody>"
        for row in table.body.rows {
            html += "<tr>"
            for (column, cell) in row.cells.enumerated() {
                html += cellHTML(cell, isHeader: false, column: column)
            }
            html += "</tr>"
        }
        html += "</tbody></table>"
        return html
    }

    private static func cssValue(for alignment: Table.ColumnAlignment) -> String {
        switch alignment {
        case .left: return "left"
        case .center: return "center"
        case .right: return "right"
        }
    }

    /// 任务列表复选框 → 禁用的 `<input type="checkbox">`（阅读器只读，不可交互）。
    /// swift-markdown 把 `[ ]` / `[x]` 解析进 `ListItem.checkbox`，不会出现在 children 里，
    /// 不显式输出就会丢。
    private func checkboxHTML(_ checkbox: Checkbox?) -> String {
        switch checkbox {
        case .checked?: return "<input type=\"checkbox\" disabled checked>"
        case .unchecked?: return "<input type=\"checkbox\" disabled>"
        case nil: return ""
        }
    }

    /// 正文文本节点：把 `[^label]` 渲染成上标链接。
    ///
    /// 只处理 `Text` 节点（正文），代码块 / 行内代码各自有自己的分支，
    /// 因此代码里出现的 `[^1]` 不会被误当成脚注。
    private func textHTML(_ text: String) -> String {
        guard text.contains("[^") else { return escape(text) }
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: #"\[\^([^\]\n]+)\]"#) else {
            return escape(text)
        }
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                result += escape(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            let label = ns.substring(with: match.range(at: 1))
            // id 用于脚注项里的「↩」反跳；同一脚注被引用多次时 id 会重复（浏览器取首个）。
            result += "<sup><a id=\"fnref-\(escape(label))\" href=\"#fn-\(escape(label))\">\(escape(label))</a></sup>"
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            result += escape(ns.substring(from: cursor))
        }
        return result
    }

    /// 从 Markdown 源里摘出脚注定义行（`[^label]: 内容`），返回去掉这些行之后的正文与定义列表。
    ///
    /// 为什么要先摘：swift-markdown 没有脚注节点，`[^1]: 内容` 会命中「引用式链接定义」语法，
    /// 使正文里的 `[^1]` 变成指向「内容」的链接、脚注正文反而丢失。
    /// 限制：只支持单行定义，缩进续行会被当成普通段落保留。
    static func extractFootnotes(_ markdown: String) -> (content: String, notes: [(label: String, text: String)]) {
        guard markdown.contains("[^") else { return (markdown, []) }
        let regex = try? NSRegularExpression(pattern: #"^[ \t]*\[\^([^\]\n]+)\]:[ \t]*(.*)$"#)
        guard let regex else { return (markdown, []) }

        var kept: [String] = []
        var notes: [(label: String, text: String)] = []
        for line in markdown.components(separatedBy: "\n") {
            let nsLine = line as NSString
            if let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) {
                let label = nsLine.substring(with: match.range(at: 1))
                let text = nsLine.substring(with: match.range(at: 2))
                    .trimmingCharacters(in: .whitespaces)
                notes.append((label, text))
            } else {
                kept.append(line)
            }
        }
        return (kept.joined(separator: "\n"), notes)
    }

    /// 脚注区：正文之后输出一个小节（纯文本内容；脚注正文里的行内 Markdown 暂不解析）。
    private func footnotesHTML(_ notes: [(label: String, text: String)]) -> String {
        guard !notes.isEmpty else { return "" }
        var html = "\n<section class=\"footnotes\"><hr><ol>"
        for note in notes {
            let back = "<a href=\"#fnref-\(escape(note.label))\">↩</a>"
            html += "<li id=\"fn-\(escape(note.label))\">\(escape(note.text)) \(back)</li>"
        }
        html += "</ol></section>"
        return html
    }

    /// Markdown 图片 → 内联 `data:` URI 的 `<img>`。
    ///
    /// 与阅读视图的 `ImageRenderer.classify` 保持同一安全口径：**不联网**——
    /// `http(s)` / 协议相对 `//` / 源文本里手写的 `data:` 一律不写入 `src`
    /// （后两者还会把巨型 base64 塞进 PDF），只输出 alt 文字占位；
    /// `javascript:` 等未知 scheme 同样拒绝。
    ///
    /// 本地图片（相对路径 / 绝对路径 / `file://`）读取后内联为 data URI：
    /// `WKWebView.loadHTMLString` 的页面无法读 `file://`，不内联 PDF 里就没有图片。
    /// 读取失败、超过 `maxInlineImageBytes` 或扩展名推断不出 MIME 时退化为 alt 文本。
    ///
    /// 源为空（`![]( )`）时只保留 alt 文本，不产生空 `src` 的破图图标。
    private func imageHTML(_ image: Image) -> String {
        let alt = image.plainText
        let title = image.title ?? ""
        let raw = (image.source ?? "").trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return escape(alt) }

        let lower = raw.lowercased()
        let blockedPrefixes = ["http://", "https://", "//", "data:"]
        if blockedPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return "<span class=\"remote-image\">\(escape(alt.isEmpty ? raw : alt))</span>"
        }
        // 只放行无 scheme（相对路径）、绝对路径与 file://；其余 scheme 视为不安全。
        if let scheme = URLComponents(string: raw)?.scheme, scheme.lowercased() != "file" {
            return escape(alt.isEmpty ? raw : alt)
        }

        guard let url = resolveLocalImageURL(raw),
              let mime = mimeType(for: url),
              let data = readImageData(at: url) else {
            return escape(alt.isEmpty ? raw : alt)
        }

        var attributes = "src=\"data:\(mime);base64,\(data.base64EncodedString())\" alt=\"\(escape(alt))\""
        if !title.isEmpty { attributes += " title=\"\(escape(title))\"" }
        return "<img \(attributes)>"
    }

    /// 把 Markdown 里的图片源解析成磁盘 URL；相对路径以 `baseDirectory` 为基准。
    private func resolveLocalImageURL(_ raw: String) -> URL? {
        if let url = URL(string: raw), url.isFileURL { return url }
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
        guard let baseDirectory else { return nil }
        return baseDirectory.appendingPathComponent(raw)
    }

    /// 读取图片字节，并对大小做上限检查（避免把超大清空进 HTML 字符串）。
    private func readImageData(at url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url),
              !data.isEmpty,
              data.count <= maxInlineImageBytes else { return nil }
        return data
    }

    /// 按扩展名推断 MIME；推断不出（无扩展名 / 未知格式）返回 nil，调用方退化为 alt 文本。
    private func mimeType(for url: URL) -> String? {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
    }

    /// 代码文本按「全角 / 半角」分段：中文段包 `span.code-cjk`（用 CSS letter-spacing
    /// 模拟 TextKit 里的 kern 补偿），西文段直接输出。
    private func codeHTML(_ text: String) -> String {
        guard CodeTypography.hasOfficialPair(style: codeStyle) else {
            return escape(text)
        }
        var result = ""
        var buffer = ""
        var bufferIsWide = false

        func flush() {
            guard !buffer.isEmpty else { return }
            let escaped = escape(buffer)
            result += bufferIsWide ? "<span class=\"code-cjk\">\(escaped)</span>" : escaped
            buffer = ""
        }

        for scalar in text.unicodeScalars {
            let wide = CodeTypography.isWide(scalar)
            if wide != bufferIsWide {
                flush()
                bufferIsWide = wide
            }
            buffer.append(Character(scalar))
        }
        flush()
        return result
    }

    private func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
