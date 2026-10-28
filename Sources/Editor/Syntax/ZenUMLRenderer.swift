import AppKit

/// 自研 **Mermaid `zenuml`** 渲染（swift-mermaid 不支持）：
/// 参与者列布局 + 生命线 + 自上而下的带标签消息箭头（顺序图 / 时序风格）。
///
/// 支持的语法（简化子集）：
/// ```
/// zenuml
///   title 登录流程
///   @Actor 用户
///   @Boundary 网关
///   用户 -> 网关: 提交账号
///   if (账号有效) {
///     网关 -> 用户: 登录成功
///   } else {
///     网关 -> 用户: 提示错误
///   }
///   return 登录结果
///   网关.checkToken()
/// ```
/// - 首行 `zenuml`（首行原样跳过，不作为消息解析）；`%%` 注释与 `%%{init: ...}%%`
///   配置指令由 `MermaidSource.stripped` 在解析入口统一剔除。
/// - `title 文本`：画布顶部标题。
/// - 参与者声明 `@Actor 名称` / `@Boundary 名称` 等：声明顺序决定列顺序；
///   未声明的参与者按首次在消息里出现的顺序追加。`@Actor` 后无名称时用类型名当参与者名。
/// - 消息行 `A -> B: 消息`：箭头支持 `->` / `-->`（实线）与 `=>`（虚线）；
///   冒号可省略（`A -> B` 即无标签），半角 `:` 与全角 `：` 都接受，`A->B:消息` 无空格也可以。
/// - 自调用行 `A.method()` / `A.method(参数)`：在 A 的生命线上画自环箭头，标签为方法名。
/// - 控制块：`if (条件) { ... }`、`loop (条件) { ... }`、`alt (条件) { ... }`、
///   `opt (条件) { ... }`、`par { ... }`，`if` / `alt` 支持 `} else { ... }`（也接受
///   `} else (条件) {`、单独的 `else {`）。块体在生命线之间画浅色分组矩形，左上角为
///   条件标签；块内消息照常绘制。嵌套按 1 层（两层矩形）设计，更深的层仍可渲染，
///   只是缩进封顶。单行块 `if (x) { A -> B: m }` 也接受。
/// - `return` / `return 文本`：从上一条消息的接收者画虚线反向箭头回到发送者，
///   标签为 `return` 或后续文本；没有上一条消息时忽略该行。
/// - 参与者上限 10 个；未闭合/多余的控制块花括号视为语法错误。
/// - 没有可识别消息、或解析失败时返回 nil（调用方回退源码并提示）。
enum ZenUMLRenderer {
    private struct Message {
        var from: String
        var to: String
        var label: String
        var dashed: Bool
        /// 自调用（`A.method()`）：在 from 对应的列上画自环。
        var selfCall: Bool
    }

    /// 一个控制块：标签（含关键字与条件）+ 视觉缩进层级（0 = 最外层）。
    private struct Block {
        var label: String
        var depth: Int
    }

    /// 解析后的事件序列：消息与控制块的开始/结束按源码顺序排列。
    private enum Item {
        case message(Message)
        case blockOpen(Int)
        case blockClose(Int)
    }

    private struct Parsed {
        var title: String
        var participants: [String]
        var blocks: [Block]
        var items: [Item]
    }

    // 画布与排版常量：宽度硬上限 1200pt，便于嵌入正文预览。
    private static let padding: CGFloat = 18
    private static let titleBarHeight: CGFloat = 26
    private static let headerHeight: CGFloat = 34
    private static let rowHeight: CGFloat = 48
    private static let firstRowGap: CGFloat = 18
    private static let bottomGap: CGFloat = 16
    private static let columnGap: CGFloat = 18
    private static let minColumnWidth: CGFloat = 86
    private static let maxColumnWidth: CGFloat = 190
    private static let maxCanvasWidth: CGFloat = 1200
    private static let maxParticipants = 10

    /// 控制块：标签行高度、块底留白、空块最小高度。
    private static let blockHeaderSpace: CGFloat = 20
    private static let blockBottomSpace: CGFloat = 8
    private static let blockMinHeight: CGFloat = 34

    private static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let headerFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let labelFont = NSFont.systemFont(ofSize: 11)
    private static let blockLabelFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)

    /// 低饱和灰蓝：参与者框、箭头统一使用，整幅图保持克制。
    private static let accent = NSColor(srgbRed: 0.34, green: 0.47, blue: 0.62, alpha: 1)
    /// 生命线用的更浅灰蓝。
    private static let lifelineColor = NSColor(srgbRed: 0.55, green: 0.60, blue: 0.67, alpha: 1)

    static func image(forSource source: String) -> NSImage? {
        // 入口统一剔除 `%%{init}%%` 配置指令与 `%%` 注释行。
        guard let parsed = parse(MermaidSource.stripped(source)) else { return nil }
        let participants = parsed.participants

        // 列宽先按参与者名自适应，再在超宽时整体压缩（下限 44pt，保证箭头仍有跨度）。
        var widths = participants.map { columnWidth(for: $0) }
        let gaps = CGFloat(participants.count - 1) * columnGap
        let maxContent = maxCanvasWidth - padding * 2
        let measured = widths.reduce(0, +)
        if measured + gaps > maxContent {
            let available = max(1, maxContent - gaps)
            let scale = available / measured
            widths = widths.map { max(44, ($0 * scale).rounded(.down)) }
            if widths.reduce(0, +) > available {
                let per = max(36, (available / CGFloat(participants.count)).rounded(.down))
                widths = widths.map { min($0, per) }
            }
        }
        let width = padding * 2 + widths.reduce(0, +) + gaps

        // 每列的横向中心。
        var centers: [CGFloat] = []
        var cursorX = padding
        for columnWidth in widths {
            centers.append(cursorX + columnWidth / 2)
            cursorX += columnWidth + columnGap
        }

        // 控制块的标签与块底需要额外竖向空间；先累加内容高度再确定总量。
        let titleHeight = parsed.title.isEmpty ? 0 : titleBarHeight
        var contentHeight: CGFloat = 0
        for item in parsed.items {
            switch item {
            case .message: contentHeight += rowHeight
            case .blockOpen: contentHeight += blockHeaderSpace
            case .blockClose: contentHeight += blockBottomSpace
            }
        }
        let height = padding * 2 + titleHeight + headerHeight + firstRowGap
            + contentHeight + bottomGap

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.textBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        let headerTop = height - padding - titleHeight
        let headerBottom = headerTop - headerHeight

        if !parsed.title.isEmpty {
            drawLeft(parsed.title, font: titleFont, color: NSColor.labelColor,
                     x: padding, y: height - padding - 16,
                     maxWidth: max(1, width - padding * 2))
        }

        // 一次遍历算出消息的 y 与每个块的外框：块从开始行上沿起、到结束行下沿止。
        let bounds = blockBounds(centers: centers, width: width)
        var blockTops = [CGFloat](repeating: 0, count: parsed.blocks.count)
        var placedBlocks: [(block: Block, rect: NSRect)] = []
        var placedMessages: [(message: Message, y: CGFloat)] = []
        var cursor = headerBottom - firstRowGap
        for item in parsed.items {
            switch item {
            case .blockOpen(let index):
                blockTops[index] = cursor + 2
                cursor -= blockHeaderSpace
            case .message(let message):
                placedMessages.append((message, cursor - rowHeight / 2))
                cursor -= rowHeight
            case .blockClose(let index):
                let top = blockTops[index]
                let bottom = cursor - 4
                let depth = parsed.blocks[index].depth
                var rect = NSRect(x: bounds.minX, y: bottom,
                                  width: max(1, bounds.maxX - bounds.minX),
                                  height: max(blockMinHeight, top - bottom))
                // 内层块左右内缩，形成可见的嵌套层次。
                if depth > 0 {
                    let inset = min(6, max(0, rect.width / 2 - 1))
                    rect = rect.insetBy(dx: inset, dy: 0)
                }
                placedBlocks.append((parsed.blocks[index], rect))
                cursor -= blockBottomSpace
            }
        }

        // 先铺块底色，再画生命线与参与者框，最后画块边框/标签与消息：
        // 底色不会盖住生命线，标签与箭头也不会被底色压住。
        for placed in placedBlocks { fillBlock(placed.block, rect: placed.rect) }
        for (index, name) in participants.enumerated() {
            drawLifeline(x: centers[index], top: headerBottom, bottom: padding)
            drawParticipant(name, rect: NSRect(x: centers[index] - widths[index] / 2,
                                               y: headerBottom,
                                               width: widths[index],
                                               height: headerHeight))
        }
        for placed in placedBlocks { strokeBlock(placed.block, rect: placed.rect) }
        for placed in placedMessages {
            let message = placed.message
            guard let fromIndex = participants.firstIndex(of: message.from) else { continue }
            if message.selfCall || message.from == message.to {
                drawSelfMessage(message, x: centers[fromIndex], y: placed.y, width: width)
            } else if let toIndex = participants.firstIndex(of: message.to) {
                drawMessage(message, fromX: centers[fromIndex], toX: centers[toIndex],
                            y: placed.y, width: width)
            }
        }

        return image
    }

    // MARK: - 解析

    private static func parse(_ source: String) -> Parsed? {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // 类型声明行：首个非空行（通常是 `zenuml`），不作为正文解析。
        let typeLine = lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        var title = ""
        var participants: [String] = []
        var seen = Set<String>()

        func register(_ name: String) {
            guard !name.isEmpty, seen.insert(name).inserted else { return }
            participants.append(name)
        }

        // 第一遍：标题与参与者声明（声明顺序决定列顺序，先于消息登记）。
        for (index, rawLine) in lines.enumerated() {
            guard index != typeLine else { continue }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let heading = titleText(from: line) {
                title = heading
                continue
            }
            if let actor = actorDeclaration(from: line) {
                register(actor)
            }
        }

        // 第二遍：消息与控制块。
        var items: [Item] = []
        var blocks: [Block] = []
        var stack: [Int] = []
        var lastMessage: Message?
        var messageCount = 0
        var invalid = false

        func openBlock(_ label: String) {
            // 视觉缩进按 1 层嵌套设计；更深层仍可渲染，只是缩进不再增加。
            let depth = min(stack.count, 1)
            let index = blocks.count
            blocks.append(Block(label: label, depth: depth))
            items.append(.blockOpen(index))
            stack.append(index)
        }

        func closeBlock() -> Bool {
            guard let index = stack.popLast() else { return false }
            items.append(.blockClose(index))
            return true
        }

        func accept(_ text: String) {
            let line = text.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return }
            if let message = parseMessage(line) {
                register(message.from)
                register(message.to)
                items.append(.message(message))
                lastMessage = message
                messageCount += 1
            } else if let call = parseSelfCall(line) {
                register(call.actor)
                let message = Message(from: call.actor, to: call.actor,
                                      label: call.label, dashed: false, selfCall: true)
                items.append(.message(message))
                lastMessage = message
                messageCount += 1
            }
        }

        /// 处理块头 `{` 之后的剩余内容（单行块），`;` 分隔多条消息。
        func handleBody(_ body: String, closesAtEnd: Bool) {
            for part in body.split(separator: ";") {
                accept(String(part))
            }
            if closesAtEnd, !closeBlock() { invalid = true }
        }

        for (index, rawLine) in lines.enumerated() {
            guard index != typeLine else { continue }
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            while line.hasSuffix(";") {
                line = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
            }
            guard !line.isEmpty else { continue }

            // 标题与声明已在第一遍处理，这里跳过。
            if titleText(from: line) != nil { continue }
            if actorDeclaration(from: line) != nil { continue }

            if let message = returnMessage(from: line, last: lastMessage) {
                register(message.from)
                register(message.to)
                items.append(.message(message))
                lastMessage = message
                messageCount += 1
                continue
            }

            // `} else {` 同时关闭上一分支并开启 else 分支；先于单独 `}` 判断。
            if let branch = elseHeader(from: line) {
                guard closeBlock() else {
                    invalid = true
                    break
                }
                openBlock(branch.label)
                handleBody(branch.remainder, closesAtEnd: branch.closes)
                continue
            }

            if line == "}" {
                guard closeBlock() else {
                    invalid = true
                    break
                }
                continue
            }

            if let header = blockHeader(from: line) {
                openBlock(header.label)
                handleBody(header.remainder, closesAtEnd: header.closes)
                continue
            }

            accept(line)
        }

        // 未闭合的块、多余的 `}` 都视为语法错误；没有消息时也没有可画的图。
        guard !invalid, stack.isEmpty else { return nil }
        guard messageCount > 0, !participants.isEmpty,
              participants.count <= maxParticipants else { return nil }
        return Parsed(title: title, participants: participants, blocks: blocks, items: items)
    }

    /// `title 文本`：仅当后接空格且不含箭头时才是标题（避免把 `title -> A` 当成标题）。
    private static func titleText(from line: String) -> String? {
        let lower = line.lowercased()
        guard lower.hasPrefix("title ") else { return nil }
        let text = String(line.dropFirst("title".count)).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains("->") else { return nil }
        return String(text.prefix(80))
    }

    /// `@Actor 名称` / `@Boundary 名称` / `@Actor 名称 as 别名`：返回参与者名。
    private static func actorDeclaration(from line: String) -> String? {
        guard line.hasPrefix("@") else { return nil }
        let body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        guard let space = body.firstIndex(where: { $0.isWhitespace }) else {
            // 只有类型、没有名称时用类型名占位（如 `@Boundary`）。
            return cleanName(body)
        }
        var name = String(body[body.index(after: space)...]).trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = String(body[..<space]) }
        if let alias = name.range(of: " as ") {
            name = String(name[..<alias.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return cleanName(name)
    }

    /// 控制块开头：`if (x) {` / `loop (x) {` / `alt (x) {` / `opt (x) {` / `par {`。
    /// 返回标签（`{` 之前的文本）与 `{` 之后的剩余内容（单行块）。
    private static func blockHeader(from line: String)
        -> (label: String, remainder: String, closes: Bool)? {
        let lower = line.lowercased()
        var matched = false
        for keyword in ["if", "loop", "alt", "opt", "par"] {
            guard lower.hasPrefix(keyword) else { continue }
            let rest = line.dropFirst(keyword.count)
            if let first = rest.first, !first.isWhitespace, first != "(" { continue }
            matched = true
            break
        }
        guard matched, let brace = line.firstIndex(of: "{") else { return nil }
        let head = String(line[..<brace]).trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty else { return nil }
        var remainder = String(line[line.index(after: brace)...])
            .trimmingCharacters(in: .whitespaces)
        var closes = false
        if let closing = remainder.firstIndex(of: "}") {
            closes = true
            remainder = String(remainder[..<closing]).trimmingCharacters(in: .whitespaces)
        }
        return (String(head.prefix(60)), remainder, closes)
    }

    /// `} else {` / `} else (条件) {` / `else {`：关闭当前分支并返回 else 分支标签。
    private static func elseHeader(from line: String)
        -> (label: String, remainder: String, closes: Bool)? {
        var body = line
        if body.hasPrefix("}") {
            body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        let lower = body.lowercased()
        guard lower.hasPrefix("else") else { return nil }
        let after = body.dropFirst("else".count)
        if let first = after.first, !first.isWhitespace, first != "(", first != "{" { return nil }
        guard let brace = body.firstIndex(of: "{") else { return nil }
        let head = String(body[..<brace]).trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty else { return nil }
        var remainder = String(body[body.index(after: brace)...])
            .trimmingCharacters(in: .whitespaces)
        var closes = false
        if let closing = remainder.firstIndex(of: "}") {
            closes = true
            remainder = String(remainder[..<closing]).trimmingCharacters(in: .whitespaces)
        }
        return (String(head.prefix(60)), remainder, closes)
    }

    /// `return` / `return 文本`：从上一条消息的接收者虚线返回发送者。
    private static func returnMessage(from line: String, last: Message?) -> Message? {
        let lower = line.lowercased()
        guard lower == "return" || lower.hasPrefix("return ")
            || lower.hasPrefix("return:") || lower.hasPrefix("return：") else { return nil }
        guard let last else { return nil }
        var tail = String(line.dropFirst("return".count)).trimmingCharacters(in: .whitespaces)
        if tail.hasPrefix(":") || tail.hasPrefix("：") {
            tail = String(tail.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        let label = tail.isEmpty ? "return" : String(tail.prefix(120))
        return Message(from: last.to, to: last.from, label: label,
                       dashed: true, selfCall: false)
    }

    /// 解析 `A -> B: 消息`（也接受 `A-->B:消息`、`A => B`、无标签的 `A -> B`）。
    private static func parseMessage(_ line: String) -> Message? {
        // `-->` 必须先于 `->` 判断，否则会被拆成 `-` + `>`。
        var arrow: (range: Range<String.Index>, dashed: Bool)?
        if let range = line.range(of: "-->") {
            arrow = (range, false)
        } else if let range = line.range(of: "=>") {
            arrow = (range, true)
        } else if let range = line.range(of: "->") {
            arrow = (range, false)
        }
        guard let arrow else { return nil }

        let from = cleanName(String(line[..<arrow.range.lowerBound]))
        guard !from.isEmpty else { return nil }

        var rest = String(line[arrow.range.upperBound...]).trimmingCharacters(in: .whitespaces)
        while rest.hasSuffix(";") {
            rest = String(rest.dropLast()).trimmingCharacters(in: .whitespaces)
        }

        var target = rest
        var label = ""
        if let colon = rest.firstIndex(where: { $0 == ":" || $0 == "：" }) {
            target = String(rest[..<colon])
            label = String(rest[rest.index(after: colon)...])
        }
        target = cleanName(target)
        label = cleanLabel(label)
        guard !target.isEmpty else { return nil }
        return Message(from: from, to: target, label: label,
                       dashed: arrow.dashed, selfCall: false)
    }

    /// 解析自调用 `A.method()` / `A.method(参数)`；其它形态（如 `if (x)`）返回 nil。
    private static func parseSelfCall(_ line: String) -> (actor: String, label: String)? {
        guard line.hasSuffix(")"), let open = line.firstIndex(of: "(") else { return nil }
        let head = String(line[..<open]).trimmingCharacters(in: .whitespaces)
        let arguments = String(line[line.index(after: open)..<line.index(before: line.endIndex)])
            .trimmingCharacters(in: .whitespaces)
        guard let dot = head.lastIndex(of: ".") else { return nil }

        let actor = cleanName(String(head[..<dot]))
        let method = String(head[head.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
        // 方法名限定为标识符，避免把控制语法（if/while 等）误当成自调用。
        guard !actor.isEmpty, !method.isEmpty,
              method.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
        else { return nil }

        let label = arguments.isEmpty ? method : "\(method)(\(arguments))"
        return (actor, label)
    }

    /// 参与者 / 目标名清洗：去引号、去尾部 `;` 与多余空白，并限制长度。
    private static func cleanName(_ text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespaces)
        while body.hasSuffix(";") {
            body = String(body.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if body.count >= 2, body.hasPrefix("\""), body.hasSuffix("\"") {
            body = String(body.dropFirst().dropLast())
        } else if body.count >= 2, body.hasPrefix("'"), body.hasSuffix("'") {
            body = String(body.dropFirst().dropLast())
        }
        body = body.trimmingCharacters(in: .whitespaces)
        return String(body.prefix(60))
    }

    private static func cleanLabel(_ text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespaces)
        while body.hasSuffix(";") {
            body = String(body.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if body.count >= 2, body.hasPrefix("\""), body.hasSuffix("\"") {
            body = String(body.dropFirst().dropLast())
        }
        return String(body.trimmingCharacters(in: .whitespaces).prefix(120))
    }

    // MARK: - 布局

    /// 列宽 = 参与者名宽度 + 左右内边距，夹在 [86, 190]。
    private static func columnWidth(for name: String) -> CGFloat {
        let textWidth = (name as NSString).size(withAttributes: [.font: headerFont]).width
        return min(maxColumnWidth, max(minColumnWidth, (textWidth + 26).rounded()))
    }

    /// 控制块横跨所有生命线；只有单个参与者时用最小宽度保证标签放得下。
    private static func blockBounds(centers: [CGFloat], width: CGFloat)
        -> (minX: CGFloat, maxX: CGFloat) {
        let minAllowed: CGFloat = 4
        let maxAllowed = max(minAllowed + 1, width - 4)
        let left = (centers.min() ?? padding) - 16
        let right = (centers.max() ?? (width - padding)) + 16
        var minX = max(minAllowed, min(maxAllowed - 1, left))
        var maxX = min(maxAllowed, max(minX + 1, right))
        if maxX - minX < 72 {
            let mid = (minX + maxX) / 2
            minX = max(minAllowed, mid - 36)
            maxX = min(maxAllowed, mid + 36)
        }
        return (minX, max(maxX, minX + 1))
    }

    // MARK: - 绘制

    /// 控制块底色：外层更淡、内层稍深，形成层次。
    private static func fillBlock(_ block: Block, rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        accent.withAlphaComponent(block.depth == 0 ? 0.055 : 0.08).setFill()
        path.fill()
    }

    /// 控制块边框 + 左上角标签。
    private static func strokeBlock(_ block: Block, rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        accent.withAlphaComponent(0.38).setStroke()
        path.lineWidth = 1
        path.stroke()
        drawBlockLabel(block, rect: rect)
    }

    private static func drawBlockLabel(_ block: Block, rect: NSRect) {
        let inset = 8 + CGFloat(block.depth) * 10
        let text = fitted(block.label, font: blockLabelFont,
                          maxWidth: max(20, rect.width - inset - 8))
        guard !text.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: blockLabelFont,
            .foregroundColor: accent,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let baseline = rect.maxY - 17
        // 标签底垫一小块同色底，避免生命线虚线穿过文字。
        let background = NSRect(x: rect.minX + inset - 4, y: baseline - 2,
                                width: min(rect.width - inset, size.width + 8),
                                height: size.height + 4)
        accent.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: background, xRadius: 3, yRadius: 3).fill()
        (text as NSString).draw(at: NSPoint(x: rect.minX + inset, y: baseline),
                                withAttributes: attributes)
    }

    private static func drawParticipant(_ name: String, rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        accent.withAlphaComponent(0.12).setFill()
        path.fill()
        accent.withAlphaComponent(0.75).setStroke()
        path.lineWidth = 1.2
        path.stroke()

        let text = fitted(name, font: headerFont, maxWidth: max(1, rect.width - 14))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: headerFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2,
                                            y: rect.midY - size.height / 2),
                                withAttributes: attributes)
    }

    private static func drawLifeline(x: CGFloat, top: CGFloat, bottom: CGFloat) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: top))
        path.line(to: NSPoint(x: x, y: bottom))
        path.lineWidth = 0.8
        path.setLineDash([3, 3], count: 2, phase: 0)
        lifelineColor.withAlphaComponent(0.65).setStroke()
        path.stroke()
    }

    /// 普通消息：源列到目标列的水平箭头，标签居中压在箭头上方。
    private static func drawMessage(_ message: Message, fromX: CGFloat, toX: CGFloat,
                                    y: CGFloat, width: CGFloat) {
        let rightward = toX > fromX
        let start = NSPoint(x: fromX + (rightward ? 2 : -2), y: y)
        let end = NSPoint(x: toX + (rightward ? -2 : 2), y: y)

        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = 1.2
        if message.dashed { path.setLineDash([4, 3], count: 2, phase: 0) }
        accent.setStroke()
        path.stroke()
        drawHead(at: end, angle: rightward ? 0 : .pi, color: accent)

        guard !message.label.isEmpty else { return }
        let centerX = (start.x + end.x) / 2
        let maxWidth = max(40, abs(end.x - start.x) - 10)
        drawCentered(message.label, font: labelFont,
                     color: NSColor.secondaryLabelColor,
                     centerX: centerX, y: y + 7, maxWidth: maxWidth)
    }

    /// 自调用：在参与者列上画一个小自环（右侧空间不足时改画在左侧），标签贴在环外侧。
    private static func drawSelfMessage(_ message: Message, x: CGFloat, y: CGFloat, width: CGFloat) {
        let loopOut: CGFloat = 30
        let half: CGFloat = 7
        // 右侧要留出「环 + 一小段标签」的位置，否则改到左侧。
        let spaceRight = width - padding / 2 - x
        let goesRight = spaceRight > loopOut + 70
        let direction: CGFloat = goesRight ? 1 : -1
        let tip = x + direction * loopOut

        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: y + half))
        path.curve(to: NSPoint(x: x, y: y - half),
                   controlPoint1: NSPoint(x: tip, y: y + 19),
                   controlPoint2: NSPoint(x: tip, y: y - 19))
        path.lineWidth = 1.1
        if message.dashed { path.setLineDash([4, 3], count: 2, phase: 0) }
        accent.setStroke()
        path.stroke()
        drawHead(at: NSPoint(x: x, y: y - half), angle: -.pi / 2, color: accent)

        guard !message.label.isEmpty else { return }
        if goesRight {
            let left = x + loopOut + 6
            drawLeft(message.label, font: labelFont, color: NSColor.secondaryLabelColor,
                     x: left, y: y - 6, maxWidth: max(30, width - padding / 2 - left))
        } else {
            let right = x - loopOut - 6
            drawRight(message.label, font: labelFont, color: NSColor.secondaryLabelColor,
                      x: right, y: y - 6, maxWidth: max(30, right - padding / 2))
        }
    }

    /// 实心三角箭头头部，`angle` 为箭头指向（弧度，0 = 向右）。
    private static func drawHead(at point: NSPoint, angle: CGFloat, color: NSColor) {
        let length: CGFloat = 8
        let halfWidth: CGFloat = 4.5
        let baseX = point.x - cos(angle) * length
        let baseY = point.y - sin(angle) * length
        let offsetX = -sin(angle) * halfWidth
        let offsetY = cos(angle) * halfWidth
        let head = NSBezierPath()
        head.move(to: point)
        head.line(to: NSPoint(x: baseX + offsetX, y: baseY + offsetY))
        head.line(to: NSPoint(x: baseX - offsetX, y: baseY - offsetY))
        head.close()
        color.setFill()
        head.fill()
    }

    /// 以 `centerX` 居中的单行文本（超宽截断）。
    private static func drawCentered(_ text: String, font: NSFont, color: NSColor,
                                     centerX: CGFloat, y: CGFloat, maxWidth: CGFloat) {
        let line = fitted(text, font: font, maxWidth: maxWidth)
        guard !line.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (line as NSString).size(withAttributes: attributes)
        (line as NSString).draw(at: NSPoint(x: centerX - size.width / 2, y: y),
                                withAttributes: attributes)
    }

    /// 以 `x` 为左起点的单行文本（超宽截断）。
    private static func drawLeft(_ text: String, font: NSFont, color: NSColor,
                                 x: CGFloat, y: CGFloat, maxWidth: CGFloat) {
        let line = fitted(text, font: font, maxWidth: maxWidth)
        guard !line.isEmpty else { return }
        (line as NSString).draw(at: NSPoint(x: x, y: y),
                                withAttributes: [.font: font, .foregroundColor: color])
    }

    /// 以 `x` 为右终点的单行文本（超宽截断）。
    private static func drawRight(_ text: String, font: NSFont, color: NSColor,
                                  x: CGFloat, y: CGFloat, maxWidth: CGFloat) {
        let line = fitted(text, font: font, maxWidth: maxWidth)
        guard !line.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (line as NSString).size(withAttributes: attributes)
        (line as NSString).draw(at: NSPoint(x: x - size.width, y: y),
                                withAttributes: attributes)
    }

    /// 单行截断到指定宽度（超出时以 `…` 结尾），保证文字不溢出。
    private static func fitted(_ text: String, font: NSFont, maxWidth: CGFloat) -> String {
        guard maxWidth > 8 else { return "" }
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        if (text as NSString).size(withAttributes: attributes).width <= maxWidth { return text }
        var characters = Array(text)
        while !characters.isEmpty {
            characters.removeLast()
            let candidate = String(characters) + "…"
            if (candidate as NSString).size(withAttributes: attributes).width <= maxWidth {
                return candidate
            }
        }
        return "…"
    }
}
