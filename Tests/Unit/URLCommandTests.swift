import Testing
import Foundation
@testable import Markable

/// 命令型 URL 解析。
@Suite("URLCommand")
struct URLCommandTests {
    private func parse(_ string: String) -> URLCommand? {
        guard let url = URL(string: string) else { return nil }
        return URLCommand.parse(url)
    }

    @Test("open：host 作 action + path 参数")
    func open() {
        let command = parse("markable://open?path=%2Ftmp%2Fa.md")
        #expect(command?.action == .open)
        #expect(command?.path == "/tmp/a.md")
    }

    @Test("export：output 与 format")
    func export() {
        let command = parse("markable://export?path=/tmp/a.md&output=/tmp/a.pdf&format=PDF")
        #expect(command?.action == .export)
        #expect(command?.output == "/tmp/a.pdf")
        #expect(command?.format == "pdf")
    }

    @Test("settings：打开设置窗口")
    func settings() {
        #expect(parse("markable://settings")?.action == .settings)
    }

    @Test("action 也可放在查询参数")
    func actionInQuery() {
        #expect(parse("markable://?action=open&path=/tmp/a.md")?.action == .open)
    }

    @Test("非 markable scheme 返回 nil")
    func wrongScheme() {
        #expect(parse("https://example.com") == nil)
    }

    @Test("未知 action 返回 nil")
    func unknownAction() {
        #expect(parse("markable://frobnicate") == nil)
    }

    @Test("fileURL 展开 ~")
    func tilde() {
        #expect(URLCommand.fileURL("~/x.md").path.hasPrefix("/"))
    }
}
