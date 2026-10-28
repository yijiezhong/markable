import Testing
@testable import Markable

/// 骨架冒烟测试：确保包结构可编译、测试目标可运行。
/// 真正的领域测试在 T011+ 落地。
@Test func packageSmoke() {
    #expect(true)
}
