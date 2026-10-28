import Foundation

/// 本机 md2pdf 工具桥接：把 Markdown 源文件交给 **Rust 版 md2pdf** 导出。
///
/// 相比内置的 `PDFExporter`（WKWebView 渲染 + `PDFPaginator` 按内容块边界切 A4 页），
/// md2pdf 走 Rust + Typst 管道：**A4 分页**、苹方简子集内嵌、四级目录书签、页码，
/// 生成时内建版式门禁——适合交付给客户 / 领导。
///
/// 工具探测顺序：`MARKABLE_MD2PDF` → `~/.local/bin` → Homebrew → PATH；
/// 每个候选都校验 `--version`，**低于 `minimumVersion` 或非 Rust 版（旧 Python 版）会被跳过**，
/// 避免悄悄走回 legacy 管道。
enum Md2PdfBridge {
    enum BridgeError: LocalizedError {
        case toolMissing
        case failed(Int32)
        case emptyOutput

        var errorDescription: String? {
            switch self {
            case .toolMissing:
                return "未找到 Rust 版 md2pdf 工具（md2pdf ≥ \(Md2PdfBridge.minimumVersion)）"
            case .failed(let code):
                return "md2pdf 退出码 \(code)"
            case .emptyOutput:
                return "md2pdf 未生成 PDF（输出为空）"
            }
        }
    }

    /// 要求的最低 Rust 版 md2pdf 版本：1.3.0 起支持任务列表复选框、脚注、行内 HTML、数学。
    static let minimumVersion = "1.3.0"

    /// 最低版本解析结果（元组便于比较）。
    static let minimumParsedVersion: (Int, Int, Int) = {
        let parts = minimumVersion.split(separator: ".").compactMap { Int($0) }
        return (parts.isEmpty ? 0 : parts[0],
                parts.count > 1 ? parts[1] : 0,
                parts.count > 2 ? parts[2] : 0)
    }()

    /// 本机是否装了可用的 Rust 版 md2pdf。
    static var isAvailable: Bool { toolURL() != nil }

    /// 解析 `md2pdf` 可执行文件位置（GUI 应用的 PATH 通常不含 `~/.local/bin`，需显式探测）。
    ///
    /// 优先 Rust 主命令名 `md2pdf`，其次兼容旧入口名 `md2pdf-cn`；两者都指向同一个二进制时没有差别，
    /// 但旧机器上 `md2pdf-cn` 可能仍是 Python legacy 脚本——版本校验会把它排除。
    static func toolURL() -> URL? {
        for path in candidatePaths() {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            if isRustPipeline(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// 候选路径（按优先级去重）：MARKABLE_MD2PDF → ~/.local/bin → Homebrew → PATH。
    static func candidatePaths() -> [String] {
        var paths: [String] = []
        if let custom = ProcessInfo.processInfo.environment["MARKABLE_MD2PDF"], !custom.isEmpty {
            paths.append(custom)
        }
        let home = NSHomeDirectory()
        for name in ["md2pdf", "md2pdf-cn"] {
            paths.append("\(home)/.local/bin/\(name)")
            paths.append("/opt/homebrew/bin/\(name)")
            paths.append("/usr/local/bin/\(name)")
        }
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in pathEnv.split(separator: ":") {
            for name in ["md2pdf", "md2pdf-cn"] {
                paths.append("\(directory)/\(name)")
            }
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// 读取工具 `--version` 输出（同步；`--version` 极快）。
    static func versionOutput(atPath path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 解析 `md2pdf 1.3.0`（Rust 版输出）；Python legacy / 其他输出返回 nil。
    static func parseVersion(_ output: String) -> (Int, Int, Int)? {
        let line = output.split(separator: "\n").first.map(String.init) ?? output
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "md2pdf" else { return nil }
        let numbers = parts[1].split(separator: ".")
        guard numbers.count == 3,
              let major = Int(numbers[0]),
              let minor = Int(numbers[1]),
              let patch = Int(numbers[2]) else { return nil }
        return (major, minor, patch)
    }

    /// 版本是否达到最低要求。
    static func isValidVersion(_ version: (Int, Int, Int)) -> Bool {
        version >= minimumParsedVersion
    }

    /// 某路径是否为合格的最新 Rust 版管道。
    static func isRustPipeline(atPath path: String) -> Bool {
        guard let output = versionOutput(atPath: path),
              let version = parseVersion(output) else { return false }
        return isValidVersion(version)
    }

    /// 把 `markdown` 导出为 `pdf`。失败时由调用方决定是否回退内置导出。
    @discardableResult
    static func export(markdown: URL, to pdf: URL, title: String) async throws -> URL {
        guard let tool = toolURL() else { throw BridgeError.toolMissing }

        let process = Process()
        process.executableURL = tool
        process.arguments = [markdown.path, "--out", pdf.path, "--title", title]

        // Rust 版 md2pdf 自带渲染，不需要外部运行时；仍补 PATH，避免用户把
        // MARKABLE_MD2PDF 指向包装脚本时找不到它内部调用的命令。
        var environment = ProcessInfo.processInfo.environment
        let localBin = "\(NSHomeDirectory())/.local/bin"
        let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let basePath = (environment["PATH"].flatMap { $0.isEmpty ? nil : $0 }) ?? fallbackPath
        environment["PATH"] = basePath.contains(localBin) ? basePath : "\(localBin):\(basePath)"
        process.environment = environment

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { finished in
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: BridgeError.failed(finished.terminationStatus))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: pdf.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { throw BridgeError.emptyOutput }
        return pdf
    }
}
