import AppKit

/// 排版参数：字体族 + 行距 / 段间距 / 首行缩进。渲染与导出共用。
///
/// 默认值全部取"中性"（不改动既有观感）：等宽字体、行距 0、段间距 0、无首行缩进。
/// 预设（默认 / 舒适 / 学术 / 紧凑 / 技术）只是这些参数的一组取值。
struct Typography: Equatable, Codable {
    enum Family: String, Codable, CaseIterable, Identifiable {
        case system, sans, serif, mono
        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: return "系统"
            case .sans: return "非衬线"
            case .serif: return "衬线"
            case .mono: return "等宽"
            }
        }

        /// 指定字号与字重的字体；缺字体时回退系统字体。
        func font(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
            switch self {
            case .system:
                return NSFont.systemFont(ofSize: size, weight: weight)
            case .sans:
                // 显式非衬线：中文走苹方（PingFang SC），缺失时回退系统字体（同样是非衬线）
                let bold = (weight == .bold || weight.rawValue >= NSFont.Weight.semibold.rawValue)
                let name = bold ? "PingFangSC-Semibold" : "PingFangSC-Regular"
                return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
            case .serif:
                let name = (weight == .bold) ? "Songti SC Bold" : "Songti SC"
                return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
            case .mono:
                return Typography.monoFont(ofSize: size, weight: weight)
            }
        }
    }

    /// 代码/等宽字体：优先中西文等宽字体（Noto Sans Mono CJK SC，中文 = 2× 西文宽，
    /// 保证代码块里中英文混排时列对齐），系统缺失时回退系统等宽字体。
    static func monoFont(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let bold = weight == .bold || weight.rawValue >= NSFont.Weight.semibold.rawValue
        let name = bold ? "NotoSansMonoCJKsc-Bold" : "NotoSansMonoCJKsc-Regular"
        return NSFont(name: name, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    var family: Family = .mono
    /// 附加行距（点）。
    var lineSpacing: Double = 0
    /// 段后间距（点）。
    var paragraphSpacing: Double = 0
    /// 首行缩进（字符数；0 = 不缩进）。按正文字号换算成点。
    var firstLineIndent: Double = 0
    /// 是否给标题加层级编号（1 / 1.1 / 1.1.1 …）。
    var headingNumbering: Bool = false
    /// 是否给代码块加行号（行号只用于显示，复制时自动剔除）。
    var codeLineNumbers: Bool = false
    /// 是否自动折行（默认开启）。关闭后长行按原样显示、超出窗口的部分会被裁切。
    var lineWrap: Bool = true

    init(family: Family = .mono,
         lineSpacing: Double = 0,
         paragraphSpacing: Double = 0,
         firstLineIndent: Double = 0,
         headingNumbering: Bool = false,
         codeLineNumbers: Bool = false,
         lineWrap: Bool = true) {
        self.family = family
        self.lineSpacing = lineSpacing
        self.paragraphSpacing = paragraphSpacing
        self.firstLineIndent = firstLineIndent
        self.headingNumbering = headingNumbering
        self.codeLineNumbers = codeLineNumbers
        self.lineWrap = lineWrap
    }

    // MARK: - Codable（兼容旧存档：缺失字段取默认值，不因新增字段丢设置）

    private enum CodingKeys: String, CodingKey {
        case family, lineSpacing, paragraphSpacing, firstLineIndent, headingNumbering, codeLineNumbers, lineWrap
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        family = try container.decodeIfPresent(Family.self, forKey: .family) ?? .mono
        lineSpacing = try container.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 0
        paragraphSpacing = try container.decodeIfPresent(Double.self, forKey: .paragraphSpacing) ?? 0
        firstLineIndent = try container.decodeIfPresent(Double.self, forKey: .firstLineIndent) ?? 0
        headingNumbering = try container.decodeIfPresent(Bool.self, forKey: .headingNumbering) ?? false
        codeLineNumbers = try container.decodeIfPresent(Bool.self, forKey: .codeLineNumbers) ?? false
        lineWrap = try container.decodeIfPresent(Bool.self, forKey: .lineWrap) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(family, forKey: .family)
        try container.encode(lineSpacing, forKey: .lineSpacing)
        try container.encode(paragraphSpacing, forKey: .paragraphSpacing)
        try container.encode(firstLineIndent, forKey: .firstLineIndent)
        try container.encode(headingNumbering, forKey: .headingNumbering)
        try container.encode(codeLineNumbers, forKey: .codeLineNumbers)
        try container.encode(lineWrap, forKey: .lineWrap)
    }

    /// 预设模板。
    static func preset(_ name: Preset) -> Typography {
        switch name {
        case .standard:
            return Typography(family: .mono, lineSpacing: 0, paragraphSpacing: 0, firstLineIndent: 0)
        case .comfort:
            return Typography(family: .system, lineSpacing: 6, paragraphSpacing: 8, firstLineIndent: 0)
        case .academic:
            var value = Typography(family: .serif, lineSpacing: 8, paragraphSpacing: 2, firstLineIndent: 2)
            value.headingNumbering = true
            return value
        case .compact:
            return Typography(family: .system, lineSpacing: 0, paragraphSpacing: 0, firstLineIndent: 0)
        case .technical:
            return Typography(family: .mono, lineSpacing: 4, paragraphSpacing: 6, firstLineIndent: 0)
        case .handout:
            // 讲义：行距与段距都放大，便于投影/打印阅读
            return Typography(family: .system, lineSpacing: 10, paragraphSpacing: 14, firstLineIndent: 0)
        case .report:
            // 报告：编号 + 段距明显，偏正式
            var value = Typography(family: .system, lineSpacing: 7, paragraphSpacing: 10, firstLineIndent: 0)
            value.headingNumbering = true
            return value
        case .onePage:
            // 一页纸：最紧凑，尽量塞进一页
            return Typography(family: .system, lineSpacing: 1, paragraphSpacing: 2, firstLineIndent: 0)
        }
    }

    enum Preset: String, CaseIterable, Identifiable {
        case standard, comfort, academic, compact, technical, handout, report, onePage
        var id: String { rawValue }
        var title: String {
            switch self {
            case .standard: return "默认"
            case .comfort: return "舒适阅读"
            case .academic: return "学术"
            case .compact: return "紧凑"
            case .technical: return "技术"
            case .handout: return "讲义"
            case .report: return "报告"
            case .onePage: return "一页纸"
            }
        }
    }
}
