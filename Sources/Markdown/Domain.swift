import Foundation

/// 领域实体：文档（唯一持久化实体）。字段与校验规则见 data-model.md。
struct Document: Equatable {
    /// 本地文件路径；nil = 未保存的新文档。
    var path: URL?
    /// 当前 Markdown 文本。
    var content: String
    /// 上次保存时的内容快照。
    var savedContent: String
    /// 外部最后修改时间（用于冲突检测）。
    var externalModifiedAt: Date?

    /// 是否有未保存修改：`content != savedContent`。
    var isDirty: Bool { content != savedContent }

    init(path: URL? = nil, content: String = "", savedContent: String = "", externalModifiedAt: Date? = nil) {
        self.path = path
        self.content = content
        self.savedContent = savedContent
        self.externalModifiedAt = externalModifiedAt
    }

    /// 打开后的文档：内容即已保存内容。
    init(openedAt path: URL, content: String, modifiedAt: Date?) {
        self.init(path: path, content: content, savedContent: content, externalModifiedAt: modifiedAt)
    }
}
