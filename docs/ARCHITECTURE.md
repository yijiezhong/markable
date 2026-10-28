# Markable 技术架构报告

版本：1.0.34

日期：2026-10-24

代码基线：`main` 发布为 1.0.34

适用：维护者、交接评审、后续架构演进

## 1. 定位与硬约束

Markable 是一个**纯本地、只读**的 macOS Markdown 阅读器。三条产品级硬约束决定了后面所有架构选择：

- **只读**：`NSTextView.isEditable = false`，不写回源文件；`DocumentStore.save` 保留在协议里但界面不暴露编辑入口；
- **不联网**：全部依赖在本地（KaTeX 资源、Vendor/swift-mermaid）；无网络请求、无凭据存储；
- **原生渲染**：SwiftUI 外壳 + AppKit 文本栈 + TextKit 2 排版，全程不经过 WebView 渲染正文（数学公式是唯一的 WebView 例外）。

## 2. 技术栈与依赖

| 层 | 选型 | 版本 / 约束 |
|---|---|---|
| 语言 / 平台 | Swift 5.10，macOS 14+ | `Package.swift`：`platforms: [.macOS(.v14)]` |
| 应用外壳 | SwiftUI（场景、工具栏、侧栏、设置、关于） | 不声明 `WindowGroup`，窗口由 AppKit 手动管理（见 §4） |
| 文本渲染 | AppKit `NSTextView` + **TextKit 2** | `NSTextView(usingTextLayoutManager: true)` |
| Markdown 解析 | `swift-markdown` 0.9.0 | 经 `swift-cmark` 0.9.0 解析（CommonMark + GFM） |
| Mermaid | `Vendor/swift-mermaid` 0.3.0 | 纯 Swift、无 WebView；随仓库携带 |
| 数学公式 | KaTeX 0.16.11 + `WKWebView` | 本地资源（596 KB），离屏渲染成 `NSImage` |
| PDF | `WKWebView.pdf()` + `PDFKit` + `PDFPaginator` | 内置导出按内容块边界切 A4 页（`PDFPaginationPlanner`） |
| 测试 | `swift-testing`（`@Suite` / `@Test`） | 56 个测试文件、325 条 `@Test`、54 个 `@Suite` |
| 打包 | 自研 `scripts/`（zsh） | 版本号、App bundle、LaunchServices、zip |

## 3. 代码结构与规模

```
Sources/                     80 文件 / 15,423 行
├── App/         18 文件 / 2,861 行   应用外壳：场景、窗口/标签、菜单命令、设置、关于、URL 命令、App Intents
├── Editor/      33 文件 / 8,010 行   正文渲染：LivePreviewController（核心）、Syntax（块/行内语法与图表）、Typography、CodeTypography
├── Export/      13 文件 / 2,961 行   导出：HTML、PDF 分页/后处理、批量、md2pdf 桥接
├── IO/           3 文件 /   225 行   文件读写与冲突、设置持久化
├── Markdown/    12 文件 / 1,204 行   领域模型与文本服务：解析、高亮、搜索、Lint、任务、交叉引用、字数
├── UI/           1 文件 /   162 行   侧栏面板（大纲 / 任务 / 反向链接 / 文件）
└── Resources/                        KaTeX（596 KB）、内置 Help（16 KB）
Tests/                       55 文件 / 5,366 行 / 321 条用例（53 套件）
Vendor/swift-mermaid/        68 文件 / 13,811 行
```

依赖方向是一条直线，没有环：

```
App → Editor → Markdown → Domain
 │       │
 │       └→ Export（HtmlRenderer 复用 Markdown 的 AST 渲染）
 └→ IO（DocumentStore / SettingsStore）
```

## 4. 运行时架构

### 4.1 应用与窗口

`MarkableApp` 刻意**不声明 `Window` / `WindowGroup` 场景**，只声明 `Settings` 场景与三组 `.commands`。原因是 SwiftUI 场景窗口和手动 `NSWindow` 同处一个标签组时会争所有权，曾导致 `objc_release` 野指针崩溃。因此：

- 所有文档窗口都由 `DocumentWindowManager`（单例）创建；
- **一个窗口、每个文档一个标签页**（标签在窗口上方），统一使用 `tabbingIdentifier("markable.document")` 才能被 `addTabbedWindow` 合并；
- 打开文件时按「已打开 → 切标签；有空标签 → 复用；否则 → 新标签页」处理。该规则抽在 `WindowTabPolicy`（纯函数），由 `WindowTabPolicyTests` 覆盖，窗口管理器只负责执行决策；
- `activeWindowID` 按 key → main → 第一个的顺序解析，菜单命令只作用于当前标签。

每个标签页的内容是一个 `DocumentScene`（SwiftUI View），持有自己的文档、选择、查找、体检、导出状态；跨标签共享的状态放在 `AppState`（主题、字号、缩放、侧栏、纸张、页边距、排版参数），由 `SettingsStore` 落 `UserDefaults`。

### 4.2 消息通道

| 通道 | 用途 | 特点 |
|---|---|---|
| `AppCommandBus` | 菜单 / 工具栏 → 场景（40+ 命令：文件、查找、视图、导航） | `ObservableObject`，按窗口定向投递 |
| `URLCommandBus` | `markable://open` / `export` / `settings` 命令型 URL | 队列投递，界面未就绪时暂存 |
| `NotificationCenter` | 窗口管理器 ↔ 场景（打开、已显示文档） | 两个自定义通知名 |
| App Intents | 快捷指令：打开文档、导出、文档统计 | 薄封装 `DocumentExportService` |

### 4.3 侧栏与文本视图

- 侧栏四面板：`OutlinePanel`（可跳转大纲）、`TasksPanel`（聚合任务进度）、`BacklinksPanel`（出链/反链）、`FilesPanel`（同目录 `.md`）；
- `ReaderTextView` 继承 `NSTextView`，接管 PageDown / PageUp / 空格 / Shift+空格 为整屏翻页；
- `MarkdownTextView`（`NSViewRepresentable`）负责创建滚动视图、同步宽度、应用滚动请求。

## 5. 数据流（打开 → 解析 → 渲染 → 导出）

```
打开来源：Finder 双击 / 命令行参数 / markable:// / 最近打开 / 文件面板
        ↓
DocumentWindowManager.open(url)
        ↓（同文件切标签 / 空标签复用 / 新标签）
DocumentScene（每标签一个）
        ↓
FileDocumentStore.open → Document(content, modifiedAt)
        ↓
MarkdownTextView ← LivePreviewController.apply(source:)
        ├─ 阶段 A：属性（源文本长度不变）
        │    BlockSyntax + InlineSyntax → [StyledRange] → apply(kind:)
        └─ 阶段 B：字符替换（改变长度 → 从后往前应用）
        ↓
NSTextStorage / TextKit 2 排版（视口驱动） → 滚动视图
        ↓（导出时另一条链路）
HtmlRenderer / PDFExporter / Md2PdfBridge / BatchExporter
```

## 6. 渲染管线（核心）

### 6.1 两步渲染与坐标约定

`LivePreviewController.apply(to:source:...)`（1,269 行的渲染核心）分两阶段：

1. **属性阶段**：基于源文本打属性，**不改变字符数**——隐藏标记、设字体/颜色、标题字号、行内代码、引用灰底等；
2. **替换阶段**：收集 `[(range, NSAttributedString)]`，**按 range 从后往前**统一应用，因为替换会改变长度（图片附件、Mermaid、数学、表格整表重建、TOC、脚注区、`<br>` 等），倒序应用保证前面的 range 不失效，并带 boundary 检查防重叠。

关键约定（也是改渲染时的「红线」）：

- **隐藏标记 = 0.1pt 字体 + 前景色 clear**，字符不删除。测试断言要查字体/颜色，不能查字符串（`HANDOVER.md` §7 已写明）；
- 渲染恒从**源文本**重建，不做「在已渲染视图上二次渲染」；
- 只读模式全文渲染；`LivePreview.plan` 的「光标段落保持源码态」逻辑属于编辑模式，阅读器不走。

### 6.2 语法识别层

| 层 | 实现 | 输出 |
|---|---|---|
| 块级 | `BlockSyntax.ranges(in:)` | front matter、围栏/缩进代码块、ATX/Setext 标题、任务列表、引用、列表、表格、callout、`<!-- ai: -->`、脚注定义、链接定义行、HTML 注释 |
| 行内 | `InlineSyntax.ranges(in:)` | 16 条规则 + 图片（alt/path/title）+ 粗斜体合并 + 转义过滤 |
| 结果模型 | `StyledRange { range, kind, content, payload }` | `range` 含标记、`content` 是内容、`payload` 是语言/路径等 |

两者都是**纯函数**，不依赖 AppKit（只依赖 Foundation / NSString），因此性能测试可以直接对 1MB 文本跑。

### 6.3 替换项清单（改变长度的部分）

| 替换项 | 触发语法 | 实现要点 |
|---|---|---|
| 图片附件 | `![alt](path)` | 本地路径相对 `baseDirectory`；等比缩到 640pt；附件字符是 `U+FFFC`（否则 TextKit 不渲染）；远程/缺失给占位 |
| Mermaid | ` ```mermaid ` | 纯 Swift 渲染成 `NSImage` 附件；不支持的类型/渲染失败时插入提示行并保留源码 |
| 数学 | `$…$` / `$$…$$` | 异步：命中缓存直接附件；未命中先放占位 `⋯`，渲染完成后重绘替换 |
| 任务标记 | `- [ ]` / `- [x]` | `[ ]` → ☐、`[x]` → ☑（列表短横线保留，属已知降级） |
| 硬换行 | 行尾两空格 / `\` | 替换为 `\n` |
| `<br>` | `<br>` / `<br/>` / `<br />` | 替换为 `U+2028`；**排除表格范围与反引号代码段**（后者为本次修复） |
| 元数据插值 | `[%key]` | 从 front matter 取值，未定义保留原文 |
| 分页线 | 单独一行 `===` / `+++` | 替换为 24 个 `─`（12pt 三级文字色） |
| 转义 | `\*` 等 | 去掉反斜杠；排除表格（由整表重建处理）与代码/注释/链接定义 |
| HTML 实体 | `&amp;` / `&#169;` | 解码；未知实体保留 |
| 自动链接 | `<https://…>`、裸 URL | 转可点击链接；排除代码/表格/注释/已有链接 |
| 水平线 | `---` / `***` / `___` | 生成灰色细线 `NSImage` 附件；排除 front matter 与代码块 |
| 目录 | `{{TOC}}` / `[TOC]` / `[toc]` | 生成层级目录，条目带 `markableTOC` 标记（大纲跳转跳过，避免跳到目录） |
| 脚注区 | `[^x]: …` | 定义行移到文末「脚注」区；引用改为上标编号并可点击 |
| 软换行接排 | 段落内单换行 | `SoftWrap` 计算连接方式（CJK 之间不插空格） |
| 表格 | 以竖线分隔的表头 / 分隔行 | 整表重建为 `NSTextTable` 真网格（见 §6.4） |
| 列表项目符号 | 设置开启时：无序列表行 | `-` / `*` / `+` → `•`；任务列表隐藏 `- ` 前缀 |
| 引用竖线 | 引用块每行行首 `>` | 原地替换为字符 `│`（`tertiaryLabelColor` + `makeBlockquoteStyle()`）；不插入附件、不自绘（灰底由 `NSTextBlock` 字符背景提供） |
| 引用内围栏 | 引用前缀 + 三反引号 | 剥离前缀后配对识别：围栏行隐藏（只盖住前缀之后的字符，竖线与灰底保留），围栏之间按 `.code` 等宽 + 灰底渲染；未闭合围栏不处理 |

### 6.4 表格：NSTextTable 真网格

表格不是「隐藏 `|` 后加粗」，而是把整表替换成 **`NSTextTable` + `NSTextTableBlock`**：

- `fixedLayoutAlgorithm`，列宽先按内容测量再按比例分配到可用宽度（内容多的列更宽）；
- 边框 0.5pt `separatorColor`、内边距 6pt、`collapsesBorders`；
- 表头加粗、列对齐取自分隔行（`:---` / `:---:` / `---:`）；
- 单元格内保留行内样式（粗体、行内代码、链接、删除线、高亮），`\|` 转义为正文字面竖线。

这也是 TextKit 2 下仍能真正画出网格线的方案（`NSTextTable` 仍可用）。

### 6.4.1 表格在导出侧的表达

阅读视图的表格是 `NSTextTable` 真网格；**HTML / 内置 PDF 导出**走 `HtmlRenderer`，现在会输出
真正的 `<table><thead><tr><th>…<tbody><tr><td>…`（列对齐来自 `Table.columnAlignments`，保留
`colspan`/`rowspan`）。此前 `Table` 没有分支，单元格文本会连成一串（`名称数量甲1乙2`）。
任务列表的 `ListItem.checkbox` 映射为禁用的 `<input type="checkbox">`；脚注因 swift-markdown
没有对应节点，由 `HtmlRenderer.extractFootnotes` 先摘出定义行、正文 `[^n]` 渲染为 `<sup>`，
文末追加 `.footnotes` 小节。

### 6.4.2 复制净化（`CopyFormatted`）

复制（⌘C / 右键 / 拖拽 / 服务）统一经 `CopyFormatted.cleanedSelection`：

1. 删除 `.markableHidden`（所有 0.1pt + 透明的语法标记）与 `.markableCopySkip`（代码行号）；
2. 把带 `.markableQuoteBar` 的 `│` 等长还原为 `>`；
3. 图片附件（`.markableImageAlt`）替换为 `[图片: alt]`，其余附件占位符删除；
4. 表格单元格（`.markableTableCell`）按行重排为 TSV（列 `\t`、行 `\n`），与相邻正文之间补空行；
5. 剥离内部属性后写剪贴板（纯文本 + 现代/旧式 RTF 两套类型名）。

这样复制只得到可见内容：标题不带 `# `、粗体不带 `**`、表格可粘回 Excel。

### 6.5 代码字体：官方字体 + 字距补偿

`CodeTypography` 不内嵌字体（Apple EULA 限制），用「等宽西文 + 中文全角 + 逐字 kern」组合出严格 2:1：

| 正文族 | 西文 | 中文 | kern 系数 | 8pt 实测 |
|---|---|---|---|---|
| 非衬线 | SF Mono（`SFMono-Regular`） | PingFang SC | 0.2363 × 字号 | 1.89pt |
| 衬线 | Courier New（`CourierNewPSMT`） | Songti SC | 0.2002 × 字号 | 1.60pt |

8–60pt、各字重实测误差 0.0000pt（详见 `docs/FONT-STRATEGY.md`）；样例 §9.6 用 8 类场景覆盖纯西文、纯中文、中英混排、缩进层级、全角标点、注释、列对齐、行内代码。

### 6.6 数学：KaTeX + 离屏 WKWebView

`MathRenderer`（单例）：

- 一个**隐藏的 borderless NSWindow** 挂 `WKWebView`（无 window 时 WebKit 不渲染）；
- 加载本地 `katex.min.js/css`，`async` 渲染成 `NSImage`；
- 缓存 + `inFlight` 去重，避免同公式重复排队；
- 渲染完成回调触发视图重绘（首屏可能短暂显示 `$…$` 源码，属已知异步行为）；
- 资源缺失或失败时回退源码。

### 6.7 Mermaid：纯 Swift，无 WebView

`MermaidRenderer` 按源码首行分派：

- **Vendor 原生支持**：flowchart/graph、sequenceDiagram、pie、classDiagram、stateDiagram、erDiagram、gitGraph、journey、architecture-beta；
- **Markable 扩展渲染器**（Vendor 标注 planned 的类型）：gantt、mindmap、timeline、xychart、quadrantchart、sankey、block，另加 packet；
- 结果缓存为 `NSImage`，失败回退为代码块占位。

### 6.8 锚点、内链、交叉引用与脚注

统一走自定义 scheme `markable-anchor://scroll?text=<目标文本>`，由 `MarkdownTextView` 解析并滚动：

- 大纲 / 目录跳转；
- `[[wiki]]` 内链 → 打开同目录文件；
- `[文字][标签]` 交叉引用 → 滚动到带该标签的标题；
- 脚注上标 → 滚动到文末脚注定义。

## 7. 文本服务层（Markdown/）

| 模块 | 职责 | 备注 |
|---|---|---|
| `MarkdownEngine` | 解析 / 序列化 / 往返保真 / 大纲 / 剥离 front matter | 基于 swift-markdown（cmark-gfm） |
| `CodeHighlighter` | 5 类 token（注释/字符串/数字/关键字/类型）+ 多语言共用扫描器 | 输出 UTF-16 `NSRange`，不上 HTML |
| `Typography` | 字体族（系统/非衬线/衬线/等宽）、行距、段距、首行缩进、标题编号、代码行号、自动折行 | 渲染与导出共用；等宽优先 Noto Sans Mono CJK SC |
| `DocumentSearch` | 大小写 / 整词 / 正则；`nextIndex` 循环 | 供 ⌘G / ⇧⌘G |
| `Lint` | 14 类确定性体检规则 | 在**屏蔽代码围栏后的等长文本**上检查，行号与原文一致 |
| `TaskAggregator` | 汇总 GFM 与 Craft 风格任务，跳过围栏 | 侧栏任务面板 |
| `CrossReference` / `WikiLinkIndex` | 交叉引用与 wiki 链接索引 | 侧栏反向链接 |
| `HeadingNumbering` / `ParagraphIndex` / `TextStats` / `SoftWrap` / `FrontMatter` | 编号、段索引、字数、接排、front matter | 纯逻辑 |

## 8. 导出链路

```
                    ┌─ HTML ── HtmlRenderer（AST → 内联 CSS 的 HTML；图片内联 data URI；表格/复选框/脚注）
Markdown 源 ────────┤
                    ├─ PDF  ── PDFDelivery（统一入口）
                    │            ├─ md2pdf 可用 → Md2PdfBridge → md2pdf（Rust 版 ≥ 1.3.0；A4 分页 / 苹方子集 / 书签 / 页码 / pdf-gate）
                    │            └─ 缺失或失败 → PDFPaginator（A4 分页 + 块边界避让）→ PDFKit
                    │                  ├─ 内容块边界规划页切点（标题孤行推后）+ 标题锚点 → 页索引
                    │                  ├─ WKPDFConfiguration.rect 逐页截取 + CGPDFContext 合成 A4
                    │                  ├─ PDFTOC：可选目录页（按文本搜标题页，近似页码）
                    │                  ├─ PDFStamper：逐页重画 + Core Text 烧页眉页脚
                    │                  └─ 重建 PDFDocument 再写盘（否则书签丢失）
                    ├─ PNG ── HTML → PDF → 逐页 thumbnail（page-001.png…）
                    └─ 批量 ── BatchExporter（递归目录，PDF/HTML/PNG，失败不中断；PDF 同样走 PDFDelivery）
```

关键取舍：

- **PDF 走统一入口 `PDFDelivery`**：菜单、`markable://export`、App Intents、批量导出同一策略——本机有 `md2pdf` 时产出 A4 交付件，缺失或失败回退内置 `PDFPaginator`；设置里的 **强制使用内置导出**（`AppState.forceBuiltinPDFExport`）会让 `PDFDelivery` 跳过 md2pdf，从而让纸张 / 页边距 / 页眉页脚 / 目录页设置真正生效；
- **图片自包含**：`HtmlRenderer` 把本地图片读入后内联成 `data:` URI（相对路径以 Markdown 文件所在目录为基准）。原因：`WKWebView.loadHTMLString` 的 `about:blank` 页面读不到 `file://` 资源（传 `baseURL` 目录同样被 WebKit 拒绝），不内联的话 PDF 里只剩 alt 文字。远程 `http(s)`、源文本里的 `data:`、未知 scheme 一律不输出 `src`（保持「不联网」）；单图超过 8MB 或读不到时退化为 alt。代价是 HTML 文件变大，收益是「导出的 HTML 离线可移植、PDF 有图」；
- **内置分页已按内容块边界避让**：页切点取完整块底边、页尾标题推后；单个超高块按内部切点拆页（代码块按行、表格按 `tr`）；图片经 `img { max-height }`（内容区高 − 40pt）限制后整块推页、不会被切断，视频与外部超高 HTML 块仍按页高硬切；采集失败回退等分；标题锚点 + 页偏移直接给出目录页码与书签目标页，中文标题不再依赖 PDF 文本层匹配（`PDFTextNormalizer` 仍作为回退与第三方 PDF 的归一化工具）；
- **书签持久化**：WKWebView 产出的 PDF 直接挂 `outlineRoot` 再写会丢书签，必须先重装页面到新 `PDFDocument`；
- **页眉页脚是烧进去的**：`PDFStamper` 用 Core Graphics 重画每页、Core Text 绘制文字，不依赖批注显示，保留原文本层；
- **目录页码是近似的**：按标题文本在正文页中查找，查不到只列标题不显示页码；
- **导出服务层**：`DocumentExportService` 是 App Intents 的薄封装，便于测试；
- **md2pdf 探测顺序**：`MARKABLE_MD2PDF` 环境变量 → `~/.local/bin` → `/opt/homebrew/bin` → `/usr/local/bin` → `PATH`（GUI 应用的 PATH 通常不含 `~/.local/bin`）；同一目录内主命令 `md2pdf` 优先、旧入口 `md2pdf-cn` 仅兜底，每个候选都执行 `--version`，低于 1.3.0 或非 Rust 版（Python legacy）直接跳过。

## 9. 文件、设置与合规

- **文件**：`DocumentStore` 协议 + `FileDocumentStore`（UTF-8 只读打开、原子写、`mtime` 冲突检测）；冲突时**不写入**，返回 `SaveOutcome.conflict`；
- **设置**：`SettingsStore` 全部落 `UserDefaults`（窗口状态、最近文件、主题、侧栏、页眉页脚、TOC、字号、缩放、纸张、页边距、排版参数），不存凭据；
- **合规**：`THIRD-PARTY-NOTICES.md` 列 6 个组件与完整许可文本；`scripts/make-app-bundle.sh` 把 `LICENSE` 与 `THIRD-PARTY-NOTICES.md` 复制进 `Contents/Resources/`；
- **隐私**：无网络请求、无账号、无遥测。

## 10. 测试与质量保障

| 维度 | 现状 |
|---|---|
| 用例规模 | 55 文件、5,366 行、321 条 `@Test`、53 个 `@Suite` |
| 覆盖重点 | 语法边界（`MarkdownEdgeCase`）、表格（`TableExtras` / `TableRendering` / `TOCAndTableWidth`）、图片（`ImageSyntax` / `ImageRenderer`）、代码字体（`CodeFont`）、水平线（`HorizontalRule`）、渲染快照（`Snapshot` / `SettingsSnapshot`）、TextKit 2 滚动（`TextKit2Scrolling`）、导出（`HtmlRenderer` / `PDFPaginator` / `PDFPaginator 按块边界分页` / `PDFPaginator 超高块内部切点` / `PDFTOC` / `PDFStamper` / `PDFTextNormalizer` / `PDFHeadingMapping` / `Md2PdfBridge` / `BatchExporter` / `ExportConfig`）、文件冲突（`DocumentStore 冲突`）、搜索 / Lint / 任务 / 交叉引用、性能（`Performance`）、**回归护栏**（`InlineCodeAndQuote` / `DebtFixes` / `WindowTabPolicy` / `MermaidExtras` / `MermaidAdvanced` / `MermaidControlFlow` / `ChunkedRender`） |
| 快照测试 | 离屏渲染成 PNG；默认输出 `.build/snapshots`（可用 `MARKABLE_SNAPSHOT_DIR` 覆盖）；真实文档输入用 `MARKABLE_SNAPSHOT_FILE` |
| 性能门禁 | 1MB 语法扫描 < 2s、大纲 < 2s（实测 0.3–0.6s，高负载约 1.1s）；**不再因系统繁忙跳过断言**，只打印负载 |
| CI | `.github/workflows/ci.yml`：`macos-14` 上版本守卫（构建前后 `VERSION` 不变）+ `swift build` + `swift test` + **打包冒烟**（`--no-bump`，校验 zip 内许可、资源与 Info.plist 版本） |
| 定向原则 | 渲染改动优先跑相关套件（`HANDOVER.md` §7 列了渲染相关套件清单） |

## 11. 构建与发布

| 环节 | 脚本 | 说明 |
|---|---|---|
| 版本号 | `VERSION`（唯一来源）+ `scripts/bump-version.sh` | 支持 `--minor` / `--major` / `--set` |
| 日常编译 | `scripts/build.sh` | 先 patch +1 再 `swift build`（SwiftPM 没有构建前钩子） |
| App 打包 | `scripts/make-app-bundle.sh` | 写 `Info.plist`（URL scheme、版本）、生成图标、复制资源与许可、`Metadata.appintents`、LaunchServices 注册；`--no-bump` 保留版本只刷新构建号（供 CI 冒烟） |
| 交付 | `scripts/release.sh` | release 构建 → 安装 `/Applications` → 关联 `.md` → `dist/Markable-<版本>.zip` |
| 产物 | `dist/`（git 忽略） | 只保留最近 5 个 `Markable-<版本>.zip`（`scripts/prune-dist.sh`；`release.sh` 结束自动清理，可 `--keep N` 调整、不加 `--yes` 只演练） |

## 12. 架构评估

### 12.1 优点

1. **分层干净**：`Markdown`（纯逻辑）→ `Editor`（渲染）→ `App`（外壳）/ `Export`（输出）/ `IO`（文件），依赖单向；
2. **语法层可测**：`BlockSyntax` / `InlineSyntax` / `SoftWrap` / `Lint` 都是纯函数，321 条用例能覆盖到边界而不启动 GUI；
3. **渲染约定集中**：「先属性、后替换、倒序应用、隐藏标记 0.1pt」四条规则写在代码注释与 HANDOVER 里，新增语法只需在替换清单登记；
4. **表格与字体有工程深度**：TextKit 真网格、2:1 等宽字距补偿都有实测与文档；
5. **导出有回退**：交付级 PDF 走外部 Rust 版 `md2pdf`（≥ 1.3.0），失败回退内置；批量导出单点失败不中断；
6. **合规完整**：依赖锁定、许可全文、二进制分发携带声明。

### 12.2 技术债与清理结果（2026-10-24，多轮；详见 HANDOVER §12–§15）

| 项 | 处理结果 |
|---|---|
| TextKit 2 + 全文重排 | **已迁移**（2026-10-24）：正文渲染改为 `ReaderTextView(usingTextLayoutManager: true)`；表格/附件/隐藏标记验证正常，滚动定位改 `NSTextLayoutManager`；引用竖线最终改为行首 `>` 原地替换为 `│` 字符（附件方案在 TextKit 2 下位置偏移，已弃用）；系统查找栏降级为自带查找面板（详见 [ADR 0002](adr/0002-textkit-2-migration.md)） |
| 单窗口多标签手动 `NSWindow` | **已加固**：打开决策抽成 `WindowTabPolicy` 纯函数 + 4 条测试；仍保留手动窗口设计（规避 SwiftUI 场景窗口与手动窗口的标签组冲突） |
| 列表标记保留 | **已修复（可配置）**：设置「无序列表显示项目符号」开启后 `-` → `•`、任务列表隐藏短横线；默认仍保留标记 |
| 引用灰底是字符背景 | **已修复（整块）**：`paragraphStyle.textBlocks` + `NSTextBlock` 100% 宽背景，段落缩进 10pt；竖线已改为行首 `>` 原地替换为 `│` 字符（附件方案弃用）；替换阶段统一继承原段落样式，避免 TextKit 归一化清空整段样式 |
| 内置 PDF 单页长图 | **已修复（A4 分页）**：新增 `PDFPaginator` + `PDFPaginationPlanner`，按内容块边界规划页切点（页尾标题孤行推后、超高 `pre` 按行 / `table` 按 `tr` 拆页），逐页 `WKPDFConfiguration.rect` 截取并画到 A4 页面，文本层完整；图片由 `HtmlRenderer` 的 `img { max-height }`（内容区高 − 40pt）限制后整块推页、不会被切断，视频仍按页高硬切；交付级仍建议 md2pdf |
| 数学异步渲染 | **已修复**：未命中缓存时先渲染占位 `⋯`，完成后**局部替换**为公式附件；渲染失败保留占位 |
| Mermaid 覆盖面 | **已全覆盖**：自研 14 类 + Vendor 9 类；`unsupportedTypes` 已清空，zenuml / requirement / eventmodeling / kanban / treemap / venn 均有渲染器；`%%{init}%%` 与 `%%` 注释在分派与各渲染器解析层剔除（容忍但不解析主题） |
| 快照测试路径 | **已修复**：`SnapshotSupport` 默认输出 `.build/snapshots`，支持 `MARKABLE_SNAPSHOT_DIR` 覆盖 |
| 版本每次编译递增 | **已修复**：`make-app-bundle.sh --no-bump`（保留版本、只刷新构建号）；CI 增加版本守卫与打包冒烟 |

### 12.3 演进项处理状态（2026-10-24，收官）

| 项 | 状态 |
|---|---|
| 增量渲染 | **已落地**：语法扫描缓存 + 渲染结果缓存 + 数学局部替换；TextKit 2 下改为在独立 `NSMutableAttributedString` 上构建、末尾单次 `setAttributedString` 写回（分块让出已禁用），配合大纲后台解析缓存，1MB 文档窗口出现 1.7s（`HANDOVER.md` §19 实测） |
| TextKit 2 / 视口化 | **已迁移**（2026-10-24）：[ADR 0001](adr/0001-textkit-2-evaluation.md) 的「不迁移」结论已被推翻，实施记录见 [ADR 0002](adr/0002-textkit-2-migration.md) 与 `HANDOVER.md` §18；`NSTextTable` / 附件 / `NSTextBlock` 在 TextKit 2 下正常，滚动查询与布局失效改 `NSTextLayoutManager`；真正的「只重建可见区」增量渲染尚未实现 |
| A4 分页避让 | **已完成**：内容块边界切页 + 页尾标题推后 + 超高块内部切点（代码按行、表格按 `tr`）；图片经 `img { max-height }` 限制在内容区高度内后整块推页，视频与外部超高 HTML 块仍按页高硬切 |
| Mermaid 图类型 | **已全覆盖**：自研 14 类 + Vendor 9 类；zenuml 支持 `title` / `@Actor` / `if-else` / `loop` / `alt` / `opt` / `par` / `return`；`%%{init}%%` 与 `%%` 注释在分派与各渲染器解析层均被剔除（统一走 `MermaidSource.stripped`，容忍但不解析主题） |
| 中文文本层 | **已修复**：`PDFTextNormalizer`（714 条 1:1 映射）+ 标题锚点映射；目录页码与书签不再依赖字面文本匹配 |

已知限制（非技术债，均已在代码注释/样例登记）：

1. 内置分页对视频与外部传入的超高 HTML 块按页高硬切（Markdown 图片已限高，不会被切断）；跨页代码块不重复 `pre` 背景，表格 `thead` 不逐页重复；
2. Mermaid 的 `%%{init}%%` 只做容忍（不解析主题）；zenuml 控制块不支持更深嵌套的额外缩进；
3. TextKit 2 已迁移（布局按需、非连续），但渲染仍是全量 `apply` + 缓存；「只重建可见区」的增量方案尚未实现。

## 附录 A：模块 → 文件对照

| 模块 | 文件 |
|---|---|
| 渲染核心 | `Editor/LivePreview/LivePreviewController.swift`、`LivePreviewPlan.swift`、`MarkdownTextView.swift` |
| 语法 | `Editor/Syntax/BlockSyntax.swift`、`InlineSyntax.swift`、`StyledRange.swift`、`FrontMatter.swift`、`CJKAdjust.swift` |
| 图表 | `MathRenderer`、`MermaidRenderer`、`MermaidSource`、`KanbanRenderer`、`TreemapRenderer`、`VennRenderer`、`ZenUMLRenderer`、`RequirementRenderer`、`EventModelingRenderer`、`GanttRenderer`、`MindmapRenderer`、`TimelineRenderer`、`XychartRenderer`、`QuadrantRenderer`、`SankeyRenderer`、`PacketRenderer`、`BlockRenderer` |
| 排版 | `Editor/Typography.swift`、`CodeTypography.swift` |
| 导出 | `Export/HtmlRenderer.swift`、`PDFExporter.swift`、`PDFPaginator.swift`、`PDFTextNormalizer.swift`、`PDFTOC.swift`、`PDFStamper.swift`、`PDFDelivery.swift`、`Md2PdfBridge.swift`、`BatchExporter.swift`、`DocumentExportService.swift`、`ExportConfig.swift`、`PageSetup.swift`、`ExportUI.swift` |
| 外壳 | `App/MarkableApp.swift`、`DocumentWindowManager.swift`、`WindowTabPolicy.swift`、`DocumentScene.swift`、`AppState.swift`、`AppCommand.swift`、`URLCommand.swift`、`AppIntents.swift`、`SettingsView.swift` |
| 文件/设置 | `IO/DocumentStore.swift`、`SettingsStore.swift`、`DocumentStoreUI.swift` |

## 附录 B：渲染管线的四条红线（改渲染前必读）

1. 隐藏标记用 **0.1pt 字体 + 透明色**，不删除字符；测试查属性，不查字符串；
2. 替换项**从后往前**批量应用，range 重叠必须跳过；
3. 渲染恒从**源文本**重建，不在渲染结果上二次渲染；
4. 代码字体走 `CodeTypography`，不要直接设 `monospacedSystemFont`。
