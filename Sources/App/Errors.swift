import Foundation

/// 文档 IO 错误。
enum DocumentError: LocalizedError, Equatable {
    case notFound(URL)
    case notUTF8(URL)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let url): "找不到文件：\(url.lastPathComponent)"
        case .notUTF8(let url): "文件不是有效的 UTF-8 文本：\(url.lastPathComponent)"
        case .io(let message): "文件操作失败：\(message)"
        }
    }
}

/// 导出错误。
enum ExportError: LocalizedError, Equatable {
    case renderFailed
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .renderFailed: "渲染文档失败"
        case .writeFailed(let detail): "写出文件失败：\(detail)"
        }
    }
}
