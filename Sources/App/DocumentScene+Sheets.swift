import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import PDFKit

/// `DocumentScene` 的面板：快速打开、跨文件搜索、查找、文档体检、PDF 选项。
/// （自 `DocumentScene.swift` 机械拆分，逻辑未改。）
extension DocumentScene {
    // MARK: - 快速打开（⇧⌘O，模糊搜索当前目录）

    var quickOpenSheet: some View {
        let dir = document.path?.deletingLastPathComponent()
        let files: [URL] = {
            guard let dir else { return [] }
            let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            return all.filter { $0.pathExtension.lowercased() == "md" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }()
        let query = quickQuery.lowercased()
        let filtered = query.isEmpty ? files : files.filter { $0.lastPathComponent.lowercased().contains(query) }

        return VStack(alignment: .leading, spacing: 8) {
            Text("快速打开").font(.headline)
            TextField("搜索文件名…", text: $quickQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 380)
                .onSubmit { if let first = filtered.first { openFromQuick(first) } }
            List(filtered, id: \.self) { url in
                Button(url.lastPathComponent) { openFromQuick(url) }
                    .buttonStyle(.plain)
            }
            .frame(width: 380, height: 240)
            HStack {
                Spacer()
                Button("取消") { showQuickOpen = false }
            }
        }
        .padding(16)
    }

    private func openFromQuick(_ url: URL) {
        showQuickOpen = false
        // 与「打开…」一致：新文件开在新标签页，当前文档保留。
        DocumentWindowManager.shared.open(url)
    }

    // MARK: - 跨文件搜索（⇧⌘F）

    var searchSheet: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("跨文件搜索").font(.headline)
            HStack {
                TextField("要搜索的文本…", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .onSubmit { runSearch() }
                Button("搜索") { runSearch() }
            }
            List(searchResults, id: \.self) { line in
                Text(line).font(.system(size: 11, design: .monospaced))
            }
            .frame(width: 520, height: 260)
            HStack {
                Text("\(searchResults.count) 处匹配").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { showSearch = false }
            }
        }
        .padding(16)
    }

    private func runSearch() {
        guard let dir = document.path?.deletingLastPathComponent() else { searchResults = []; return }
        let needle = searchQuery.lowercased()
        guard !needle.isEmpty else { searchResults = []; return }

        var results: [String] = []
        let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "md" else { continue }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.lowercased().contains(needle) {
                results.append("\(url.lastPathComponent):\(index + 1)  \(line.trimmingCharacters(in: .whitespaces))")
                if results.count >= 200 { break }
            }
            if results.count >= 200 { break }
        }
        searchResults = results
    }

    // MARK: - 查找（正则 / 整词 / 大小写 + 结果列表）

    var findSheet: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("查找").font(.headline)
            HStack(spacing: 8) {
                TextField("要查找的文本…", text: $findQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit { runFind() }
                Toggle("正则", isOn: $app.findOptions.isRegex)
                Toggle("整词", isOn: $app.findOptions.wholeWord)
                Toggle("区分大小写", isOn: $app.findOptions.caseSensitive)
                Button("查找") { runFind() }
            }
            .fixedSize(horizontal: false, vertical: true)
            List(findMatches.indices, id: \.self) { index in
                let match = findMatches[index]
                Button {
                    scrollRequest = ScrollRequest(search: match.text)
                } label: {
                    HStack(spacing: 8) {
                        Text("第 \(match.line) 行")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .leading)
                        Text(match.preview)
                            .lineLimit(1)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(width: 560, height: 260)
            HStack {
                Text("\(findMatches.count) 处匹配").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { showFindSheet = false }
            }
        }
        .padding(16)
    }

    /// ⌥⌘G：用当前选中的文本作为查找内容。
    func findUsingSelection() {
        let text = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            findQuery = ""
            showFindSheet = true
            return
        }
        findQuery = text
        runFind()
        showFindSheet = true
    }

    /// ⌥⌘F：打开系统查找栏（NSTextView 的 Find Bar），作为自研查找的备用入口。
    /// TextKit 2 不支持 `NSTextFinder` 的系统查找栏（Find Bar）；
    /// 统一使用 Markable 自带的查找面板，保证 ⌥⌘F 与 ⌘F 行为一致。
    func showSystemFindBar() {
        findQuery = ""
        findMatches = []
        showFindSheet = true
    }



    /// ⌘G / ⇧⌘G：在查找结果间循环跳转（还没有结果时先打开查找面板）。
    func advanceFind(_ direction: Int) {
        guard !findMatches.isEmpty else {
            findQuery = ""
            showFindSheet = true
            return
        }
        findMatchIndex = DocumentSearch.nextIndex(current: findMatchIndex, count: findMatches.count, direction: direction)
        let match = findMatches[findMatchIndex]
        guard !match.text.isEmpty else { return }
        scrollRequest = ScrollRequest(search: match.text)
    }

    private func runFind() {
        findMatches = DocumentSearch.matches(in: document.content, query: findQuery, options: app.findOptions)
        findMatchIndex = 0
    }

    // MARK: - 文档体检面板

    var lintSheet: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("文档体检").font(.headline)
            if lintIssues.isEmpty {
                Text("未发现问题。").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(lintIssues.indices, id: \.self) { index in
                    let issue = lintIssues[index]
                    Button {
                        if !issue.preview.isEmpty {
                            scrollRequest = ScrollRequest(search: issue.preview)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text("第 \(issue.line) 行")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(width: 64, alignment: .leading)
                            Text(issue.message)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: 560, height: 280)
            }
            HStack {
                Text("共 \(lintIssues.count) 处").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { showLintSheet = false }
                    .fixedSize()
            }
        }
        .padding(16)
        // 空态时内容很少，若不给宽度，SwiftUI 会把 sheet 压窄、把「关闭」按钮压成省略号。
        .frame(width: lintIssues.isEmpty ? 380 : 620)
    }

    // MARK: - 页眉页脚（导出 PDF 用）

    var headerFooterSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PDF 选项").font(.headline)
            Text("页眉/页脚留空即不显示。占位符：{title} 文档名 · {page} 页码 · {total} 总页数")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(Md2PdfBridge.isAvailable
                 ? "已安装 md2pdf：默认走 md2pdf 通道，版式由 md2pdf 决定，下面的页眉/页脚、目录页与纸张设置不生效。勾选下方「强制内置导出」后这些设置才会生效（内置通道为 A4 分页）。"
                 : "未安装 md2pdf，导出走内置通道（A4 分页），下面的设置全部生效。")
                .font(.footnote)
                .foregroundStyle(Md2PdfBridge.isAvailable ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("强制使用内置导出（让纸张 / 页边距 / 页眉页脚 / 目录页生效）",
                   isOn: $app.forceBuiltinPDFExport)
                .disabled(!Md2PdfBridge.isAvailable)
            TextField("页眉，例如：{title}", text: $app.pdfHeader)
                .textFieldStyle(.roundedBorder)
                .frame(width: 420)
            TextField("页脚，例如：第 {page} / {total} 页", text: $app.pdfFooter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 420)
            Toggle("在最前插入目录页", isOn: $app.includeTOC)
            HStack {
                Spacer()
                Button("完成") { showHeaderSheet = false }
            }
        }
        .padding(16)
    }

}
