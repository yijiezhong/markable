import Foundation

/// Mermaid 源码的公共预处理（自研渲染器共用）。
///
/// Mermaid 允许在源码中写两类与图形无关的行：
/// - 配置指令 `%%{init: {"theme": "dark"}}%%`（可跨行）；
/// - 注释 `%% 说明文字`。
///
/// 自研渲染器逐行解析正文，若不先剔除这些行，配置指令会被当成未知语法
/// （例如 zenuml 会把 `%%{init...` 误判成参与者），注释行也可能干扰
/// 「首行即类型声明」的判断。这里统一提供过滤能力，各渲染器在解析入口
/// 调用一次 `stripped(_:)` 即可。
enum MermaidSource {
    /// 指令起始与结束标记（与 Mermaid 官方语法一致）。
    private static let directiveOpen = "%%{"
    private static let directiveClose = "}%%"

    /// 去掉所有 `%%{ ... }%%` 配置指令（支持跨行）与整行 `%%` 注释，保留其余行。
    ///
    /// - 指令独占一行时整行删除；指令与正文同一行时只删除指令片段。
    /// - 原始空行原样保留（部分渲染器的空行有语义，例如 eventmodeling 用它结束隐式链）。
    /// - 未闭合的 `%%{` 之后的内容会被丢弃，调用方最终通常会因「无可识别内容」回退源码。
    static func stripped(_ source: String) -> String {
        var output: [String] = []
        var inDirective = false

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = Substring(rawLine)
            var kept = ""
            var strippedAnything = false

            while !rest.isEmpty {
                if inDirective {
                    if let end = rest.range(of: directiveClose) {
                        rest = rest[end.upperBound...]
                        inDirective = false
                    } else {
                        // 指令尚未结束：整段丢弃，继续看下一行。
                        rest = rest[rest.endIndex...]
                    }
                } else if let start = rest.range(of: directiveOpen) {
                    kept += String(rest[..<start.lowerBound])
                    rest = rest[start.lowerBound...]
                    strippedAnything = true
                    if let end = rest.range(of: directiveClose) {
                        rest = rest[end.upperBound...]
                    } else {
                        inDirective = true
                        rest = rest[rest.endIndex...]
                    }
                } else {
                    kept += String(rest)
                    rest = rest[rest.endIndex...]
                }
            }

            // 整行注释（`%%` 开头，且不在 `%%{` 指令里）直接丢弃。
            if kept.trimmingCharacters(in: .whitespaces).hasPrefix("%%") { continue }
            // 指令行被剥空后不留空行，避免改变「首行」判断。
            if kept.trimmingCharacters(in: .whitespaces).isEmpty, strippedAnything { continue }
            output.append(kept)
        }

        return output.joined(separator: "\n")
    }

    /// 返回首个 `%%{init: ...}%%` 指令的括号内内容（如 `init: {"theme":"dark"}`）。
    ///
    /// 本轮渲染器只容忍/忽略配置指令，不解析其内容；该接口留给后续实现
    /// 主题色等配置时使用。没有 `init` 指令（或指令未闭合）时返回 nil。
    static func firstDirective(_ source: String) -> String? {
        var cursor = source.startIndex
        while let start = source.range(of: directiveOpen, range: cursor..<source.endIndex) {
            guard let end = source.range(of: directiveClose, range: start.upperBound..<source.endIndex)
            else { return nil }
            let body = source[start.upperBound..<end.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if body.lowercased().hasPrefix("init") { return body }
            cursor = end.upperBound
        }
        return nil
    }

    /// Mermaid 内置主题（来自 `%%{init: {"theme": "dark"}}%%`）。
    enum Theme: String, CaseIterable, Equatable {
        case `default`, dark, forest, neutral, base
    }

    /// 解析 `%%{init: ...}%%` 里的 `theme` 字段；没有配置 / 无法识别时返回 `.default`。
    ///
    /// 支持双引号、单引号与无引号写法（`"theme": "forest"` / `'theme': 'forest'` /
    /// `theme: forest`），字段名不区分大小写；`themeVariables` 里的同名键不会被误取
    /// （正则要求 `theme` 后紧跟冒号）。
    ///
    /// 说明：Vendor `swift-mermaid` 不接受配色注入，自研渲染器又跟随系统外观取色，
    /// 因此本解析结果目前只作为元信息暴露（`MermaidRenderer.theme(of:)`），
    /// 不改变渲染颜色——避免为了「主题」把 15 个渲染器的配色推倒重来。
    static func theme(of source: String) -> Theme {
        guard let directive = firstDirective(in: source) else { return .default }
        let pattern = #"["']?theme["']?\s*:\s*["']?([A-Za-z-]+)["']?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(
                in: directive,
                range: NSRange(location: 0, length: (directive as NSString).length)
              ),
              let range = Range(match.range(at: 1), in: directive)
        else { return .default }
        return Theme(rawValue: directive[range].lowercased()) ?? .default
    }

    /// 第一个 `%%{ ... }%%` 指令的内部文本（不含标记）。
    private static func firstDirective(in source: String) -> String? {
        guard let open = source.range(of: directiveOpen),
              let close = source.range(of: directiveClose, range: open.upperBound..<source.endIndex)
        else { return nil }
        return String(source[open.upperBound..<close.lowerBound])
    }
}
