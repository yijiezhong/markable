import SwiftUI

/// 侧栏面板（T028）：大纲（可跳转）与文件列表。
struct OutlinePanel: View {
    /// 由父视图异步算好后传入（大文档不在 body 里解析全文）。
    let items: [OutlineItem]
    var numbered: Bool = false
    var onSelect: (OutlineItem) -> Void

    private var numbers: [String] {
        numbered ? HeadingNumbering.numbers(levels: items.map(\.level)) : []
    }

    var body: some View {
        List(items.indices, id: \.self) { index in
            let item = items[index]
            Button {
                onSelect(item)
            } label: {
                HStack(spacing: 6) {
                    Text(String(repeating: "  ", count: max(0, item.level - 1)))
                    if index < numbers.count {
                        Text(numbers[index])
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text(item.title)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
    }
}

/// 文件列表面板（简化：展示同目录下的 .md 文件；不做文件树编辑）。
struct FilesPanel: View {
    let directory: URL?
    var onOpen: (URL) -> Void

    private var markdownFiles: [URL] {
        guard let directory else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    var body: some View {
        List(markdownFiles, id: \.self) { url in
            Button(url.lastPathComponent) { onOpen(url) }
                .buttonStyle(.plain)
        }
    }
}
