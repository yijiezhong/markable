import Testing
import Foundation
@testable import Markable

/// 任务聚合：GFM / Craft 两种方言、跳过代码围栏、完成计数。
@Suite("TaskAggregator")
struct TaskAggregatorTests {
    @Test("GFM 任务项与完成状态")
    func gfm() {
        let text = """
        - [ ] 未完成
        - [x] 已完成
        * [X] 大写也算完成
        """
        let tasks = TaskAggregator.tasks(in: text)
        #expect(tasks.count == 3)
        #expect(tasks[0] == .init(text: "未完成", done: false, line: 1))
        #expect(tasks[1] == .init(text: "已完成", done: true, line: 2))
        #expect(tasks[2] == .init(text: "大写也算完成", done: true, line: 3))
    }

    @Test("Craft 行首方括号方言")
    func craft() {
        let text = """
        [] 待办
        [x] 办完
        """
        let tasks = TaskAggregator.tasks(in: text)
        #expect(tasks.count == 2)
        #expect(tasks[0].done == false)
        #expect(tasks[1].done == true)
    }

    @Test("跳过代码围栏内容")
    func skipFence() {
        let text = """
        ```md
        - [ ] 这是示例，不算
        ```
        - [ ] 真实任务
        """
        let tasks = TaskAggregator.tasks(in: text)
        #expect(tasks.count == 1)
        #expect(tasks[0].text == "真实任务")
    }

    @Test("普通列表不算任务")
    func plainList() {
        #expect(TaskAggregator.tasks(in: "- 只是列表项\n").isEmpty)
        #expect(TaskAggregator.tasks(in: "1. 有序列表\n").isEmpty)
    }
}
