import AppKit

/// 代码块语法高亮（阅读器侧）：移植 movable `Markdown/CodeHighlighter.swift` 的五类 token
/// （注释 / 字符串 / 数字 / 关键字 / 类型名）+ 十来个语言共用一套扫描器。
///
/// 与 movable 的差异：这里**不输出 HTML**，而是输出**基于 UTF-16 的 `NSRange`**，
/// 直接作用于 Markable 的 `NSTextStorage`（在 `LivePreviewController` 里上色）。
/// 未识别的语言返回空数组（不高亮、也不假装高亮）。
enum CodeHighlighter {
    enum TokenClass {
        case comment, string, number, keyword, type
    }

    struct Token {
        var range: NSRange
        var cls: TokenClass
    }

    /// 语言配置：注释前缀、块注释定界、字符串引号（UTF-16 码元）、词表。
    private struct Lang {
        var lineComments: [String] = ["//"]
        var blockComments: [(String, String)] = [("/*", "*/")]
        var quoteCodes: [UInt16] = [34, 39]        // " '
        var keywords: Set<String> = []
        var types: Set<String> = []
        var caseSensitive = true
        var allowsBacktick = false                 // JS/TS 模板串
        var hashComment = false                    // Python/Shell 的 #
    }

    // MARK: - 入口

    /// 代码 → token 区间列表（区间相对 `code` 起点，调用方加上内容起点偏移）。
    static func tokens(in code: String, language: String) -> [Token] {
        let name = language.lowercased()
        if ["html", "xml", "svg", "vue"].contains(name) { return markupTokens(code) }
        guard !name.isEmpty, let cfg = config(for: name) else { return [] }
        return scan(code, cfg)
    }

    /// 该语言是否有分词规则（供文档体检等）。空语言不算问题：本就不高亮。
    static func isKnown(_ lang: String) -> Bool {
        let name = lang.lowercased()
        if name.isEmpty { return true }
        if ["html", "xml", "svg", "vue"].contains(name) { return true }
        return config(for: name) != nil
    }

    /// token 配色（向只读路径的 solarized 靠拢，浅/深色自适应）。
    static func color(for cls: TokenClass) -> NSColor {
        switch cls {
        case .comment: return dynamic(light: 0x93A1A1, dark: 0x586E75)
        case .string:  return dynamic(light: 0x2AA198, dark: 0x2AA198)
        case .number:  return dynamic(light: 0xD33682, dark: 0xD33682)
        case .keyword: return dynamic(light: 0x859900, dark: 0xB58900)
        case .type:    return dynamic(light: 0x268BD2, dark: 0x6C71C4)
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        let l = NSColor(hex: light), d = NSColor(hex: dark)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l
        }
    }

    // MARK: - 词表

    private static func config(for name: String) -> Lang? {
        switch name.lowercased() {
        case "python", "py":
            var l = Lang(lineComments: [], blockComments: [], quoteCodes: [34, 39], hashComment: true)
            l.keywords = ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not",
                          "and", "or", "import", "from", "as", "with", "try", "except", "finally",
                          "raise", "yield", "lambda", "pass", "break", "continue", "global", "None",
                          "True", "False", "async", "await", "assert", "del", "is"]
            l.types = ["int", "float", "str", "bool", "list", "dict", "set", "tuple", "bytes", "self"]
            return l
        case "javascript", "js", "typescript", "ts", "jsx", "tsx":
            var l = Lang()
            l.allowsBacktick = true
            l.keywords = ["const", "let", "var", "function", "return", "if", "else", "for", "while",
                          "class", "new", "import", "from", "export", "default", "try", "catch",
                          "finally", "throw", "async", "await", "yield", "typeof", "instanceof",
                          "null", "undefined", "true", "false", "this", "super", "extends", "interface",
                          "type", "enum", "implements", "public", "private", "readonly", "as", "in", "of"]
            l.types = ["string", "number", "boolean", "any", "void", "Promise", "Array", "Object", "Map", "Set"]
            return l
        case "swift":
            var l = Lang()
            l.keywords = ["func", "let", "var", "return", "if", "else", "guard", "for", "while", "in",
                          "class", "struct", "enum", "protocol", "extension", "import", "init", "self",
                          "nil", "true", "false", "try", "catch", "throw", "throws", "async", "await",
                          "public", "private", "internal", "fileprivate", "static", "mutating", "where",
                          "switch", "case", "default", "break", "continue", "defer", "final", "lazy",
                          "weak", "unowned", "some", "any", "typealias", "associatedtype", "override"]
            l.types = ["Int", "Double", "Float", "String", "Bool", "Array", "Dictionary", "Set", "Optional",
                       "Void", "Any", "AnyObject", "URL", "Data", "Result", "Error"]
            return l
        case "rust", "rs":
            var l = Lang()
            l.keywords = ["fn", "let", "mut", "return", "if", "else", "for", "while", "loop", "match",
                          "struct", "enum", "trait", "impl", "use", "mod", "pub", "crate", "self", "super",
                          "as", "in", "ref", "move", "async", "await", "where", "dyn", "static", "const",
                          "unsafe", "true", "false", "break", "continue"]
            l.types = ["i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "usize", "isize",
                       "f32", "f64", "bool", "char", "str", "String", "Vec", "Option", "Result", "Box"]
            return l
        case "go", "golang":
            var l = Lang()
            l.keywords = ["func", "var", "const", "type", "struct", "interface", "return", "if", "else",
                          "for", "range", "switch", "case", "default", "go", "defer", "chan", "select",
                          "package", "import", "map", "nil", "true", "false", "break", "continue", "fallthrough"]
            l.types = ["int", "int64", "float64", "string", "bool", "byte", "rune", "error", "any"]
            return l
        case "java", "kotlin", "kt":
            var l = Lang()
            l.keywords = ["public", "private", "protected", "class", "interface", "enum", "extends",
                          "implements", "static", "final", "void", "return", "if", "else", "for", "while",
                          "new", "import", "package", "try", "catch", "finally", "throw", "throws",
                          "null", "true", "false", "this", "super", "fun", "val", "var", "when", "object"]
            l.types = ["int", "long", "double", "float", "boolean", "char", "String", "List", "Map", "Integer"]
            return l
        case "c", "cpp", "c++", "objc", "objective-c":
            var l = Lang()
            l.keywords = ["int", "char", "float", "double", "void", "long", "short", "unsigned", "signed",
                          "struct", "union", "enum", "typedef", "static", "const", "return", "if", "else",
                          "for", "while", "do", "switch", "case", "default", "break", "continue", "sizeof",
                          "class", "public", "private", "protected", "template", "typename", "namespace",
                          "using", "new", "delete", "try", "catch", "throw", "nullptr", "true", "false",
                          "auto", "std", "include", "define", "ifdef", "ifndef", "endif"]
            return l
        case "sql":
            var l = Lang(lineComments: ["--"], blockComments: [("/*", "*/")], quoteCodes: [39, 34])
            l.keywords = ["select", "from", "where", "insert", "into", "values", "update", "set", "delete",
                          "create", "table", "index", "view", "drop", "alter", "join", "left", "right",
                          "inner", "outer", "on", "group", "by", "order", "having", "limit", "offset",
                          "and", "or", "not", "null", "as", "distinct", "count", "sum", "avg", "min", "max",
                          "case", "when", "then", "else", "end", "union", "all", "exists", "in", "like"]
            l.types = ["int", "integer", "text", "varchar", "timestamp", "boolean", "numeric", "serial"]
            l.caseSensitive = false
            return l
        case "bash", "sh", "shell", "zsh":
            var l = Lang(blockComments: [], quoteCodes: [34, 39], hashComment: true)
            l.keywords = ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac",
                          "function", "return", "exit", "export", "local", "readonly", "in", "echo",
                          "cd", "ls", "rm", "cp", "mv", "mkdir", "grep", "sed", "awk", "cat", "set", "source"]
            return l
        case "json", "jsonc":
            var l = Lang(lineComments: [], blockComments: [], quoteCodes: [34])
            l.keywords = ["true", "false", "null"]
            return l
        case "css", "scss", "less":
            var l = Lang(lineComments: ["//"], blockComments: [("/*", "*/")], quoteCodes: [34, 39])
            l.keywords = ["color", "background", "margin", "padding", "border", "display", "position",
                          "width", "height", "font", "font-family", "font-size", "flex", "grid", "gap",
                          "important", "media", "import", "from", "root", "hover"]
            return l
        case "yaml", "yml", "toml", "ini":
            var l = Lang(lineComments: [], blockComments: [], quoteCodes: [34, 39], hashComment: true)
            l.keywords = ["true", "false", "null", "yes", "no"]
            return l
        case "html", "xml", "svg", "vue":
            return Lang()
        default:
            return nil
        }
    }

    // MARK: - 通用扫描器（按 UTF-16 码元推进，区间即 NSRange）

    private static func scan(_ code: String, _ cfg: Lang) -> [Token] {
        var out: [Token] = []
        let u = Array(code.utf16)
        var i = 0

        func isAsciiLetter(_ x: UInt16) -> Bool { (x >= 65 && x <= 90) || (x >= 97 && x <= 122) }
        func isDigit(_ x: UInt16) -> Bool { x >= 48 && x <= 57 }
        func isIdent(_ x: UInt16) -> Bool { isAsciiLetter(x) || isDigit(x) || x == 95 || x == 36 }  // _ $
        func matches(at j: Int, _ s: String) -> Bool {
            let a = Array(s.utf16)
            guard j + a.count <= u.count else { return false }
            for k in 0..<a.count where u[j + k] != a[k] { return false }
            return true
        }
        func emit(_ start: Int, _ end: Int, _ cls: TokenClass) {
            guard end > start else { return }
            out.append(Token(range: NSRange(location: start, length: end - start), cls: cls))
        }

        while i < u.count {
            let c = u[i]

            // # 注释
            if cfg.hashComment, c == 35 {
                let s = i
                while i < u.count, u[i] != 10 { i += 1 }
                emit(s, i, .comment); continue
            }
            // 行注释
            if let lc = cfg.lineComments.first(where: { matches(at: i, $0) }) {
                _ = lc
                let s = i
                while i < u.count, u[i] != 10 { i += 1 }
                emit(s, i, .comment); continue
            }
            // 块注释
            if let bc = cfg.blockComments.first(where: { matches(at: i, $0.0) }) {
                let s = i
                i += bc.0.utf16.count
                while i < u.count, !matches(at: i, bc.1) { i += 1 }
                if matches(at: i, bc.1) { i += bc.1.utf16.count }
                emit(s, i, .comment); continue
            }
            // 字符串
            if cfg.quoteCodes.contains(c) || (cfg.allowsBacktick && c == 96) {
                let quote = c
                let s = i
                i += 1
                while i < u.count {
                    let x = u[i]; i += 1
                    if x == 92, i < u.count { i += 1; continue }        // 反斜杠转义
                    if x == quote { break }
                    if quote != 96, x == 10 { break }                   // 普通串不跨行
                }
                emit(s, i, .string); continue
            }
            // 数字
            if isDigit(c) {
                let s = i
                while i < u.count {
                    let x = u[i]
                    if isDigit(x) || x == 46 || x == 95 || x == 120 || x == 101 || x == 45 { i += 1 } else { break }
                }
                emit(s, i, .number); continue
            }
            // 标识符 / 关键字 / 类型
            if isAsciiLetter(c) || c == 95 {
                let s = i
                while i < u.count, isIdent(u[i]) { i += 1 }
                let word = String(decoding: u[s..<i], as: UTF16.self)
                let probe = cfg.caseSensitive ? word : word.lowercased()
                let kws = cfg.caseSensitive ? cfg.keywords : Set(cfg.keywords.map { $0.lowercased() })
                let tys = cfg.caseSensitive ? cfg.types : Set(cfg.types.map { $0.lowercased() })
                if kws.contains(probe) { emit(s, i, .keyword) }
                else if tys.contains(probe) { emit(s, i, .type) }
                continue
            }
            i += 1
        }
        return out
    }

    // MARK: - HTML / XML（标签名 + 属性名 + 属性值 + 注释）

    private static func markupTokens(_ code: String) -> [Token] {
        var out: [Token] = []
        let u = Array(code.utf16)
        var i = 0

        func isAsciiLetter(_ x: UInt16) -> Bool { (x >= 65 && x <= 90) || (x >= 97 && x <= 122) }
        func isDigit(_ x: UInt16) -> Bool { x >= 48 && x <= 57 }
        func matches(at j: Int, _ s: String) -> Bool {
            let a = Array(s.utf16)
            guard j + a.count <= u.count else { return false }
            for k in 0..<a.count where u[j + k] != a[k] { return false }
            return true
        }
        func emit(_ start: Int, _ end: Int, _ cls: TokenClass) {
            guard end > start else { return }
            out.append(Token(range: NSRange(location: start, length: end - start), cls: cls))
        }

        while i < u.count {
            guard u[i] == 60 else { i += 1; continue }   // '<'
            // 注释 <!-- … -->
            if matches(at: i, "<!--") {
                let s = i
                while i < u.count, !matches(at: i, "-->") { i += 1 }
                if i < u.count { i += 3 }
                emit(s, i, .comment); continue
            }
            // 标签
            let tagStart = i
            while i < u.count, u[i] != 62 { i += 1 }     // '>'
            if i < u.count { i += 1 }
            let interiorEnd = (i > tagStart && u[i - 1] == 62) ? i - 1 : i

            // 标签名
            var j = tagStart + 1
            if j < interiorEnd, u[j] == 47 { j += 1 }    // '/'
            let nameStart = j
            while j < interiorEnd, isAsciiLetter(u[j]) || isDigit(u[j]) || u[j] == 45 || u[j] == 58 || u[j] == 95 { j += 1 }
            emit(nameStart, j, .keyword)

            // 属性：属性名（= 前）→ 类型色；引号串 → 字符串色
            var k = j
            while k < interiorEnd {
                let x = u[k]
                if x == 34 || x == 39 {
                    let q = x; let ss = k; k += 1
                    while k < interiorEnd, u[k] != q { k += 1 }
                    if k < interiorEnd { k += 1 }
                    emit(ss, k, .string); continue
                }
                if isAsciiLetter(x) || x == 95 || x == 45 {
                    let ss = k
                    while k < interiorEnd, isAsciiLetter(u[k]) || isDigit(u[k]) || u[k] == 45 || u[k] == 58 || u[k] == 95 { k += 1 }
                    var m = k
                    while m < interiorEnd, u[m] == 32 || u[m] == 9 { m += 1 }
                    if m < interiorEnd, u[m] == 61 { emit(ss, k, .type) }
                    continue
                }
                k += 1
            }
        }
        return out
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
