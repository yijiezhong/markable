import AppKit
import Testing
@testable import Markable

/// Mermaid 配置指令（`%%{init: ...}%%`）/ 注释过滤，以及 zenuml 控制块的回归。
///
/// 说明：`MermaidRenderer` 按**首行**分派图类型（本轮不允许修改该文件），
/// 因此「`%%{init}%%` 位于整个代码块最前面」时会在分派层被拦住；
/// 这里直接调用各自研渲染器验证「源码预处理 + 渲染」链路，
/// 另用「指令位于类型行之后」的用例覆盖 `MermaidRenderer` 端到端。
@MainActor
@Suite("MermaidControlFlow")
struct MermaidControlFlowTests {
    /// 断言渲染出非 nil 且宽高都大于 0 的图片。
    private func expectRenderable(_ image: NSImage?, label: String) {
        guard let image else {
            Issue.record("\(label) 应渲染成功，实际返回 nil")
            return
        }
        #expect(image.size.width > 0, "\(label) 宽度应大于 0，实际 \(image.size.width)")
        #expect(image.size.height > 0, "\(label) 高度应大于 0，实际 \(image.size.height)")
    }

    // MARK: - MermaidSource 预处理

    @Test("MermaidSource：单行 init 指令与注释行被剔除")
    func stripsInlineDirectiveAndComments() {
        let source = """
        zenuml
        %%{init: {"theme": "dark"}}%%
        %% 这是一行注释
          A -> B: 请求
        """
        let cleaned = MermaidSource.stripped(source)
        #expect(cleaned.contains("A -> B: 请求"), "正文应保留")
        #expect(!cleaned.contains("%%{init"), "配置指令应被剔除")
        #expect(!cleaned.contains("这是一行注释"), "注释行应被剔除")
        #expect(cleaned.split(separator: "\n").count == 2, "剔除后应只剩类型行与正文")
    }

    @Test("MermaidSource：跨行 init 指令整段剔除")
    func stripsMultilineDirective() {
        let source = """
        zenuml
        %%{init: {
          "theme": "dark",
          "themeVariables": {"fontFamily": "PingFang SC"}
        }}%%
        %% 注释
          A -> B: 请求
        """
        let cleaned = MermaidSource.stripped(source)
        #expect(cleaned.contains("A -> B: 请求"))
        #expect(!cleaned.contains("themeVariables"), "跨行指令的中间行也应被剔除")
        #expect(!cleaned.contains("%%"))
    }

    @Test("MermaidSource：firstDirective 返回首个 init 指令内容")
    func exposesFirstDirective() {
        let source = """
        %%{init: {"theme": "dark"}}%%
        zenuml
        %%{init: {"theme": "light"}}%%
          A -> B: x
        """
        #expect(MermaidSource.firstDirective(source) == "init: {\"theme\": \"dark\"}",
                "应返回首个 init 指令的括号内内容")
        #expect(MermaidSource.firstDirective("zenuml\n  A -> B: x") == nil,
                "没有 init 指令时应返回 nil")
    }

    // MARK: - zenuml 配置容忍

    @Test("zenuml：前置 init 指令不影响渲染")
    func zenumlAcceptsLeadingDirective() {
        let source = """
        %%{init: {"theme":"dark"}}%%
        zenuml
          用户 -> 网关: 下单
          网关 -> 用户: 已受理
        """
        expectRenderable(ZenUMLRenderer.image(forSource: source), label: "zenuml + init")
    }

    @Test("zenuml：注释行被忽略且不改变布局")
    func zenumlIgnoresComments() {
        let plain = """
        zenuml
          A -> B: 请求
          B -> A: 响应
        """
        let commented = """
        zenuml
          %% 这段是注释
          A -> B: 请求
          %%{init: {"theme":"dark"}}%%
          %% 另一行注释
          B -> A: 响应
        """
        guard let plainImage = ZenUMLRenderer.image(forSource: plain),
              let commentedImage = ZenUMLRenderer.image(forSource: commented) else {
            Issue.record("两种写法都应渲染成功")
            return
        }
        expectRenderable(commentedImage, label: "zenuml + 注释")
        #expect(plainImage.size == commentedImage.size,
                "注释/指令行被剔除后，尺寸应与原始正文一致")
        #expect(MermaidSource.stripped(commented).split(separator: "\n").count == 3)
    }

    // MARK: - zenuml 控制块

    @Test("zenuml：if/else 控制块渲染分组矩形")
    func zenumlIfElseBlock() {
        let blocked = """
        zenuml
          title 登录流程
          @Actor 用户
          @Boundary 网关
          用户 -> 网关: 提交账号
          if (账号有效) {
            网关 -> 用户: 登录成功
          } else {
            网关 -> 用户: 提示错误
          }
          return 登录结果
        """
        let linear = """
        zenuml
          用户 -> 网关: 提交账号
          网关 -> 用户: 登录成功
          网关 -> 用户: 提示错误
        """
        guard let blockedImage = ZenUMLRenderer.image(forSource: blocked),
              let linearImage = ZenUMLRenderer.image(forSource: linear) else {
            Issue.record("if/else 与等价的直线消息都应渲染成功")
            return
        }
        expectRenderable(blockedImage, label: "zenuml if/else")
        #expect(blockedImage.size.height > linearImage.size.height,
                "控制块需要额外标签空间，高度应大于纯消息版本")
    }

    @Test("zenuml：loop / opt / par 与一层嵌套")
    func zenumlLoopsAndNesting() {
        let source = """
        zenuml
          @Actor 用户
          @Actor 服务
          用户 -> 服务: 轮询
          loop (每 5 秒) {
            opt (有更新) {
              服务 -> 用户: 推送
            }
            par {
              服务.refresh()
            }
          }
          alt (超时) {
            服务 -> 用户: 失败
          } else {
            服务 -> 用户: 成功
          }
        """
        expectRenderable(ZenUMLRenderer.image(forSource: source), label: "zenuml 嵌套控制块")
    }

    @Test("zenuml：未闭合控制块视为语法错误并返回 nil")
    func zenumlRejectsUnclosedBlock() {
        let source = """
        zenuml
          if (条件) {
            A -> B: 消息
        """
        #expect(ZenUMLRenderer.image(forSource: source) == nil, "未闭合的块应返回 nil")
        #expect(ZenUMLRenderer.image(forSource: "zenuml\n}\n  A -> B: 消息\n") == nil,
                "多余的闭合花括号应返回 nil")
    }

    @Test("zenuml：单行块与 return 均可解析")
    func zenumlSingleLineBlockAndReturn() {
        let source = """
        zenuml
          A -> B: 查询
          if (缓存命中) { B -> A: 直接返回 }
          return 结果
        """
        expectRenderable(ZenUMLRenderer.image(forSource: source), label: "zenuml 单行块")
    }

    // MARK: - 其他自研渲染器的配置容忍

    @Test("requirement：带 init 指令仍渲染")
    func requirementAcceptsDirective() {
        let source = """
        %%{init: {"theme":"dark"}}%%
        requirementDiagram
        requirement 登录 {
          id: 1
          text: 支持用户名密码登录
        }
        requirement 审计 {
          id: 2
          text: 记录登录事件
        }
        %% 注释行
        登录 - satisfies -> 审计
        """
        expectRenderable(RequirementRenderer.image(forSource: source), label: "requirement + init")
    }

    @Test("eventmodeling：带 init 指令仍渲染")
    func eventModelingAcceptsDirective() {
        let source = """
        %%{init: {"theme":"dark"}}%%
        eventmodeling
          下单 -> 订单已创建 -> 订单详情
          %% 注释行
          订单详情 => 发货
        """
        expectRenderable(EventModelingRenderer.image(forSource: source), label: "eventmodeling + init")
    }

    @Test("kanban / treemap / venn：带 init 指令仍渲染")
    func extraRenderersAcceptDirective() {
        let kanban = """
        %%{init: {"theme":"dark"}}%%
        kanban
          todo[待办]
            t1[写解析器]
          doing[进行中]
            t2[补测试]
        """
        let treemap = """
        %%{init: {"theme":"dark"}}%%
        treemap
          "研发"
            "解析器": 30
            "渲染器": 18
        """
        let venn = """
        %%{init: {"theme":"dark"}}%%
        venn
          "前端": 12
          "后端": 20
          "前端&后端": 5
        """
        expectRenderable(KanbanRenderer.image(forSource: kanban), label: "kanban + init")
        expectRenderable(TreemapRenderer.image(forSource: treemap), label: "treemap + init")
        expectRenderable(VennRenderer.image(forSource: venn), label: "venn + init")
    }

    // MARK: - MermaidRenderer 端到端

    @Test("MermaidRenderer：类型行之后的 init 指令不影响端到端渲染")
    func mermaidRendererToleratesDirectiveAfterTypeLine() {
        let source = """
        zenuml
        %%{init: {"theme":"dark"}}%%
          用户 -> 网关: 下单
          网关 -> 用户: 已受理
        """
        expectRenderable(MermaidRenderer.image(forSource: source), label: "端到端 zenuml + init")

        let requirement = """
        requirementDiagram
        %%{init: {"theme":"dark"}}%%
        requirement 甲 {
          id: 1
        }
        requirement 乙 {
          id: 2
        }
        甲 - satisfies -> 乙
        """
        expectRenderable(MermaidRenderer.image(forSource: requirement), label: "端到端 requirement + init")
    }
}
