import AppKit
import Foundation
import UniformTypeIdentifiers

// 用法：swift scripts/set-default-md.swift <Markable.app 路径>
//
// 把 .md（net.daringfireball.markdown）的默认打开程序设为指定 .app，
// 让 Finder 双击 .md 打开的就是这份最新安装的版本；最后打印并校验当前默认值。
//
// 退出码：0 成功且已指向目标；1 参数/设置失败；3 设置后仍未指向目标。

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write("用法：set-default-md.swift <Markable.app 路径>\n".data(using: .utf8)!)
    exit(1)
}

let appURL = URL(fileURLWithPath: arguments[1])
guard FileManager.default.fileExists(atPath: appURL.path) else {
    FileHandle.standardError.write("找不到应用：\(appURL.path)\n".data(using: .utf8)!)
    exit(1)
}

guard let type = UTType(filenameExtension: "md") else {
    FileHandle.standardError.write("无法解析 .md 的 UTType\n".data(using: .utf8)!)
    exit(1)
}

NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type)

let current = NSWorkspace.shared.urlForApplication(toOpen: type)
print("md 默认打开程序 → \(current?.path ?? "nil")")

if current?.standardizedFileURL.path == appURL.standardizedFileURL.path {
    exit(0)
} else {
    exit(3)
}
