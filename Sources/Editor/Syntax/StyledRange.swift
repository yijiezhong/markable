import Foundation

/// Markdown 语义片段类型（用于渲染与 live-preview 决策）。
enum MarkdownTokenKind: Equatable {
    case heading(Int)
    case bold
    case italic
    case code
    case link
    case blockquote
    case listItem
    case taskList
    case codeBlock
    case table
    case frontMatter
    case footnote
    case image
    case highlight
    case strikethrough
    case comment
    case footnoteRef
    case linkRef
    case callout
    case aiMark
    case subscriptText
    case superscriptText
    case underlineText
}

/// 一段带语义的文本范围（NSRange 基于 UTF-16，可直接作用于 NSTextStorage/NSString）。
///
/// - `range`：包含语法标记的完整范围（如 `**粗**`）；
/// - `content`：**内容**范围（如 `粗`），渲染时只显示它、隐藏标记；
/// - `payload`：附加信息（例如图片路径）。
struct StyledRange: Equatable {
    var range: NSRange
    var kind: MarkdownTokenKind
    var content: NSRange
    var payload: String? = nil

    init(range: NSRange, kind: MarkdownTokenKind, content: NSRange? = nil, payload: String? = nil) {
        self.range = range
        self.kind = kind
        self.content = content ?? range
        self.payload = payload
    }
}
