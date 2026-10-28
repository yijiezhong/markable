import AppKit
import Testing
@testable import Markable

/// 引用内的围栏代码块（`> ``` ` … `> ``` `）。
///
/// 顶层围栏扫描只看行首，这类行过去被当作引用正文把 ``` 显示出来。
/// 现在剥离引用前缀后识别围栏：围栏字符隐藏（0.1pt + 透明），内容按等宽 + 灰底渲染，
/// 引用竖线与整块灰底保留。
///
/// 注意：基准排版用 `.system` 字体族——`Typography()` 默认族是 `.mono`，正文本身就是等宽，
/// 那样无法区分「正文」与「代码字体」。
@MainActor
@Suite("QuotedFence")
struct QuotedFenceTests {
    private func render(_ source: String, width: CGFloat = 760) -> NSTextStorage {
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        LivePreviewController().apply(to: textView, source: source, baseDirectory: nil,
                                      readOnly: true, fontSize: 14,
                                      typography: Typography(family: .system))
        return textView.textStorage!
    }

    private func font(in storage: NSTextStorage, at location: Int) -> NSFont? {
        storage.attributes(at: location, effectiveRange: nil)[.font] as? NSFont
    }

    private func isCodeFont(_ font: NSFont?) -> Bool {
        // 代码字体是 Noto Sans Mono CJK SC（或回退的系统等宽），系统正文字体不含 "Mono"。
        font?.fontName.contains("Mono") == true
    }

    @Test("围栏隐藏、内容等宽、竖线保留")
    func quotedFenceRendersAsCode() {
        let storage = render("> ```\n> let value = 1\n> ```\n")
        let ns = storage.string as NSString

        let fence = ns.range(of: "```")
        #expect(fence.location != NSNotFound, "围栏字符应仍在文本中（隐藏而非删除）")
        if fence.location != NSNotFound {
            #expect((font(in: storage, at: fence.location)?.pointSize ?? 99) < 1,
                    "围栏应隐藏（0.1pt），实际 \(font(in: storage, at: fence.location)?.pointSize ?? -1)")
        }

        let code = ns.range(of: "let value = 1")
        #expect(code.location != NSNotFound)
        if code.location != NSNotFound {
            #expect(isCodeFont(font(in: storage, at: code.location)),
                    "代码内容应为等宽字体，实际 \(font(in: storage, at: code.location)?.fontName ?? "nil")")
            #expect(storage.attributes(at: code.location, effectiveRange: nil)[.backgroundColor] != nil,
                    "代码内容应有灰底")
        }

        #expect(storage.string.filter { $0 == "│" }.count == 3,
                "三行引用应各有竖线，实际 \(storage.string.filter { $0 == "│" }.count)")
    }

    @Test("围栏带语言标识同样识别")
    func quotedFenceWithLanguage() {
        let storage = render("> ```swift\n> let a = 1\n> ```\n")
        let ns = storage.string as NSString
        let code = ns.range(of: "let a = 1")
        #expect(code.location != NSNotFound)
        if code.location != NSNotFound {
            #expect(isCodeFont(font(in: storage, at: code.location)))
        }
        let fence = ns.range(of: "```swift")
        if fence.location != NSNotFound {
            #expect((font(in: storage, at: fence.location)?.pointSize ?? 99) < 1)
        }
    }

    @Test("未闭合的围栏保持原样，不吞正文")
    func unclosedFenceStaysLiteral() {
        let storage = render("> ```\n> 正文不应变成代码\n")
        let ns = storage.string as NSString
        let fence = ns.range(of: "```")
        #expect(fence.location != NSNotFound)
        if fence.location != NSNotFound {
            #expect((font(in: storage, at: fence.location)?.pointSize ?? 0) > 1,
                    "未闭合围栏不应被识别为代码块")
        }
        let body = ns.range(of: "正文不应变成代码")
        #expect(body.location != NSNotFound)
        if body.location != NSNotFound {
            let bodyFont = font(in: storage, at: body.location)
            #expect(!isCodeFont(bodyFont),
                    "正文不应被套上代码字体（实际 \(bodyFont?.fontName ?? "nil")）")
        }
    }

    @Test("顶层代码块里的 > ``` 不被误判为引用围栏")
    func fenceInsideTopLevelCodeIsIgnored() {
        let storage = render("```\n> ```\n```\n")
        let ns = storage.string as NSString
        let inner = ns.range(of: "> ```")
        #expect(inner.location != NSNotFound)
        if inner.location != NSNotFound {
            // `> ` 前缀由 blockquote 隐藏（0.1pt）；它后面的 ``` 是代码内容，应正常显示。
            let fenceStart = inner.location + 2
            #expect(fenceStart < ns.length)
            if fenceStart < ns.length {
                let innerFont = font(in: storage, at: fenceStart)
                #expect((innerFont?.pointSize ?? 0) > 1,
                        "代码块内的 ``` 不应被隐藏（实际 \(innerFont?.pointSize ?? -1)）")
                #expect(isCodeFont(innerFont),
                        "应保持顶层代码块的等宽字体（实际 \(innerFont?.fontName ?? "nil")）")
            }
        }
    }

    @Test("嵌套引用里的围栏同样识别（多层前缀一起剥离）")
    func nestedQuotedFence() {
        let storage = render("> > ```\n> > let x = 1\n> > ```\n")
        let ns = storage.string as NSString

        let code = ns.range(of: "let x = 1")
        #expect(code.location != NSNotFound)
        if code.location != NSNotFound {
            #expect(isCodeFont(font(in: storage, at: code.location)),
                    "嵌套引用内的代码应为等宽，实际 \(font(in: storage, at: code.location)?.fontName ?? "nil")")
        }
        let fence = ns.range(of: "```")
        if fence.location != NSNotFound {
            #expect((font(in: storage, at: fence.location)?.pointSize ?? 99) < 1,
                    "围栏应隐藏，实际 \(font(in: storage, at: fence.location)?.pointSize ?? -1)")
        }
        #expect(storage.string.filter { $0 == "│" }.count == 3,
                "三行嵌套引用应各有竖线，实际 \(storage.string.filter { $0 == "│" }.count)")
    }
}
