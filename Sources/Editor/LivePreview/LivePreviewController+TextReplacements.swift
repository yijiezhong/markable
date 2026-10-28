import AppKit

/// `LivePreviewController` 的字符替换收集：图片、Mermaid、数学占位、任务列表、
/// 列表项目符号、硬换行、元数据、分页、转义/实体、自动链接、目录、脚注区与内链附件。
/// （自 `LivePreviewController.swift` 机械拆分，逻辑未改。）
extension LivePreviewController {
    // MARK: - 字符替换收集

    /// `![alt](path)` → 图片附件（本地）或占位附件（远程 / 缺失）。
    /// 附件必须落在 **U+FFFC** 字符上才会渲染，故在替换阶段把 alt 范围换成附件字符。
    func collectImageReplacements(
        in storage: NSMutableAttributedString,
        baseDirectory: URL?,
        into list: inout [(range: NSRange, text: NSAttributedString)]
    ) {
        let text = storage.string
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        // 引用式图片定义：`[label]: url "title"`
        var definitions: [String: String] = [:]
        if let defRegex = try? NSRegularExpression(
            pattern: #"^\[([^\]\n]+)\]:\s*(?:<([^>\n]*)>|(\S+))(?:\s+["'][^"']*["'])?[ \t]*$"#,
            options: [.anchorsMatchLines]
        ) {
            for match in defRegex.matches(in: text, range: full) {
                let label = ns.substring(with: match.range(at: 1)).lowercased()
                let urlRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
                definitions[label] = ns.substring(with: urlRange)
            }
        }

        func makeAttachment(path: String, alt: String) -> NSTextAttachment {
            switch ImageRenderer.classify(path, relativeTo: baseDirectory) {
            case .local(let url):
                return ImageRenderer.attachment(forLocal: url)
                    ?? ImageRenderer.placeholderAttachment(text: "🖼 \(alt.isEmpty ? path : alt)（无法读取）")
            case .remote(let raw):
                return ImageRenderer.placeholderAttachment(text: "🌐 \(raw)")
            case .missing(let raw):
                return ImageRenderer.placeholderAttachment(text: "🖼 \(alt.isEmpty ? raw : alt)（缺失）")
            }
        }

        /// 附件字符（U+FFFC）带上 alt：复制时据此换成 `[图片: alt]`，而不是把占位符方框抄走。
        func attachedImage(path: String, alt: String) -> NSAttributedString {
            let text = NSMutableAttributedString(attachment: makeAttachment(path: path, alt: alt))
            text.addAttribute(.markableImageAlt, value: alt,
                              range: NSRange(location: 0, length: text.length))
            return text
        }

        // 行内图片：`![alt](path "title")` / `![alt](<path with space> "title")`（alt 可空）
        // 只替换 alt，其余标记由 hideMarkup 隐藏。
        if let imageRegex = try? NSRegularExpression(
            pattern: #"!\[([^\]\n]*)\]\(\s*(?:<([^>\n]*)>|([^)\s]+))(?:\s+["'][^"']*["'])?\s*\)"#
        ) {
            for match in imageRegex.matches(in: text, range: full) {
                let alt = ns.substring(with: match.range(at: 1))
                let pathRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
                let path = ns.substring(with: pathRange)
                list.append((match.range(at: 1), attachedImage(path: path, alt: alt)))
            }
        }

        // 引用式图片：`![alt][ref]`（整段替换为附件；标记没有 hideMarkup 处理）
        if let refRegex = try? NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\[([^\]\n]*)\]"#) {
            for match in refRegex.matches(in: text, range: full) {
                let alt = ns.substring(with: match.range(at: 1))
                let label = match.range(at: 2).length > 0 ? ns.substring(with: match.range(at: 2)) : alt
                guard let url = definitions[label.lowercased()] else { continue }
                list.append((match.range, attachedImage(path: url, alt: alt)))
            }
        }
    }

    /// ```mermaid 代码块 → 图片附件；失败时保留源码并在其前插入原因提示。
    func collectMermaidReplacements(
        in storage: NSMutableAttributedString,
        into list: inout [(range: NSRange, text: NSAttributedString)]
    ) {
        let text = storage.string
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: #"```mermaid[ \t]*\n([\s\S]*?)```"#) else { return }
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let codeRange = match.range(at: 1)
            guard codeRange.location != NSNotFound else { continue }
            let code = ns.substring(with: codeRange)
            if let image = MermaidRenderer.image(forSource: code) {
                list.append((match.range, Self.taggedAttachment(image, kind: "mermaid", source: code)))
                continue
            }
            let reason: String
            if let type = MermaidRenderer.unsupportedType(of: code) {
                reason = "⚠︎ Mermaid 图类型「\(type)」暂不支持，已回退源码"
            } else {
                reason = "⚠︎ Mermaid 渲染失败，已回退源码"
            }
            let hint = NSAttributedString(string: reason + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: max(11, baseSize - 2)),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ])
            list.append((NSRange(location: match.range.location, length: 0), hint))
        }
    }

    /// 数学公式：命中缓存 → 附件；未命中 → 待渲染列表。
    func collectMathReplacements(
        in storage: NSMutableAttributedString,
        into list: inout [(range: NSRange, text: NSAttributedString)]
    ) -> [(tex: String, display: Bool)] {
        let text = storage.string
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let patterns: [(String, Bool)] = [
            (#"\$\$([\s\S]+?)\$\$"#, true),
            (#"\\\[([\s\S]+?)\\\]"#, true),
            (#"\\\(([\s\S]+?)\\\)"#, false),
            (#"(?<![\\\w$])\$([^\$\n]+?)\$(?!\w)"#, false),
        ]

        var found: [(range: NSRange, tex: String, display: Bool)] = []
        for (pattern, display) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: full) {
                let content = match.range(at: 1)
                guard content.location != NSNotFound else { continue }
                found.append((match.range, ns.substring(with: content), display))
            }
        }
        // ```math 围栏：内容按块级公式排版
        if let fence = try? NSRegularExpression(pattern: #"```math[ \t]*\n([\s\S]*?)```"#) {
            for match in fence.matches(in: text, range: full) {
                let content = match.range(at: 1)
                guard content.location != NSNotFound else { continue }
                found.append((match.range, ns.substring(with: content), true))
            }
        }

        var pending: [(tex: String, display: Bool)] = []
        var queued = Set<String>()
        var occupied: [NSRange] = []
        for item in found.sorted(by: { $0.range.location < $1.range.location }) {
            if occupied.contains(where: { NSIntersectionRange($0, item.range).length > 0 }) { continue }
            occupied.append(item.range)
            if let image = MathRenderer.shared.cachedImage(tex: item.tex, display: item.display) {
                list.append((item.range, Self.taggedAttachment(image, kind: "math", source: item.tex)))
            } else {
                // 未命中缓存（排队中/渲染中）：先用占位符，避免首屏闪现 `$…$` 源码；
                // 渲染完成后局部替换为公式图片。
                list.append((item.range, mathPlaceholder(display: item.display, tex: item.tex)))
                if !MathRenderer.shared.isRendering(tex: item.tex, display: item.display) {
                    let key = "\(item.display):\(item.tex)"
                    if !queued.contains(key) { queued.insert(key); pending.append((item.tex, item.display)) }
                }
            }
        }
        return pending
    }

    /// 数学公式占位符：异步渲染期间先显示占位，避免首屏闪现 `$…$` 源码。
    ///
    /// 占位文字带 `.markableAttachmentKind`：复制时按公式处理成 `[公式]`，
    /// 不会把「⋯ 公式渲染中 ⋯」这种临时提示抄进剪贴板。
    private func mathPlaceholder(display: Bool, tex: String) -> NSAttributedString {
        let text = display ? "⋯ 公式渲染中 ⋯" : "⋯"
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: max(11, baseSize - 2)),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .markableMathKey: "\(display ? "1" : "0")|\(tex)",
            .markableAttachmentKind: "math",
        ])
    }

    /// 数学渲染完成后，只把占位符替换成公式附件（增量更新，不重建整篇）。
    func replaceMathPlaceholders() {
        guard let textView = currentTextView, let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        var edits: [(range: NSRange, text: NSAttributedString)] = []
        storage.enumerateAttribute(.markableMathKey, in: full, options: []) { value, range, _ in
            guard let key = value as? String,
                  let separator = key.firstIndex(of: "|") else { return }
            let display = key[..<separator] == "1"
            let tex = String(key[key.index(after: separator)...])
            guard let image = MathRenderer.shared.cachedImage(tex: tex, display: display) else { return }
            edits.append((range, Self.taggedAttachment(image, kind: "math", source: tex)))
        }
        guard !edits.isEmpty else { return }
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            storage.replaceCharacters(in: edit.range, with: edit.text)
        }
        if let layoutManager = textView.textLayoutManager,
           let contentManager = layoutManager.textContentManager {
            layoutManager.invalidateLayout(for: NSTextRange(location: contentManager.documentRange.location))
        }
        // 同步缓存，避免下次命中旧占位
        if lastRenderKey != nil {
            lastRenderResult = storage.copy() as? NSAttributedString
        }
    }

    /// 任务列表标记 `[ ]` / `[x]` → ☐ / ☑。
    func collectTaskMarkerReplacements(
        in storage: NSMutableAttributedString,
        into list: inout [(range: NSRange, text: NSAttributedString)]
    ) {
        let text = storage.string
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(
            pattern: #"^(\s*(?:[-*+]|\d+\.)?\s*)(\[[ xX]?\])(?= )"#,
            options: [.anchorsMatchLines]
        ) else { return }
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let inner = ns.substring(with: match.range(at: 2))   // 形如 `[ ]` / `[x]` / `[]`
            let box = (inner.contains("x") || inner.contains("X")) ? "☑" : "☐"
            list.append((match.range(at: 2), NSAttributedString(string: box, attributes: baseAttributes)))
        }
    }

    /// 无序列表标记 → 项目符号（`•`）；任务列表隐藏 `- ` 前缀（☐/☑ 已能表示）。
    /// 仅在 `bulletLists` 开启时生效；有序列表保持 `1.` 编号不变。
    func collectListBulletReplacements(
        in storage: NSMutableAttributedString,
        into list: inout [(range: NSRange, text: NSAttributedString)]
    ) {
        guard bulletLists else { return }
        let text = storage.string
        var handled = Set<Int>()

        // 任务列表：`- [ ]` → `☐`（去掉 `- ` 前缀与空格）
        for item in cachedBlockRanges where item.kind == .taskList {
            guard handled.insert(item.range.location).inserted else { continue }
            guard let prefix = listMarkerPrefix(in: text, lineStart: item.range.location), !prefix.isOrdered else { continue }
            list.append((prefix.range, NSAttributedString(string: "", attributes: baseAttributes)))
        }
        // 无序列表：`-` / `*` / `+` → `•`（保留前导缩进）
        for item in cachedBlockRanges where item.kind == .listItem {
            guard handled.insert(item.range.location).inserted else { continue }
            guard let prefix = listMarkerPrefix(in: text, lineStart: item.range.location), !prefix.isOrdered else { continue }
            list.append((prefix.range, NSAttributedString(string: "• ", attributes: baseAttributes)))
        }
    }

    /// 行首列表前缀：返回「标记 + 后随空白」的范围，以及是否为有序列表。
    private func listMarkerPrefix(in text: String, lineStart: Int) -> (range: NSRange, isOrdered: Bool)? {
        let ns = text as NSString
        guard lineStart >= 0, lineStart < ns.length else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
        guard lineRange.length > 0 else { return nil }
        let line = ns.substring(with: lineRange) as NSString
        guard let regex = try? NSRegularExpression(pattern: #"^([ \t]*)([-*+]|\d+\.)([ \t]+)"#) else { return nil }
        guard let match = regex.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length)) else { return nil }
        let marker = match.range(at: 2)
        let spaces = match.range(at: 3)
        let start = marker.location
        let end = spaces.location + spaces.length
        let range = NSRange(location: lineRange.location + start, length: end - start)
        let markerText = ns.substring(with: NSRange(location: lineRange.location + marker.location, length: marker.length))
        return (range, markerText.rangeOfCharacter(from: .decimalDigits) != nil)
    }

    /// 硬换行标记：行尾两空格或反斜杠 → 去掉标记（保留换行）。
    func collectHardBreakReplacements(
        in storage: NSMutableAttributedString,
        into list: inout [(range: NSRange, text: NSAttributedString)]
    ) {
        let text = storage.string
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        // 行尾 ≥2 空格 + 换行
        if let regex = try? NSRegularExpression(pattern: #"[ \t]{2,}\n"#) {
            for match in regex.matches(in: text, range: full) {
                list.append((match.range, NSAttributedString(string: "\n", attributes: baseAttributes)))
            }
        }
        // 行尾反斜杠 + 换行（且反斜杠前不是反斜杠）
        if let regex = try? NSRegularExpression(pattern: #"(?<!\\)\\\n"#) {
            for match in regex.matches(in: text, range: full) {
                list.append((match.range, NSAttributedString(string: "\n", attributes: baseAttributes)))
            }
        }
        // 行内 <br> / <br/> / <br /> → 行分隔符（不新增段落）
        if let regex = try? NSRegularExpression(pattern: #"<br\s*/?>"#, options: [.caseInsensitive]) {
            let tableRanges = cachedBlockRanges.filter { $0.kind == .table }.map(\.range)
            // 反引号行内代码内的 `<br>` 保持字面（与表格单元格 normalizeCellBreaks 的保护一致）
            let inlineCodeRanges = cachedInlineRanges.filter { $0.kind == .code }.map(\.range)
            for match in regex.matches(in: text, range: full) {
                if tableRanges.contains(where: { NSLocationInRange(match.range.location, $0) }) { continue }
                if inlineCodeRanges.contains(where: { NSLocationInRange(match.range.location, $0) }) { continue }
                list.append((match.range, NSAttributedString(string: "\u{2028}", attributes: baseAttributes)))
            }
        }
    }

    /// 元数据插值：正文 `[%key]` → front matter 的值（未定义按原文保留）。
    func collectMetadataReplacements(
        in storage: NSMutableAttributedString,
        into list: inout [(range: NSRange, text: NSAttributedString)]
    ) {
        let text = storage.string
        let ns = text as NSString
        let metadata = FrontMatter.parse(text)
        guard !metadata.isEmpty, let regex = try? NSRegularExpression(pattern: #"\[%([^\]\n]+)\]"#) else { return }
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces).lowercased()
            guard let value = metadata[key] else { continue }
            list.append((match.range, NSAttributedString(string: value, attributes: baseAttributes)))
        }
    }

    /// 文档内分页：单独一行 `===` / `+++` → 分隔线。
    func collectPageBreakReplacements(
        in storage: NSMutableAttributedString,
        into list: inout [(range: NSRange, text: NSAttributedString)]
    ) {
        let text = storage.string
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: #"^(===+|\+\+\+)[ \t]*$"#, options: [.anchorsMatchLines]) else { return }
        let divider = String(repeating: "─", count: 24)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            list.append((match.range, NSAttributedString(string: divider, attributes: attributes)))
        }
    }

    /// Markdown 转义：`\*` → `*`（去掉反斜杠，显示字面字符）。
    /// 表格单元格内的转义由表格重建（`splitTableRow`）处理，这里排除表格范围，
    /// 否则单字符替换会与"整表替换"重叠，导致表格重建被跳过。
    func collectEscapeReplacements(
        in storage: NSMutableAttributedString,
        into list: inout [(range: NSRange, text: NSAttributedString)]
    ) {
        let text = storage.string
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: #"\\([\\`*_{}\[\]()#+\-.!|>~^=])"#) else { return }
        let excluded = cachedBlockRanges
            .filter { $0.kind == .table || $0.kind == .comment || $0.kind == .frontMatter || $0.kind == .linkRef }
            .map(\.range)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if excluded.contains(where: { NSLocationInRange(match.range.location, $0) }) { continue }
            let literal = ns.substring(with: match.range(at: 1))
            list.append((match.range, NSAttributedString(string: literal, attributes: baseAttributes)))
        }
    }

    /// HTML 实体：`&amp;` / `&#169;` / `&#x2F;` → 对应字符（未知实体保留原样）。
    /// 同转义：表格内的实体由表格重建处理，这里排除表格范围。
    func collectEntityReplacements(
        in storage: NSMutableAttributedString,
        into list: inout [(range: NSRange, text: NSAttributedString)]
    ) {
        let text = storage.string
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: #"&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z][a-zA-Z0-9]*);"#) else { return }
        let excluded = cachedBlockRanges
            .filter { $0.kind == .table || $0.kind == .comment || $0.kind == .frontMatter || $0.kind == .linkRef }
            .map(\.range)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if excluded.contains(where: { NSLocationInRange(match.range.location, $0) }) { continue }
            let token = ns.substring(with: match.range)
            guard let decoded = Self.decodeEntity(token) else { continue }
            list.append((match.range, NSAttributedString(string: decoded, attributes: baseAttributes)))
        }
    }

    private static func decodeEntity(_ token: String) -> String? {
        guard token.hasPrefix("&"), token.hasSuffix(";") else { return nil }
        let body = String(token.dropFirst().dropLast())
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            guard let value = UInt32(body.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        if body.hasPrefix("#") {
            guard let value = UInt32(body.dropFirst(), radix: 10), let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
            "nbsp": "\u{00A0}", "copy": "©", "reg": "®", "trade": "™",
            "hellip": "…", "mdash": "—", "ndash": "–", "times": "×", "divide": "÷",
            "laquo": "«", "raquo": "»", "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’",
            "deg": "°", "plusmn": "±", "middot": "·", "bull": "•", "dagger": "†",
            "permil": "‰", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢",
            "sect": "§", "para": "¶", "sup2": "²", "sup3": "³", "frac12": "½",
        ]
        return named[body]
    }

    /// 自动链接：`<https://…>` / `<mailto:…>` 与裸 URL（GFM autolink）→ 可点击链接。
    /// 排除代码 / 表格 / 注释 / front matter / 链接定义行 / 已有链接与图片，避免误伤。
    func collectAutolinkReplacements(
        in storage: NSMutableAttributedString,
        into list: inout [(range: NSRange, text: NSAttributedString)]
    ) {
        let text = storage.string
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        var excluded = cachedBlockRanges.filter { item in
            switch item.kind {
            case .table, .comment, .frontMatter, .linkRef, .codeBlock: return true
            default: return false
            }
        }.map(\.range)
        excluded += cachedInlineRanges.filter { item in
            switch item.kind {
            case .link, .image, .code: return true
            default: return false
            }
        }.map(\.range)

        func linkAttributes(_ url: String) -> [NSAttributedString.Key: Any] {
            var attributes = baseAttributes
            attributes[.foregroundColor] = NSColor.linkColor
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.link] = URL(string: url)
            return attributes
        }

        // 1) 尖括号自动链接 `<url>` / `<mailto:…>`
        var angleRanges: [NSRange] = []
        if let angleRegex = try? NSRegularExpression(pattern: #"<(https?://[^>\s]+|mailto:[^>\s]+)>"#) {
            for match in angleRegex.matches(in: text, range: full) {
                if excluded.contains(where: { NSLocationInRange(match.range.location, $0) }) { continue }
                angleRanges.append(match.range)
                let urlText = ns.substring(with: match.range(at: 1))
                list.append((match.range, NSAttributedString(string: urlText, attributes: linkAttributes(urlText))))
            }
        }

        // 2) 裸 URL：`https://…`（去尾部标点；已被尖括号/链接/代码覆盖的跳过）
        if let bareRegex = try? NSRegularExpression(pattern: #"(?<![\w/])(https?://[^\s<>()\[\]"']+)"#) {
            for match in bareRegex.matches(in: text, range: full) {
                if excluded.contains(where: { NSLocationInRange(match.range.location, $0) }) { continue }
                if angleRanges.contains(where: { NSLocationInRange(match.range.location, $0) }) { continue }
                var urlText = ns.substring(with: match.range)
                while let last = urlText.last, ".,;:!?)]}'\"".contains(last) {
                    urlText.removeLast()
                }
                guard !urlText.isEmpty, URL(string: urlText) != nil else { continue }
                let range = NSRange(location: match.range.location, length: (urlText as NSString).length)
                list.append((range, NSAttributedString(string: urlText, attributes: linkAttributes(urlText))))
            }
        }
    }

    /// 正文内目录：单独一行 `{{TOC}}` / `[TOC]` / `[toc]` → 生成层级目录。
    func collectTOCReplacements(
        in storage: NSMutableAttributedString,
        into list: inout [(range: NSRange, text: NSAttributedString)]
    ) {
        let text = storage.string
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: #"^\{\{TOC\}\}$|^\[TOC\]$|^\[toc\]$"#, options: [.anchorsMatchLines]) else { return }
        let outline = MarkdownEngine().outline(of: text)
        guard !outline.isEmpty else { return }
        let toc = outline.map { item in
            String(repeating: "  ", count: max(0, item.level - 1)) + "• " + item.title
        }
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let attributed = NSMutableAttributedString(string: toc.joined(separator: "\n"), attributes: baseAttributes)
            // 每条目录项可点击跳转（自定义 scheme，由 MarkdownTextView 处理）
            var offset = 0
            for item in outline {
                let line = String(repeating: "  ", count: max(0, item.level - 1)) + "• " + item.title
                let lineRange = NSRange(location: offset, length: (line as NSString).length)
                if let url = Self.anchorURL(for: item.title),
                   lineRange.location + lineRange.length <= attributed.length {
                    attributed.addAttribute(.link, value: url, range: lineRange)
                    attributed.addAttribute(.foregroundColor, value: NSColor.linkColor, range: lineRange)
                }
                offset += lineRange.length + 1   // +1 for "\n"
            }
            // 给目录整体打标记：滚动定位时跳过目录条目（避免命中目录而非正文标题）
            attributed.addAttribute(.markableTOC, value: true, range: NSRange(location: 0, length: attributed.length))
            list.append((match.range, attributed))
        }
    }

    /// 内部锚点 URL：`markable-anchor://scroll?text=<目标文本>`。
    private static func anchorURL(for text: String) -> URL? {
        var components = URLComponents()
        components.scheme = "markable-anchor"
        components.host = "scroll"
        components.queryItems = [URLQueryItem(name: "text", value: text)]
        return components.url
    }

    /// `[[wiki]]` 内链 → 可点击（自定义 scheme，由 `MarkdownTextView` 解析为"打开同目录文件"）。
    func attachWikiLinks(in storage: NSMutableAttributedString) {
        let text = storage.string
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: #"\[\[([^\]\n]+)\]\]"#) else { return }
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let inner = ns.substring(with: match.range(at: 1))
            let name = (inner.split(separator: "|").first.map(String.init) ?? inner)
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            var components = URLComponents()
            components.scheme = "markable-wiki"
            components.host = "open"
            components.queryItems = [URLQueryItem(name: "name", value: name)]
            guard let url = components.url else { continue }
            storage.addAttribute(.link, value: url, range: match.range)
        }
    }

    /// 交叉引用 `[文字][标签]` → 可点击滚动到带该标签的标题（复用锚点 scheme）。
    func attachCrossReferenceLinks(in storage: NSMutableAttributedString) {
        let text = storage.string
        let ns = text as NSString
        let targets = CrossReference.targets(in: text)
        guard !targets.isEmpty else { return }
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\[\]\n]+)\]\[([^\[\n]+)\]"#) else { return }

        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let label = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            guard let title = targets[label.lowercased()] else { continue }
            // 真正的引用式链接定义优先，不覆盖
            if CrossReference.hasDefinition(label, in: text) { continue }
            guard let url = Self.anchorURL(for: title) else { continue }
            storage.addAttribute(.link, value: url, range: match.range)
        }
    }

    /// 脚注引用 `[^x]` → 可点击滚动到定义行 `[^x]:`。
    func attachFootnoteLinks(in storage: NSMutableAttributedString) {        let text = storage.string
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: #"\[\^([^\]\n]+)\](?!:)"#) else { return }
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let label = ns.substring(with: match.range(at: 1))
            guard let url = Self.anchorURL(for: "[^\(label)]:") else { continue }
            storage.addAttribute(.link, value: url, range: match.range)
        }
    }

    private static func attachment(_ image: NSImage) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(origin: .zero, size: image.size)
        return NSAttributedString(attachment: attachment)
    }

    /// 带语义的附件（Mermaid / 数学）：复制时按 kind 换成可读占位文本，
    /// 源码用于 Mermaid 占位里的 `flowchart TD` 摘要。
    private static func taggedAttachment(
        _ image: NSImage,
        kind: String,
        source: String = ""
    ) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: attachment(image))
        let range = NSRange(location: 0, length: text.length)
        text.addAttribute(.markableAttachmentKind, value: kind, range: range)
        if !source.isEmpty {
            text.addAttribute(.markableAttachmentSource, value: source, range: range)
        }
        return text
    }

    /// 真脚注区：把 `[^x]: …` 定义从正文移到文末"脚注"区；正文引用 `[^x]` 改为上标编号并可点击跳转。
    func collectFootnoteAreaReplacements(
        in storage: NSMutableAttributedString,
        into list: inout [(range: NSRange, text: NSAttributedString)]
    ) {
        let text = storage.string
        let ns = text as NSString
        guard let defRegex = try? NSRegularExpression(pattern: #"^\[\^([^\]\n]+)\]:[ \t]*(.*)$"#, options: [.anchorsMatchLines]) else { return }
        let defMatches = defRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !defMatches.isEmpty else { return }

        var definitions: [(label: String, body: String, lineRange: NSRange)] = []
        for match in defMatches {
            let label = ns.substring(with: match.range(at: 1))
            let body = ns.substring(with: match.range(at: 2))
            definitions.append((label, body, ns.lineRange(for: match.range)))
        }

        // 正文引用 `[^x]`（排除定义行内部、以及 `[^x]:` 形式）
        guard let refRegex = try? NSRegularExpression(pattern: #"\[\^([^\]\n]+)\](?!:)"#) else { return }
        var refs: [(label: String, range: NSRange)] = []
        var order: [String] = []
        for match in refRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let insideDefinition = definitions.contains { def in
                match.range.location >= def.lineRange.location
                    && match.range.location + match.range.length <= def.lineRange.location + def.lineRange.length
            }
            guard !insideDefinition else { continue }
            let label = ns.substring(with: match.range(at: 1))
            if !order.contains(where: { $0.lowercased() == label.lowercased() }) { order.append(label) }
            refs.append((label, match.range))
        }

        // 编号：先按引用出现顺序，再给未被引用的定义补号
        var numbers: [String: Int] = [:]
        var next = 1
        for label in order { numbers[label.lowercased()] = next; next += 1 }
        for def in definitions where numbers[def.label.lowercased()] == nil {
            numbers[def.label.lowercased()] = next; next += 1
        }
        func body(of label: String) -> String? {
            definitions.first { $0.label.lowercased() == label.lowercased() }?.body
        }

        // 1) 删除正文里的定义行
        for def in definitions {
            list.append((def.lineRange, NSAttributedString(string: "", attributes: baseAttributes)))
        }

        // 2) 引用 → 上标编号（可点击跳到脚注条目）
        for ref in refs {
            guard let number = numbers[ref.label.lowercased()] else { continue }
            let attributed = NSMutableAttributedString(string: String(number), attributes: [
                .font: NSFont.systemFont(ofSize: baseSize * 0.75, weight: .semibold),
                .foregroundColor: NSColor.controlAccentColor,
                .baselineOffset: 4.0,
            ])
            if let body = body(of: ref.label), !body.isEmpty, let url = Self.anchorURL(for: body) {
                attributed.addAttribute(.link, value: url, range: NSRange(location: 0, length: attributed.length))
            }
            list.append((ref.range, attributed))
        }

        // 3) 文末追加脚注区
        let sorted = definitions.sorted { (numbers[$0.label.lowercased()] ?? 0) < (numbers[$1.label.lowercased()] ?? 0) }
        var area = "\n──────────\n脚注\n\n"
        for def in sorted {
            area += "\(numbers[def.label.lowercased()] ?? 0). \(def.body)\n"
        }
        let areaAttributes: [NSAttributedString.Key: Any] = [
            .font: typography.family.font(ofSize: max(9, baseSize - 1), weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: baseParagraphStyle,
        ]
        list.append((NSRange(location: storage.length, length: 0),
                     NSAttributedString(string: area, attributes: areaAttributes)))
    }

}
