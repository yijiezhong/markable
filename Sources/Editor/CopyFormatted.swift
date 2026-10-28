import AppKit

extension NSAttributedString.Key {
    /// 渲染期**隐藏**的 Markdown 语法标记（值 `true`）。
    ///
    /// 标题的 `# `、`**`、反引号、链接括号、代码围栏、引用前缀、注释 / front matter /
    /// 引用式链接定义行等都用「0.1pt + 透明色」原地隐藏而不是删除——保留字符是为了让
    /// TextKit 的排版与选区偏移稳定。它们不是文档内容：复制时统一剔除（见 `CopyFormatted`）。
    static let markableHidden = NSAttributedString.Key("markable.hidden")
    /// 渲染期插入、**可见但不属于内容**的文本（值 `true`），目前用于代码块行号。
    ///
    /// 与 `.markableHidden` 分开是因为语义不同：行号是给眼睛看的排版辅助，
    /// 既不隐藏也不能被复制走。
    static let markableCopySkip = NSAttributedString.Key("markable.copySkip")
    /// 图片附件字符（U+FFFC）携带的 alt 文本（值 `String`，可为空）。
    ///
    /// 复制时把附件占位符替换成 `[图片: alt]`（alt 为空则 `[图片]`），
    /// 让纯文本结果仍能看出「这里有一张图」。
    static let markableImageAlt = NSAttributedString.Key("markable.imageAlt")
    /// 表格单元格标记（值 `String`：`"表序,行,列"`，行/列从 0 起）。
    ///
    /// 表格在渲染时被重建为 `NSTextTable`（每个单元格一段，末尾带换行），直接复制
    /// 会把每个单元格摊成一行。复制时据此把单元格重新拼成 TSV（见 `CopyFormatted`）。
    static let markableTableCell = NSAttributedString.Key("markable.tableCell")
    /// 附件语义（值 `String`：`"mermaid"` / `"math"`）。
    ///
    /// Mermaid 图与数学公式在渲染时是附件字符（U+FFFC），直接删掉会让复制结果凭空
    /// 少一块。复制时按语义换成 `[Mermaid: flowchart TD]` / `[公式]` 这类可读占位。
    static let markableAttachmentKind = NSAttributedString.Key("markable.attachmentKind")
    /// 附件源码（值 `String`），配合 `.markableAttachmentKind` 生成截断后的占位文本。
    static let markableAttachmentSource = NSAttributedString.Key("markable.attachmentSource")
}

/// 复制净化管线：让「复制」只输出**读者看得见的内容**。
///
/// 渲染层为了让 Markdown 看起来像成品，往文本里塞了不少内部结构：隐藏的语法标记、
/// 附件占位字符（U+FFFC）、代码行号、标题编号，以及被拆成 `NSTextTable` 的表格。复制时
/// 必须按下面的顺序把它们还原成用户真正想粘贴的东西：
///
/// 1. **删除隐藏 / 跳过标记**：先把不属于内容的字符去掉，后面每一步看到的都是可见文本；
///    整行都被隐藏的行（front matter / 引用式链接定义行 / 代码围栏行）连同换行一起删，
///    避免留下空行；
/// 2. **引用竖线还原**：渲染期插入的 `│`（带 `.markableQuoteBar`）等长换回 `>`，
///    正文里用户自己写的 `│` 不带标记，原样保留；
/// 3. **附件占位符**：图片 → `[图片: alt]`，Mermaid → `[Mermaid: …]`，数学 → `[公式]`，
///    其余附件删除，保证剪贴板里没有 U+FFFC；
/// 4. **表格 TSV**：最后做，因为它要读 `.markableTableCell` 把**整段**选区重新排布
///    （行内单元格之间变 tab、行之间保留换行，表格与相邻正文之间留一个空行）。
///
/// 处理结果同时用于纯文本与 RTF（调用方用 `QuoteBarCopy.write` 写入剪贴板），
/// 因此粘贴到富文本应用也不会带回隐藏标记或附件方框。
enum CopyFormatted {
    /// TextKit 里附件字符的固定码位。
    private static let attachmentCharacter: unichar = 0xFFFC
    /// 渲染期用来代替 `>` 的竖线（U+2502）。
    private static let renderedQuoteBar: unichar = 0x2502
    /// 还原后的 Markdown 引用标记。
    private static let quoteMarker = ">"
    /// 单元格内换行（`<br>` 渲染成 U+2028 行分隔符）。
    private static let lineSeparator: unichar = 0x2028

    /// 选区里需要从结果中剥离的内部属性（不写进 RTF）。
    private static let internalKeys: [NSAttributedString.Key] = [
        .markableQuoteBar, .markableQuoteSourcePrefix, .markableTOC, .markableMathKey,
        .markableHidden, .markableCopySkip, .markableImageAlt, .markableTableCell,
        .markableAttachmentKind, .markableAttachmentSource,
    ]

    /// 插入换行 / tab 时用的中性属性（不继承单元格的表格块 / 对齐）。
    private static var plainAttributes: [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        return [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .paragraphStyle: style]
    }

    // MARK: - 入口

    /// 若选区里含渲染内部结构，返回净化后的属性字符串；返回 `nil` 表示选区本来就是
    /// 干净的可见内容，调用方应走 AppKit 的默认写入（保持原生 `│` 等不被误伤）。
    static func cleanedSelection(in storage: NSAttributedString, range: NSRange) -> NSAttributedString? {
        guard storage.length > 0 else { return nil }
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        guard clamped.length > 0 else { return nil }

        let result = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: clamped))
        var changed = false
        changed = removeMarkedCharacters(in: result) || changed
        changed = QuoteBarCopy.restoreQuoteBars(in: result) || changed
        changed = rewriteAttachments(in: result) || changed
        changed = rebuildTables(in: result) || changed
        stripInternalAttributes(in: result)
        return changed ? result : nil
    }

    // MARK: - 1) 删除隐藏 / 跳过标记

    /// 删除所有带 `.markableHidden` / `.markableCopySkip` 的字符；返回是否有删除。
    ///
    /// **整行隐藏**（front matter、引用式链接定义行、代码围栏行、独占一行的注释…）连同
    /// 行尾换行一起删——只删字符会把整行留成空行。判定条件是「行内非换行字符要么隐藏、
    /// 要么只是空白 / 引用竖线前缀」，且**至少有一个真正隐藏的字符**：代码块里的纯空行、
    /// 引用块里的空行没有隐藏字符，因此不会被压缩。
    ///
    /// 删除隐藏行后，**只吸收紧邻这些行的连续空行**（最多留 1 个），不做全局 `\n{3,}`
    /// 替换——代码块内的空行（可见内容）永远不会被碰到。
    static func removeMarkedCharacters(in text: NSMutableAttributedString) -> Bool {
        let full = NSRange(location: 0, length: text.length)
        guard full.length > 0 else { return false }

        var hidden = [Bool](repeating: false, count: text.length)
        var prefix = [Bool](repeating: false, count: text.length)
        var ranges: [NSRange] = []
        text.enumerateAttribute(.markableHidden, in: full, options: []) { value, range, _ in
            guard (value as? Bool) == true else { return }
            ranges.append(range)
            for index in range.location..<(range.location + range.length) where index < hidden.count {
                hidden[index] = true
            }
        }
        text.enumerateAttribute(.markableQuoteBar, in: full, options: []) { value, range, _ in
            guard (value as? Bool) == true else { return }
            for index in range.location..<(range.location + range.length) where index < prefix.count {
                prefix[index] = true
            }
        }
        text.enumerateAttribute(.markableCopySkip, in: full, options: []) { value, range, _ in
            guard (value as? Bool) == true else { return }
            ranges.append(range)
        }
        guard !ranges.isEmpty else { return false }

        let hiddenLines = fullyHiddenLines(in: text, hidden: hidden, prefix: prefix)
        let absorbed = blankLinesToAbsorb(around: hiddenLines, in: text)

        let all = ranges + hiddenLines + absorbed
        // 选区开头被删掉（front matter / 文档开头的定义行）时，结果里残留的前导空行要清掉。
        let deletedFromStart = all.contains { $0.length > 0 && $0.location == 0 }
        for range in merged(all).reversed() where range.location + range.length <= text.length {
            text.deleteCharacters(in: range)
        }
        if deletedFromStart {
            trimLeadingBlankLines(in: text)
        }
        return true
    }

    /// 紧邻隐藏行的连续空行，吸收到「隐藏行位置最多留 1 个空行」为止。
    ///
    /// 例：`正文A\n\n[ref]: url\n\n\n正文B` → 删除定义行后前后空行相邻，只保留 1 个。
    /// 代码块围栏行前后不是空行，因此代码块内的空行、代码块后的段落空行都不受影响。
    private static func blankLinesToAbsorb(around hiddenLines: [NSRange], in text: NSAttributedString) -> [NSRange] {
        guard !hiddenLines.isEmpty else { return [] }
        var absorbed: [NSRange] = []
        for block in mergedLines(hiddenLines) {
            var before: [NSRange] = []
            var cursor = block.location
            while let previous = previousLineRange(before: cursor, in: text), isBlankLine(previous, in: text) {
                before.append(previous)
                cursor = previous.location
                if previous.location == 0 { break }
            }
            var after: [NSRange] = []
            var end = block.location + block.length
            while let next = nextLineRange(after: end, in: text), isBlankLine(next, in: text) {
                after.append(next)
                end = next.location + next.length
            }
            let total = before.count + after.count
            // 只有隐藏行**前面也有空行**（夹在空行之间）时才压缩后随空行；
            // 代码块围栏行前面是代码内容，因此「代码块后的段落空行」不会被吞。
            guard before.count >= 1, total >= 2 else { continue }
            var remaining = total - 1
            for range in after where remaining > 0 {
                absorbed.append(range)
                remaining -= 1
            }
            for range in before where remaining > 0 {
                absorbed.append(range)
                remaining -= 1
            }
        }
        return absorbed
    }

    /// 合并相邻或相接的行区间（连续多行隐藏视为一个块，空行只吸收一次）。
    private static func mergedLines(_ lines: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for line in lines.sorted(by: { $0.location < $1.location }) {
            if let last = result.last, last.location + last.length >= line.location {
                let end = max(last.location + last.length, line.location + line.length)
                result[result.count - 1] = NSRange(location: last.location, length: end - last.location)
            } else {
                result.append(line)
            }
        }
        return result
    }

    /// 合并重叠或相邻的区间，避免同一段字符被删两次。
    private static func merged(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.sorted { $0.location < $1.location }
        var result: [NSRange] = []
        for range in sorted {
            if let last = result.last, last.location + last.length >= range.location {
                let end = max(last.location + last.length, range.location + range.length)
                result[result.count - 1] = NSRange(location: last.location, length: end - last.location)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// 整行都是隐藏字符（允许行内空白与引用竖线前缀）的行范围；纯空行 / 空引用行不算。
    ///
    /// 引用竖线前缀之所以可以忽略：引用块内的代码围栏行渲染成 `│ ``` `，
    /// 围栏隐藏后整行只剩前缀，若不连前缀一起删，前缀会粘到下一行（`> > let a = 1`）。
    /// 「至少有一个真正隐藏的字符」保证 `>` 单独一行（空引用行）不会被误删。
    private static func fullyHiddenLines(
        in text: NSAttributedString,
        hidden: [Bool],
        prefix: [Bool]
    ) -> [NSRange] {
        let ns = text.string as NSString
        var result: [NSRange] = []
        var index = 0
        while index < ns.length {
            let line = ns.lineRange(for: NSRange(location: index, length: 0))
            var hasHidden = false
            var fullyCovered = true
            var position = line.location
            let end = line.location + line.length
            while position < end {
                let character = ns.character(at: position)
                if character == 0x0A || character == 0x0D || character == lineSeparator {
                    position += 1
                    continue
                }
                if hidden[position] {
                    hasHidden = true
                } else if character == 0x20 || character == 0x09 {
                    // 空白：允许（缩进 / 前缀后的空格）
                } else if prefix[position] {
                    // 引用竖线前缀：允许（整行随隐藏字符一起删）
                } else {
                    fullyCovered = false
                    break
                }
                position += 1
            }
            if fullyCovered && hasHidden {
                result.append(line)
            }
            index = end
            if line.length == 0 { break }
        }
        return result
    }

    /// `location` 之前那一行的范围（没有上一行时返回 nil）。
    private static func previousLineRange(before location: Int, in text: NSAttributedString) -> NSRange? {
        guard location > 0, location <= text.length else { return nil }
        return (text.string as NSString).lineRange(for: NSRange(location: location - 1, length: 0))
    }

    /// `location` 开始的那一行范围（没有下一行时返回 nil）。
    private static func nextLineRange(after location: Int, in text: NSAttributedString) -> NSRange? {
        guard location >= 0, location < text.length else { return nil }
        return (text.string as NSString).lineRange(for: NSRange(location: location, length: 0))
    }

    /// 该行是否只有空白（空格 / Tab / 换行）。
    private static func isBlankLine(_ range: NSRange?, in text: NSAttributedString) -> Bool {
        guard let range, range.location >= 0, range.length > 0,
              range.location + range.length <= text.length else { return false }
        let ns = text.string as NSString
        for index in range.location..<(range.location + range.length) {
            let character = ns.character(at: index)
            let isBlank = character == 0x0A || character == 0x0D
                || character == 0x20 || character == 0x09 || character == lineSeparator
            if !isBlank { return false }
        }
        return true
    }

    /// 去掉结果开头的空行（只在选区开头的内容被整段删除后调用）。
    private static func trimLeadingBlankLines(in text: NSMutableAttributedString) {
        let ns = text.string as NSString
        var end = 0
        while end < ns.length {
            let character = ns.character(at: end)
            guard character == 0x0A || character == 0x0D
                || character == 0x20 || character == 0x09 else { break }
            end += 1
        }
        if end > 0 {
            text.deleteCharacters(in: NSRange(location: 0, length: end))
        }
    }

    // MARK: - 3) 附件占位符

    /// 附件字符（U+FFFC）的复制处理：
    /// - 图片 → `[图片: alt]` / `[图片]`；
    /// - Mermaid → `[Mermaid: 源码首行（截断）]`，无源码时 `[Mermaid 图]`；
    /// - 数学 → `[公式]`（异步渲染中的占位文字同样按这个处理）；
    /// - 其余附件（复选框、竖线附件…）→ 删除，保证剪贴板里没有 U+FFFC 方框。
    static func rewriteAttachments(in text: NSMutableAttributedString) -> Bool {
        var changed = false

        // 3.1 图片：附件字符换成 alt 占位文本。
        var imageEdits: [(range: NSRange, label: String)] = []
        text.enumerateAttribute(.markableImageAlt, in: NSRange(location: 0, length: text.length),
                                options: []) { value, range, _ in
            guard let alt = value as? String else { return }
            imageEdits.append((range, imageLabel(for: alt)))
        }
        for edit in imageEdits.sorted(by: { $0.range.location > $1.range.location }) {
            guard edit.range.location + edit.range.length <= text.length else { continue }
            replaceAttachment(range: edit.range, with: edit.label, in: text)
            changed = true
        }

        // 3.2 Mermaid / 数学：换成可读占位（位置在图片替换后重新枚举，偏移已变化）。
        var semanticEdits: [(range: NSRange, label: String)] = []
        text.enumerateAttribute(.markableAttachmentKind, in: NSRange(location: 0, length: text.length),
                                options: []) { value, range, _ in
            guard let kind = value as? String else { return }
            let source = text.attribute(.markableAttachmentSource, at: range.location,
                                        effectiveRange: nil) as? String ?? ""
            semanticEdits.append((range, attachmentLabel(kind: kind, source: source)))
        }
        for edit in semanticEdits.sorted(by: { $0.range.location > $1.range.location }) {
            guard edit.range.location + edit.range.length <= text.length else { continue }
            replaceAttachment(range: edit.range, with: edit.label, in: text)
            changed = true
        }

        // 3.3 剩余附件字符：从后往前逐个删除（复选框、竖线附件、未知附件…）。
        let ns = text.string as NSString
        var attachmentLocations: [Int] = []
        for index in 0..<ns.length where ns.character(at: index) == attachmentCharacter {
            attachmentLocations.append(index)
        }
        for location in attachmentLocations.reversed() {
            text.deleteCharacters(in: NSRange(location: location, length: 1))
            changed = true
        }
        return changed
    }

    /// 把一段附件字符换成占位文本，并清掉继承下来的附件 / 语义属性（否则文字会被当成附件）。
    private static func replaceAttachment(range: NSRange, with label: String,
                                         in text: NSMutableAttributedString) {
        text.replaceCharacters(in: range, with: label)
        let replaced = NSRange(location: range.location, length: (label as NSString).length)
        guard replaced.length > 0 else { return }
        text.removeAttribute(.attachment, range: replaced)
        text.removeAttribute(.markableImageAlt, range: replaced)
        text.removeAttribute(.markableAttachmentKind, range: replaced)
        text.removeAttribute(.markableAttachmentSource, range: replaced)
    }

    /// 图片占位文本：`[图片: 示意图]`；alt 为空（或只有空白）时退化成 `[图片]`。
    static func imageLabel(for alt: String) -> String {
        let trimmed = alt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "[图片]" : "[图片: \(trimmed)]"
    }

    /// 语义附件（Mermaid / 数学）的占位文本。
    static func attachmentLabel(kind: String, source: String = "") -> String {
        switch kind {
        case "mermaid":
            let summary = mermaidSummary(from: source)
            return summary.isEmpty ? "[Mermaid 图]" : "[Mermaid: \(summary)]"
        case "math":
            return "[公式]"
        default:
            return ""
        }
    }

    /// Mermaid 源码摘要：取前 3 个非空行、用 ` / ` 连接、压缩空白，总长最多 80 个字符
    /// （超出截断并以 `…` 结尾）。
    private static func mermaidSummary(from source: String) -> String {
        var lines: [String] = []
        for line in source.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let collapsed = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .joined(separator: " ")
            lines.append(collapsed)
            if lines.count == 3 { break }
        }
        guard !lines.isEmpty else { return "" }
        let joined = lines.joined(separator: " / ")
        let limit = 80
        if joined.count <= limit { return joined }
        return String(joined.prefix(limit - 1)) + "…"
    }

    // MARK: - 4) 表格 → TSV

    /// 表格单元格：位置 + 所属表格 + 行列号。
    private struct CellRef {
        var range: NSRange
        var table: Int
        var row: Int
        var column: Int
    }

    /// 组装单元的两种形态：普通文本、已重排好的表格 TSV。
    private enum Chunk {
        case text(NSAttributedString)
        case table(NSAttributedString)
    }

    /// 若选区含表格单元格，把整段选区重排：单元格之间 `\t`、行之间 `\n`，
    /// 表格与相邻正文之间留一个空行；返回是否重排过。
    static func rebuildTables(in text: NSMutableAttributedString) -> Bool {
        let full = NSRange(location: 0, length: text.length)
        guard full.length > 0 else { return false }

        var cells: [CellRef] = []
        text.enumerateAttribute(.markableTableCell, in: full, options: []) { value, range, _ in
            guard let raw = value as? String, let parsed = parseCell(raw) else { return }
            cells.append(CellRef(range: range, table: parsed.table, row: parsed.row, column: parsed.column))
        }
        guard !cells.isEmpty else { return false }

        var chunks: [Chunk] = []
        var cursor = 0
        var index = 0
        while index < cells.count {
            let first = cells[index]
            if first.range.location > cursor {
                chunks.append(.text(text.attributedSubstring(
                    from: NSRange(location: cursor, length: first.range.location - cursor))))
            }
            // 同一表格的单元格在文本里是连续的；遇到下一个表格就断开成新的 TSV 块。
            var group: [CellRef] = []
            var next = index
            while next < cells.count, cells[next].table == first.table {
                group.append(cells[next])
                next += 1
            }
            chunks.append(.table(makeTSV(group, in: text)))
            cursor = group[group.count - 1].range.location + group[group.count - 1].range.length
            index = next
        }
        if cursor < text.length {
            chunks.append(.text(text.attributedSubstring(
                from: NSRange(location: cursor, length: text.length - cursor))))
        }

        text.setAttributedString(assemble(chunks))
        return true
    }

    /// `"表序,行,列"` → 三元组。
    private static func parseCell(_ raw: String) -> (table: Int, row: Int, column: Int)? {
        let parts = raw.split(separator: ",").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    /// 把一个表格里**选区实际覆盖到的**单元格拼成 TSV：
    /// 同一行的单元格用 `\t` 连接，行之间用 `\n`；未被覆盖的行列不输出。
    private static func makeTSV(_ cells: [CellRef], in text: NSMutableAttributedString) -> NSAttributedString {
        var rows: [Int: [(column: Int, content: NSAttributedString)]] = [:]
        for cell in cells {
            guard cell.range.location + cell.range.length <= text.length else { continue }
            let content = sanitizedCell(text.attributedSubstring(from: cell.range))
            rows[cell.row, default: []].append((cell.column, content))
        }

        let result = NSMutableAttributedString()
        for (rowIndex, row) in rows.keys.sorted().enumerated() {
            if rowIndex > 0 {
                result.append(NSAttributedString(string: "\n", attributes: plainAttributes))
            }
            let columns = rows[row] ?? []
            for (cellIndex, cell) in columns.sorted(by: { $0.column < $1.column }).enumerated() {
                if cellIndex > 0 {
                    result.append(NSAttributedString(string: "\t", attributes: plainAttributes))
                }
                result.append(cell.content)
            }
        }
        // 单元格自带 NSTextTableBlock 段落样式：不清掉的话 RTF 里又变回表格，
        // 粘贴到 Excel/Numbers 就不会按 TSV 拆列。
        if result.length > 0 {
            result.addAttribute(.paragraphStyle, value: NSMutableParagraphStyle(),
                                range: NSRange(location: 0, length: result.length))
        }
        return result
    }

    /// 单元格内容清洗：去掉布局用的尾部换行，单元格内的换行（U+2028 / `\n`）折成空格，
    /// 避免破坏 TSV 的行列结构。
    private static func sanitizedCell(_ text: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: text)
        while mutable.length > 0 {
            let last = (mutable.string as NSString).character(at: mutable.length - 1)
            guard last == 0x0A || last == 0x0D else { break }
            mutable.deleteCharacters(in: NSRange(location: mutable.length - 1, length: 1))
        }
        if mutable.length > 0 {
            let ns = mutable.string as NSString
            for index in stride(from: mutable.length - 1, through: 0, by: -1) {
                let character = ns.character(at: index)
                if character == 0x0A || character == 0x0D || character == lineSeparator {
                    mutable.replaceCharacters(in: NSRange(location: index, length: 1), with: " ")
                }
            }
        }
        return mutable
    }

    /// 组装输出：表格块与相邻正文之间补一个空行，表格块本身不额外带前导 / 尾随空行
    /// （这样「全选只有表格」复制出来正好是 `A\tB\n1\t2`，粘到表格软件不会多空行）。
    private static func assemble(_ chunks: [Chunk]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        var pending: [NSAttributedString] = []   // 表格之后的纯空白段，延后决定去留
        var afterTable = false

        for chunk in chunks {
            switch chunk {
            case .text(let text):
                if afterTable {
                    if isWhitespaceOnly(text) {
                        pending.append(text)
                        continue
                    }
                    flushPending(pending, into: output)
                    pending = []
                    appendBlankLineIfNeeded(to: output, body: text)
                    output.append(text)
                    afterTable = false
                } else {
                    output.append(text)
                }
            case .table(let tsv):
                // 表格之间、或正文之后：确保前面隔着一个空行（选区开头不补）。
                pending = []
                appendBlankLineIfNeeded(to: output, body: tsv)
                output.append(tsv)
                afterTable = true
            }
        }
        // 收尾：表格后暂存的纯空白（选区以表格 / 表格后的空行结束）直接丢弃——
        // 表格块本身不带尾随空行，粘到 Excel/Numbers 不会多出一行空行。
        return output
    }

    /// 把表格后暂存的空白写回输出，再由 `appendBlankLineIfNeeded` 补足空行。
    private static func flushPending(_ pending: [NSAttributedString], into output: NSMutableAttributedString) {
        for item in pending {
            output.append(item)
        }
    }

    /// 输出末尾与 `body` 之间补到**一个空行**（两个换行）；`body` 开头的换行也会计入。
    private static func appendBlankLineIfNeeded(to output: NSMutableAttributedString, body: NSAttributedString) {
        guard output.length > 0 else { return }
        let leading = leadingNewlineCount(in: body.string)
        let trailing = trailingNewlineCount(in: output.string)
        let total = trailing + leading
        if total < 2 {
            output.append(NSAttributedString(string: String(repeating: "\n", count: 2 - total),
                                            attributes: plainAttributes))
        }
    }

    private static func isWhitespaceOnly(_ text: NSAttributedString) -> Bool {
        text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func trailingNewlineCount(in string: String) -> Int {
        var count = 0
        for character in string.reversed() {
            if character == "\n" { count += 1 } else { break }
        }
        return count
    }

    private static func leadingNewlineCount(in string: String) -> Int {
        var count = 0
        for character in string {
            if character == "\n" { count += 1 } else { break }
        }
        return count
    }

    // MARK: - 收尾

    /// 移除内部标记属性；RTF 只保留字体/颜色/段落样式这些标准属性。
    private static func stripInternalAttributes(in text: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: text.length)
        guard full.length > 0 else { return }
        for key in internalKeys {
            text.removeAttribute(key, range: full)
        }
    }
}
