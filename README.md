# Markable

纯本地的 macOS Markdown 阅读器（原生 TextKit 渲染，只读、不联网）。

> 2026-10-23 起作为独立仓库维护。

## 定位

- **只读阅读器**：打开 Markdown 即渲染，不编辑、不写回源文件（`isEditable = false`）。
- **纯本地**：不发起网络请求、不存储凭据；早期 AI 功能已于 2026-10-13 整体移除。
- **交付级 PDF 走本机 md2pdf 工具**（见下文「PDF 输出」一节）；内置导出已做 A4 分页（按内容块边界切页，超高代码块/表格按行拆页）。
- **外部改动自动刷新**：源文件变化后在 2 秒内自动重载并保持阅读位置；⌘R / 工具栏刷新按钮可强制重载（内容未变也重新渲染）。

## 技术栈

- SwiftUI（应用外壳 / 设置 / 侧栏）+ AppKit（窗口与多标签页管理）
- TextKit 2（`NSTextView`，`usingTextLayoutManager: true`，只读渲染）
- `swift-markdown`（解析）、`Vendor/swift-mermaid`（Mermaid 渲染）
- KaTeX + `WKWebView`（数学公式）、`PDFKit`（PDF 导出与盖章）

## 构建与运行

```bash
scripts/build.sh        # 编译：每次自动把 patch 版本号 +1
scripts/build.sh -c release
swift run               # 直接运行
swift test              # 测试
```

首次解析依赖需代理：

```bash
export HTTPS_PROXY=http://127.0.0.1:1087
swift package resolve
```

> SwiftPM 没有「构建前跑脚本」的钩子，所以裸 `swift build` 不会递增版本号；日常请用 `scripts/build.sh`（等价于 `swift build` + 版本递增）。

## 版本号（自动递增）

- **唯一来源**：仓库根的 `VERSION` 文件（`major.minor.patch`）。
- **每次编译**：`scripts/build.sh` 自动 patch +1（如 `1.0.2 → 1.0.3`）。
- **每次打包**：`scripts/make-app-bundle.sh` 自动 patch +1，并把版本写入 `Info.plist` 的 `CFBundleShortVersionString` / `CFBundleVersion`。
- **生成物**：`Sources/App/GeneratedVersion.swift`（`AppVersion.short` / `build` / `display`），供「关于」窗口显示。
- **手动控制**：

```bash
scripts/bump-version.sh                    # patch +1
scripts/bump-version.sh --minor            # 1.0.x → 1.1.0
scripts/bump-version.sh --major            # 1.x.y → 2.0.0
scripts/bump-version.sh --set 2.3.4        # 直接指定
scripts/bump-version.sh --print            # 只打印当前版本
```

「关于 Markable」会显示当前版本与构建号（例如 `版本 1.0.3 (202610232218)`）。

打包脚本支持 `--no-bump`（保留当前版本、只刷新构建号），供 CI 冒烟与本地验证使用：

```bash
scripts/make-app-bundle.sh --debug --no-bump --zip /tmp/dist
```

## 交付（默认流程）

**每次改动完成后默认运行 `scripts/release.sh`**（不要只 `swift build`）：

```bash
scripts/release.sh          # release 构建 → 打包 → 安装 → 设 .md 关联 → 打 zip
scripts/release.sh --debug  # 调试构建（更快），其余步骤相同
```

它依次完成：

1. 版本号 patch +1（`VERSION` → `GeneratedVersion.swift`）；
2. `swift build -c release`；
3. 生成 `dist/Markable.app` 与 `dist/Markable-<版本>.zip`；
4. 覆盖安装到 `/Applications/Markable.app`（不可写时退到 `~/Applications/Markable.app`）；
5. 重新注册 LaunchServices，并把 **`.md` 的默认打开程序指向刚安装的版本**；
6. 清理 `dist/` 旧包：只保留最近 5 个 `Markable-<版本>.zip`（`scripts/prune-dist.sh`）。

> `release.sh` 会自动清理旧的 `dist/*.zip`，只保留最近 5 个；手动整理用
> `scripts/prune-dist.sh --keep N [--dry-run]`（不加 `--yes` 只演练，不删除）。

> 因此 **Finder 双击 `.md` 打开的始终是最近一次 `scripts/release.sh` 安装的版本**。
> 只跑 `swift build` / `scripts/build.sh` 不会更新 `.app`，双击仍是旧版。

单独设置关联（不重新打包时）：

```bash
swift scripts/set-default-md.swift /Applications/Markable.app
```


打包成可发布的 `.app`（写入 URL scheme、图标、App Intents 元数据）：

```bash
scripts/make-app-bundle.sh --release --zip
```

## 使用

- **打开**：⌘O；快速打开 ⇧⌘O；最近打开；多标签页 ⌘N。
- **工具栏**（按场景与频率从左到右）：文件与导航（打开 / 快速打开 / 上·下标题）→ 查找 → 缩放组（缩小 / 实际大小 / 缩放至窗口 / 放大）→ 显示（主题 / 版式 / 纸张）→ 检查（体检）→ 导出与分享（PDF / HTML / 图片 / PDF 选项 / 批量 / 分享）。
- **字体**：系统 / **非衬线**（苹方）/ 衬线（宋体）/ 等宽；在「字号与排版 → 字体」或「设置 → 排版」切换。
- **代码字体**：苹果官方字体 + 字距补偿，中英文严格 2:1 等宽（非衬线 SF Mono + 苹方；衬线 Courier New + 宋体，随正文字体切换）；详见 `docs/FONT-STRATEGY.md`。
- **放大 / 缩小**：⌘+ / ⌘-（工具栏按钮同样可用）；范围 50%–300%。缩放只改变阅读显示，不改字号设置与导出结果。
- **缩放**（工具栏平铺按钮 / 「字号与排版」菜单，参考「预览」）：实际大小 ⌘0、缩放至窗口大小 ⌘9（按窗口宽度适配阅读密度）。
- **字号**：⌥⌘= / ⌥⌘- / ⌥⌘0，或在「设置 → 外观」调整 11–24；字号决定排版基准，会进入导出的 PDF。
- **自动折行**：默认开启（行宽跟随窗口，长段落/表格单元格自动折行）；可在「设置 → 排版 → 自动折行」或「字号与排版」菜单关掉。关闭后长行按原样显示，超出窗口的部分会被裁切。
- **侧栏**：大纲 / 任务 / 链接 / 文件。
- **导出**：PDF、HTML、逐页 PNG、文件夹批量导出。
- **设置**：主题（浅色 / 深色 / 跟随系统）、字号 11–24、纸张（A3 / A4 / A5 / Letter / Legal / flow）、页边距、页眉页脚、目录页、代码行号。
- **状态栏**：字数 / 句数 / 字符 / 阅读时长；文档体检（Lint）。
- **命令型 URL**：
  - 打开：`markable://open?path=%2Ftmp%2Fa.md`
  - 导出：`markable://export?path=/tmp/a.md&output=/tmp/a.pdf&format=pdf|html`

## PDF 输出（两种通道，按用途选）

| 通道 | 产物 | 适用 |
|---|---|---|
| **「导出 PDF」按钮（默认）** | 调用本机 Rust 版 `md2pdf`（≥ 1.3.0）：**A4 分页**、苹方简子集内嵌、目录书签、页码 | 交付给客户 / 领导 |
| 回退：内置导出 | 工具缺失或失败时自动回退：内置 **A4 分页**（`PDFPaginator` 按内容块边界切页）+ 标题书签 | 快速归档、阅读预览 |

**集成逻辑**：`导出 PDF…`（工具栏 / 菜单）→ 按 `MARKABLE_MD2PDF` → `~/.local/bin` → `/opt/homebrew/bin` → `/usr/local/bin` → `PATH` 依次探测（同一目录内 `md2pdf` 优先，`md2pdf-cn` 仅作旧入口兜底）→ 每个候选执行 `--version`，低于 1.3.0 或非 Rust 版（Python legacy）直接跳过 → 命中则调用；否则或调用失败时回退内置 `PDFExporter`，并在导出完成时提示实际使用的通道。

md2pdf 通道也可在命令行单独使用（本机唯一交付级 MD→PDF 入口）：

```bash
md2pdf <文件.md> --out <文件.pdf>        # 生成
pdf-gate <文件.pdf>                      # 版式门禁，必须通过
```

> 内置导出已是 **A4 分页**（`PDFPaginator` + `PDFPaginationPlanner`）：按内容块边界切页、页尾标题孤行推后、超高 `pre` 按行 / `table` 按 `tr` 拆页；图片由 `HtmlRenderer` 限高（`max-height` = 内容区高度 − 40pt）后整块推页，不会被拦腰切断，视频仍按页高硬切。交付级 PDF 仍优先走 md2pdf（版式与门禁更完整）。
>
> **两条通道的版式控制不同**：走 md2pdf 时，纸张 / 页边距 / 页眉页脚 / 目录页 / 盖章全部由 md2pdf 的 `style.typ` 决定。想用 Markable 自己的这些设置，在「PDF 选项」里勾选 **强制使用内置导出**（`app.forceBuiltinPDFExport`，持久化）——此时 `PDFDelivery` 跳过 md2pdf，走内置 A4 分页通道。
>
> **HTML 导出是单文件自包含**：本地图片内联为 `data:` URI（PDF 通道必需——WKWebView 的 about:blank 读不到 `file://`），因此 HTML 文件体积会随图片增长；换来离线可移植、不留外链。

## 目录结构

```
Sources/
├── App/           应用入口、菜单、文档场景、窗口/标签页管理、设置、帮助
├── Editor/        TextKit 渲染；LivePreview/（源→视图重建）；Syntax/（行内/块级语法、各类图表与公式）
├── Export/        HTML 渲染、PDF 导出/盖章/目录页、md2pdf 桥接、批量导出、导出 UI
├── IO/            文件读写与冲突提示、设置存储
├── Markdown/      领域类型、解析引擎、代码高亮、搜索、字数、Lint、交叉引用、WikiLink
├── UI/            侧栏面板（大纲/文件）
└── Resources/     KaTeX、内置帮助页
Tests/
├── Unit/          引擎、语法、渲染、导出、设置、性能
└── UI/            快照与集成测试
```

## 质量

- 静态检查：`scripts/lint.sh`（先 `brew install swiftlint swift-format`；默认**只报告**、不因历史告警判红，`--strict` 才在 error 时返回 1，`--fix` 自动修复且只作用于 `Sources/`、`Tests/`；工具缺失时跳过并返回 0）。`.swiftlint.yml` 已排除 `Vendor/` 第三方并校准阈值；2026-10-24 完成三处重构（PDFPaginator 函数、LivePreviewController / DocumentScene 类型体）后 **error 为 0**，`--strict` 通过。
- `swift test`：全绿（325 条用例 / 54 个套件 / 56 个测试文件，覆盖 Markdown 往返、渲染决策、表格真网格、PDF 分页（块边界避让 / 超高块按行拆页）/ 目录页码与书签 / 中文文本层归一化 / 盖章、HTML 导出、App Intents、设置持久化、1MB / 5MB 文档性能基线（5MB 块级扫描 0.57s）、TextKit 2 滚动定位、渲染快照、水平分隔线、导出图片内联（data URI / 远程拒绝 / 超限退化）、跨页表格重复表头与接缝美化、导出结构（表格真实 <table> / 任务复选框 / 脚注）、复制洁净度（隐藏标记剔除 / 表格 TSV / 图片 alt / Mermaid 与公式占位 / 标题编号剔除）、导出链接 scheme 过滤、以及技术债回归护栏：列表项目符号 / 引用整块背景与字符竖线（复制还原为 `>`、空行分段竖线完整） / 数学占位与局部替换 / 大文档渲染 / Mermaid 全部类型（含 zenuml 控制块 / requirement / eventmodeling / kanban / treemap / venn）/ 窗口标签决策）。
- 渲染样例：`samples/markdown-syntax-full.md` —— 覆盖 CommonMark + GFM + Markable 扩展的全部常见元素，每节带"期望"注释与文末核对清单，可直接用于人工/自动化回归。
- 架构评估、技术债处理记录与 ADR：`docs/ARCHITECTURE.md` §12、`docs/adr/`。

## 文档

- `docs/FONT-STRATEGY.md` —— 代码字体方案（官方字体 + 字距补偿，8–60pt 实测）
- `docs/ARCHITECTURE.md` —— 技术架构报告（分层、渲染管线、导出链路、约束与演进建议）
- `docs/adr/0001-textkit-2-evaluation.md` —— TextKit 2 迁移评估与决策（原「不迁移」结论已于 2026-10-24 废弃）
- `docs/adr/0002-textkit-2-migration.md` —— TextKit 2 迁移实施记录（表格 / 附件 / 引用竖线 / 查找栏 / 性能）
- `samples/markdown-syntax-full.md` —— Markdown 语法全集测试样例（645 行 / 22 节）
- `THIRD-PARTY-NOTICES.md` —— 第三方组件清单、锁定版本与完整许可文本

## 许可证

MIT，见 `LICENSE`。第三方组件（`Vendor/swift-mermaid`、`swift-markdown`、`swift-cmark`、KaTeX 等）遵循其各自许可，完整清单与文本见 `THIRD-PARTY-NOTICES.md`。

## 维护

- 架构与约束：`docs/ARCHITECTURE.md`
- 关键决策记录：`docs/adr/`
- 版本号规则：`x.y.z` 每位 0–9，`z` 满 9 进位 `y`、`y` 满 9 进位 `x`（见 `scripts/bump-version.sh`）
- 本地维护日志（不随仓库发布）：`HANDOVER.md`
