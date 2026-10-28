import AppKit

extension NSAttributedString.Key {
    /// 渲染阶段插入的引用块竖线标记（值 `true`）。
    ///
    /// 引用块行首的 `>` 在渲染时被**原地替换**成 `│`
    /// （见 `LivePreviewController`），复制时据此把这些竖线还原成源码里的 `>`。
    /// 用户正文里原生的 `│` 不带此标记，复制时保持原样。
    static let markableQuoteBar = NSAttributedString.Key("markable.quoteBar")
    /// 竖线对应的**原始行首前缀**（值 `String`，如 `"> > "`）。
    ///
    /// 嵌套引用（`> > 内层`）渲染时只画一条竖线，复制时若只还原一个 `>`
    /// 就会丢掉层级。渲染时把完整前缀记在这里，复制时整段还原。
    static let markableQuoteSourcePrefix = NSAttributedString.Key("markable.quoteSourcePrefix")
}

/// 引用块竖线的复制还原：渲染层与文本视图共享同一套标记逻辑。
///
/// 只处理**带 `.markableQuoteBar` 标记**的 `│`，不按字符硬替换，避免污染正文里
/// 用户自己写的 `│`。还原结果同时写纯文本与 RTF，粘贴到富文本应用也不会带回竖线。
///
/// 完整的复制管线（隐藏标记 → 竖线还原 → 附件占位符 → 表格 TSV）在 `CopyFormatted` 里；
/// 本类型只负责其中的竖线还原与剪贴板写入。
enum QuoteBarCopy {
    /// 渲染时用来代替 `>` 的竖线字符（U+2502）。
    private static let renderedBar: unichar = 0x2502
    /// 还原后的 Markdown 引用标记。
    private static let markdownMarker = ">"

    /// 系统复制经 AppKit 传下来的旧式类型名；现代应用则请求 `public.*`。
    private static let legacyStringType = NSPasteboard.PasteboardType("NSStringPboardType")
    private static let legacyRTFType =
        NSPasteboard.PasteboardType("NeXT Rich Text Format v1.0 pasteboard type")
    /// 两套类型名都写：不同粘贴目标取的 flavor 不同，漏写一侧会重新看到 `│`。
    private static let plainTextTypes: [NSPasteboard.PasteboardType] = [
        .string, legacyStringType,
    ]
    private static let richTextTypes: [NSPasteboard.PasteboardType] = [
        .rtf, legacyRTFType,
    ]

    /// 把文本里**带标记**的渲染竖线还原成源码前缀；返回是否发生了替换。
    ///
    /// 普通引用还原成 `>`（等长）；带 `.markableQuoteSourcePrefix` 的嵌套引用还原成完整
    /// 前缀（如 `> > `，**变长**）。因此从后往前替换，偏移不受影响；属性由被替换区间继承
    /// （字体/颜色/段落样式不变）。
    static func restoreQuoteBars(in text: NSMutableAttributedString) -> Bool {
        let full = NSRange(location: 0, length: text.length)
        guard full.length > 0 else { return false }
        let ns = text.string as NSString
        var edits: [(range: NSRange, replacement: String)] = []
        text.enumerateAttribute(.markableQuoteBar, in: full, options: []) { value, range, _ in
            guard (value as? Bool) == true else { return }
            for index in range.location..<(range.location + range.length)
            where index < ns.length && ns.character(at: index) == renderedBar {
                let prefix = text.attribute(.markableQuoteSourcePrefix, at: index,
                                            effectiveRange: nil) as? String
                if let prefix, !prefix.isEmpty, prefix.hasPrefix(markdownMarker) {
                    // 渲染时把第一层前缀换成了「│ + 同样数量的空格」，其余层的 `>` 作为
                    // 隐藏标记已被删除；这里把「│ + 其后连续空格」换回原始前缀。
                    var length = 1
                    while length < prefix.count,
                          index + length < ns.length,
                          ns.character(at: index + length) == 0x20 {
                        length += 1
                    }
                    // 选区截断时（只选中 `│`，后面的空格没选）只还原 `>`，
                    // 否则部分选区会凭空带出选区外的前缀。
                    let truncated = length == 1 && prefix.count > 1 && prefix.hasPrefix("> ")
                    let replacement = truncated ? markdownMarker : prefix
                    edits.append((NSRange(location: index, length: length), replacement))
                } else {
                    edits.append((NSRange(location: index, length: 1), markdownMarker))
                }
            }
        }
        guard !edits.isEmpty else { return false }
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            guard edit.range.location + edit.range.length <= text.length else { continue }
            text.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return true
    }

    /// 把净化后的选区写进剪贴板：纯文本与 RTF 内容一致，均为 `>`。
    /// 返回是否成功写入纯文本。
    @discardableResult
    static func write(_ attributed: NSAttributedString, to pasteboard: NSPasteboard) -> Bool {
        let range = NSRange(location: 0, length: attributed.length)
        let rtf = attributed.rtf(from: range, documentAttributes: [:])
        let plain = attributed.string

        pasteboard.clearContents()
        pasteboard.declareTypes(rtf == nil ? plainTextTypes : plainTextTypes + richTextTypes, owner: nil)
        guard pasteboard.setString(plain, forType: .string) else { return false }
        _ = pasteboard.setString(plain, forType: legacyStringType)
        if let rtf {
            _ = pasteboard.setData(rtf, forType: .rtf)
            _ = pasteboard.setData(rtf, forType: legacyRTFType)
        }
        return true
    }
}
