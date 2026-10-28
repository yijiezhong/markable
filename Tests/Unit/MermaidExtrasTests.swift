import AppKit
import Testing
@testable import Markable

/// 自研 Mermaid 扩展图类型（kanban / treemap / venn）的渲染回归：
/// 合法源码应产出尺寸合理的 `NSImage`，非法/空源码应返回 nil（由调用方回退提示）。
@MainActor
@Suite("MermaidExtras")
struct MermaidExtrasTests {
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

    @Test("kanban：三列多卡片（含卡片元数据）")
    func kanbanRenders() {
        let source = """
        kanban
          todo[待办]
            t1[写解析器]
            t2[补测试] @{ assigned: 'kimi' }
          doing[进行中]
            [没有 ID 的卡片]
          done[已完成]
            t4[通过评审]
        """
        expectRenderable(source, label: "kanban")
    }

    @Test("kanban：没有列时返回 nil")
    func kanbanRejectsEmpty() {
        #expect(MermaidRenderer.image(forSource: "kanban\n") == nil, "只有首行时应返回 nil")
        #expect(MermaidRenderer.image(forSource: "") == nil, "空源码应返回 nil")
    }

    @Test("treemap：两级分组按数值分配面积")
    func treemapRenders() {
        let source = """
        treemap
          title 季度投入
          "研发"
            "解析器": 30
            "渲染器": 18
          "文档"
            "教程": 12
            "示例": 6
        """
        expectRenderable(source, label: "treemap")
    }

    @Test("treemap-beta：扁平叶子也支持")
    func treemapBetaRenders() {
        let source = """
        treemap-beta
          Root
            A: 30
            B: 70
        """
        expectRenderable(source, label: "treemap-beta")
    }

    @Test("treemap：没有任何正数值时返回 nil")
    func treemapRejectsEmpty() {
        #expect(MermaidRenderer.image(forSource: "treemap\n") == nil, "只有首行时应返回 nil")
        #expect(MermaidRenderer.image(forSource: "treemap\n  Root\n    A\n") == nil,
                "只有分组没有数值时应返回 nil")
    }

    @Test("venn：三集合 + 两两交集 + 三重交集")
    func vennRenders() {
        let source = """
        venn-beta
          title 技能分布
          "前端": 12
          "后端": 20
          "数据": 8
          "前端&后端": 5
          "前端&后端&数据": 2
        """
        expectRenderable(source, label: "venn-beta")
    }

    @Test("venn：两集合也支持")
    func vennTwoSets() {
        expectRenderable("venn\n  A: 10\n  B: 20\n", label: "venn 两集合")
    }

    @Test("venn：集合不足两个或无法解析时返回 nil")
    func vennRejectsInvalid() {
        #expect(MermaidRenderer.image(forSource: "venn\n") == nil, "只有首行时应返回 nil")
        #expect(MermaidRenderer.image(forSource: "venn\n  A: 10\n") == nil,
                "只有一个集合时应返回 nil")
        #expect(MermaidRenderer.image(forSource: "venn\n  A: x\n  B: y\n") == nil,
                "数值无法解析时应返回 nil")
        #expect(MermaidRenderer.image(forSource: "venn\n  A: 1\n  B: 2\n  C: 3\n  D: 4\n") == nil,
                "超过三个集合时应返回 nil")
    }

    @Test("kanban / treemap / venn 已从 unsupportedTypes 移除，zenuml 仍保留")
    func unsupportedTypeList() {
        #expect(MermaidRenderer.unsupportedType(of: "zenuml\n  A -> B") == nil,
                "zenuml 已由自研渲染器支持，不应再出现在 unsupportedTypes 中")
        #expect(MermaidRenderer.unsupportedType(of: "kanban\n  todo[待办]") == nil)
        #expect(MermaidRenderer.unsupportedType(of: "treemap\n  A: 1") == nil)
        #expect(MermaidRenderer.unsupportedType(of: "treemap-beta\n  A: 1") == nil)
        #expect(MermaidRenderer.unsupportedType(of: "venn\n  A: 1") == nil)
        #expect(MermaidRenderer.unsupportedType(of: "venn-beta\n  A: 1") == nil)
    }

    @Test("自研渲染器统一剔除 %%{init}%% 控制块")
    func customRenderersStripInitBlock() {
        // headType 统一走 MermaidSource.stripped（所有自研类型共用）
        let types = ["gantt", "timeline", "mindmap", "packet", "quadrantChart", "sankey", "xychart"]
        for type in types {
            let sample = "%%{init: {'theme':'dark'}}%%\n\(type)\n  x"
            #expect(MermaidRenderer.headType(of: sample).hasPrefix(type.lowercased()),
                    "\(type) 的控制块应被剔除")
        }
        // 实际渲染：gantt（duration-only，语法最稳）
        let gantt = "%%{init: {'theme':'dark'}}%%\ngantt\n  section A\n  任务: 3d"
        #expect(MermaidRenderer.image(forSource: gantt) != nil, "gantt 控制块剔除后应渲染成功")
    }
}
