# 参与贡献

感谢你愿意改进 Markable。这是一个 macOS 原生 Markdown 阅读器（SwiftUI + AppKit + TextKit 2），
只读、离线、不修改源文件——这三条是设计底线，请勿提交违反它们的改动。

## 环境

- macOS 14+
- Xcode 15+ 工具链（Swift 5.10+）
- 首次构建需要能访问 SwiftPM 依赖（`swift-markdown`、`swift-cmark`）

```bash
swift build
swift test
scripts/lint.sh          # 可选：先 brew install swiftlint swift-format
```

## 提交前

1. `swift build` 与 `swift test` 必须通过；
2. 新增/修改行为要带测试（`Tests/Unit/`，swift-testing 风格）；
3. 静态检查 error 为 0（`scripts/lint.sh --strict`）；
4. 不要提交 `dist/`、`.build/`、`.DS_Store`（`.gitignore` 已覆盖）。

## 约定

- **渲染两阶段**：属性阶段不改变文本长度；替换阶段必须倒序应用并检查边界。
  隐藏的 Markdown 标记用「0.1pt 字体 + 透明色」隐藏，**不要删除字符**（测试会断言字体/颜色）。
- 用户可见文案与代码注释用中文；标识符用英文。
- 一次提交只做一件事，提交信息写清「改了什么、为什么」。

## 报告问题

请用 Issue 模板，附上：macOS 版本、Markable 版本（关于窗口）、复现步骤、期望与实际结果；
涉及渲染问题时附最小 Markdown 片段与截图。
