import Testing
@testable import Markable

@Suite("Zoom")
struct ZoomTests {
    @Test("放大与缩小按 1.1 倍步进")
    func steppedZoomMovesInBothDirections() {
        let up = AppState.steppedZoom(from: 1.0, direction: 1)
        let down = AppState.steppedZoom(from: 1.0, direction: -1)
        #expect(up > 1.0)
        #expect(down < 1.0)
        #expect(abs(up - 1.1) < 0.0001)
        #expect(abs(down - 1.0 / 1.1) < 0.0001)
    }

    @Test("缩放不越过上下限")
    func steppedZoomClampsAtBounds() {
        #expect(AppState.steppedZoom(from: 3.0, direction: 1) == 3.0)
        #expect(AppState.steppedZoom(from: 0.5, direction: -1) == 0.5)
        var value = 1.0
        for _ in 0..<100 { value = AppState.steppedZoom(from: value, direction: 1) }
        #expect(value == AppState.zoomRange.upperBound)
        for _ in 0..<100 { value = AppState.steppedZoom(from: value, direction: -1) }
        #expect(value == AppState.zoomRange.lowerBound)
    }

    @Test("方向为 0 时只收敛到范围内")
    func zeroDirectionNormalizes() {
        #expect(AppState.steppedZoom(from: 1.5, direction: 0) == 1.5)
        #expect(AppState.steppedZoom(from: 10.0, direction: 0) == AppState.zoomRange.upperBound)
        #expect(AppState.steppedZoom(from: 0.1, direction: 0) == AppState.zoomRange.lowerBound)
    }

    @Test("缩放至窗口：按 800pt 参考宽计算并收敛")
    func fitZoomUsesReferenceWidth() {
        #expect(AppState.fitZoom(forWidth: 800) == 1.0)
        #expect(AppState.fitZoom(forWidth: 1600) == 2.0)
        #expect(AppState.fitZoom(forWidth: 400) == AppState.zoomRange.lowerBound)
        #expect(AppState.fitZoom(forWidth: 5000) == AppState.zoomRange.upperBound)
    }
}
