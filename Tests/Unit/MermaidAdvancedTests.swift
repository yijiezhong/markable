import AppKit
import Testing
@testable import Markable

/// 自研 Mermaid 高级图类型（zenuml / requirement / eventmodeling）的渲染回归：
/// 合法源码应产出尺寸合理的 `NSImage`（宽 ≤ 1200pt），非法/空源码应返回 nil（由调用方回退提示），
/// 且这三类已从 `unsupportedTypes` 移除、不再被 `unsupportedType(of:)` 命中。
@MainActor
@Suite("MermaidAdvanced")
struct MermaidAdvancedTests {
    /// 合法源码：应渲染出非 nil 且宽高都大于 0 的图片，宽度不超过 1200pt。
    private func expectRenderable(_ source: String, label: String) {
        guard let image = MermaidRenderer.image(forSource: source) else {
            Issue.record("\(label) 应渲染成功，实际返回 nil")
            return
        }
        #expect(image.size.width > 0, "\(label) 宽度应大于 0，实际 \(image.size.width)")
        #expect(image.size.height > 0, "\(label) 高度应大于 0，实际 \(image.size.height)")
        #expect(image.size.width <= 1200, "\(label) 宽度应不超过 1200pt，实际 \(image.size.width)")
    }

    // MARK: - zenuml

    @Test("zenuml：参与者 + 消息 + 自调用")
    func zenumlRenders() {
        let source = """
        zenuml
          用户 -> 网关: 下单
          网关.checkToken()
          网关 -> 用户: 已受理
        """
        expectRenderable(source, label: "zenuml")
    }

    @Test("zenuml：无空格写法与虚线箭头")
    func zenumlCompactSyntax() {
        let source = """
        zenuml
          A->B:请求
          B-->A:响应
          C => A: 通知
        """
        expectRenderable(source, label: "zenuml 紧凑写法")
    }

    @Test("zenuml：只有首行或没有可识别消息时返回 nil")
    func zenumlRejectsInvalid() {
        #expect(MermaidRenderer.image(forSource: "zenuml\n") == nil, "只有首行时应返回 nil")
        #expect(MermaidRenderer.image(forSource: "") == nil, "空源码应返回 nil")
        #expect(MermaidRenderer.image(forSource: "zenuml\n  无法识别的行\n") == nil,
                "没有可识别消息时应返回 nil")
    }

    // MARK: - requirement

    @Test("requirement：需求框 + 属性 + 关系箭头")
    func requirementRenders() {
        let source = """
        requirementDiagram

        requirement 登录 {
          id: 1
          text: 支持用户名密码登录
          risk: high
          verifymethod: test
        }

        requirement 审计 {
          id: 2
          text: 记录全部登录事件
        }

        element 网关 {
          type: simulation
        }

        登录 - satisfies -> 审计
        网关 - verifies -> 登录
        """
        expectRenderable(source, label: "requirementDiagram")
    }

    @Test("requirement：简化写法（无属性 + 单行块 + 首行 requirement）")
    func requirementSimplifiedSyntax() {
        let source = """
        requirement
          requirement 订单 {
            id: 1, text: 支持下单, risk: medium
          }
          requirement 库存
          订单 - derives -> 库存
        """
        expectRenderable(source, label: "requirement 简化写法")
    }

    @Test("requirement：只有首行或节点不足两个时返回 nil")
    func requirementRejectsInvalid() {
        #expect(MermaidRenderer.image(forSource: "requirementDiagram\n") == nil,
                "只有首行时应返回 nil")
        #expect(MermaidRenderer.image(forSource: "requirementDiagram\nrequirement 唯一 {\n  id: 1\n}\n") == nil,
                "只有一个节点时应返回 nil")
    }

    // MARK: - eventmodeling

    @Test("eventmodeling：命令→事件→视图链 + 显式声明")
    func eventModelingRenders() {
        let source = """
        eventmodeling
          下单 -> 订单已创建 -> 订单详情
          订单详情 => 发货
          command 支付
          event 已支付
          view 支付结果
        """
        expectRenderable(source, label: "eventmodeling")
    }

    @Test("tf：显式类型声明组成隐式链")
    func eventModelingTF() {
        let source = """
        tf
          command 提交
          event 已提交
          view 提交结果
        """
        expectRenderable(source, label: "tf")
    }

    @Test("eventmodeling：只有首行或没有可识别节点时返回 nil")
    func eventModelingRejectsInvalid() {
        #expect(MermaidRenderer.image(forSource: "eventmodeling\n") == nil, "只有首行时应返回 nil")
        #expect(MermaidRenderer.image(forSource: "tf\n") == nil, "tf 只有首行时应返回 nil")
        #expect(MermaidRenderer.image(forSource: "eventmodeling\n  无法识别的行\n") == nil,
                "没有可识别节点时应返回 nil")
    }

    // MARK: - 分派

    @Test("zenuml / requirement / eventmodeling 已从 unsupportedTypes 移除")
    func unsupportedTypeList() {
        #expect(MermaidRenderer.unsupportedType(of: "zenuml\n  A -> B") == nil,
                "zenuml 已支持，不应再被判定为不支持")
        #expect(MermaidRenderer.unsupportedType(of: "requirement\n") == nil)
        #expect(MermaidRenderer.unsupportedType(of: "requirementDiagram\n") == nil)
        #expect(MermaidRenderer.unsupportedType(of: "eventmodeling\n") == nil)
        #expect(MermaidRenderer.unsupportedType(of: "tf\n") == nil)
    }
}

@Suite("MermaidSource 主题解析")
struct MermaidThemeTests {
    @Test("解析 init 指令里的 theme（双引号 / 单引号 / 无引号）")
    func parsesTheme() {
        #expect(MermaidSource.theme(of: "%%{init: {\"theme\": \"forest\"}}%%\nflowchart TD\n A-->B") == .forest)
        #expect(MermaidSource.theme(of: "%%{init: {'theme': 'dark'}}%%\npie\n \"A\": 1") == .dark)
        #expect(MermaidSource.theme(of: "%%{init: {theme: neutral}}%%\nflowchart TD") == .neutral)
        #expect(MermaidSource.theme(of: "flowchart TD\n A-->B") == .default, "没有指令时应为默认")
        #expect(MermaidSource.theme(of: "%%{init: {\"theme\": \"unknown-value\"}}%%") == .default, "未知主题应回退默认")
    }

    @Test("themeVariables 中的 theme 不会被误取")
    func ignoresThemeVariables() {
        let source = "%%{init: {\"themeVariables\": {\"primaryColor\": \"#f00\"}}}%%\nflowchart TD"
        #expect(MermaidSource.theme(of: source) == .default)
    }

    @Test("渲染器转发解析结果")
    func rendererForwardsTheme() {
        #expect(MermaidRenderer.theme(of: "%%{init: {\"theme\": \"base\"}}%%\nflowchart TD") == .base)
    }
}
