# ADR 0002：TextKit 2 迁移实施

状态：**已实施（2026-10-24；取代 [ADR 0001](0001-textkit-2-evaluation.md) 的「不迁移」结论）**

日期：2026-10-24

决策人：维护者（Lead）

关联：[ADR 0001](0001-textkit-2-evaluation.md)、`docs/ARCHITECTURE.md` §12.2 / §12.3、`HANDOVER.md` §18–§19

## 背景

ADR 0001 依据「`NSTextTable` / 附件 / `NSTextBlock` 依赖 + 3–5 人日成本 + 无明确收益」，
给出「不迁移 TextKit 2」的结论，并改用缓存 + 分块让出来覆盖当前文档规模。

2026-10-24 维护者要求推翻该结论并完成迁移。实际结果是：原评估中的主要阻碍（表格、附件）
没有出现，迁移顺带解决了 1MB 大文档的打开性能问题。

## 决策

正文渲染切到 **TextKit 2**：`MarkdownTextView` 创建 `ReaderTextView(usingTextLayoutManager: true)`。

迁移范围内不改变产品约束：仍是只读（`isEditable = false`）、不联网、数学公式仍走唯一的
`WKWebView` 例外。

## 实施内容

| 项 | 方案 |
|---|---|
| 视图 | `MarkdownTextView` → `ReaderTextView(usingTextLayoutManager: true)` |
| 布局查询 | `NSTextLayoutManager.textLayoutFragment(for:)` + `ensureLayout(for:)`，替代 `NSLayoutManager.glyphRange/boundingRect/characterIndex`（`ScrollViewBox.scrollToCharacter` / `visibleTopCharacterIndex`） |
| 布局失效 | `NSTextLayoutManager.invalidateLayout(for:)` 替代 `invalidateLayout(forCharacterRange:)` |
| 表格 | `NSTextTable` + `NSTextTableBlock` 在 TextKit 2 下正常绘制（列宽 / 网格线 / 单元格内联样式），`TableRendering` / `TableExtras` 全过 |
| 引用灰底 | `NSParagraphStyle.textBlocks` + `NSTextBlock` 正常 |
| 引用竖线 | 改为行首 `>` 原地替换为字符 `│`（见下节） |
| 附件 | 图片 / 数学 / Mermaid / 水平线附件正常；`U+FFFC` 占位与 `bounds` 语义不变 |
| 隐藏标记 | 0.1pt 字体 + 透明色正常 |
| 查找栏 | 降级为自带查找面板（见下节） |

## 踩坑记录

### 引用竖线：四个方案、两次失败

| 方案 | 结果 |
|---|---|
| `NSTextBlock` 左边框 | 多行引用被压成一行，不可用 |
| 逐行插入竖线 `NSTextAttachment` | 不崩溃，但 TextKit 2 下位置有偏移，已弃用 |
| `NSTextLayoutFragment` 子类 + `NSTextLayoutManagerDelegate` 重写 `draw` | 触发 `NSWindow` 布局死循环（`more Layout Window passes than views`），启动即崩溃 |
| `ReaderTextView.drawBackground` 枚举引用段落 fragment 绘制 | 不崩溃；但去掉逐行替换后，引用两行被软换行合并成一行（逐行替换本身是保留换行的必要环节） |
| **最终：行首 `>` 原地替换为字符 `│`** | `collectQuoteBarReplacements`：长度不变、位置与行高由文本行自然决定，两行引用竖线连续；`tertiaryLabelColor` + `makeBlockquoteStyle()`；不插入附件、不自绘 |

因此「引用竖线」在生产路径上**不是附件**，而是字符替换；`quoteBarAttachment()` 已无调用方。

### 系统查找栏

TextKit 2 不支持 `NSTextFinder` 的 Find Bar：`⌥⌘F`（原「使用系统查找栏」）统一降级到
Markable 自带查找面板（与 `⌘F` 同一入口），菜单文案改为「使用查找面板…」。

### 1MB 大文档性能（`HANDOVER.md` §19 实测 58.8s → 1.7s）

| 问题 | 修复 |
|---|---|
| `OutlinePanel` 在 body 里每次求值都解析全文（6912 标题 × 1MB，主线程） | 大纲改由 `DocumentScene` 的 `.task(id: document.content)` 后台解析并缓存（300ms 防抖），面板只读缓存 |
| 替换阶段数千次 `replaceCharacters` 在大文档上 O(n²) | 从后往前筛出有效替换后一次切片重建（保持 boundary 语义） |
| `apply` 直接改 `textView.textStorage`，TextKit 2 每次变更触发内容枚举 / 布局 | 在独立 `NSMutableAttributedString` 上构建，最后单次 `setAttributedString` 写回 |
| 分块让出（`RunLoop.run`）在 TextKit 2 下不再需要 | 已禁用：`apply` 中 `chunked = false`，`renderChunkSize` 与让出代码保留作回退入口 |

实测（release）：1MB / 6912 节，窗口出现 1.7s、rss 约 190MB、滚动流畅。

## 验证

- 新增 `TextKit2Scrolling` 2 条（字符定位 / 可见区顶部字符）；
- 迁移当时全量 **250 条 / 49 套件**通过；当前（1.0.34）**253 条 `@Test` / 49 个 `@Suite` / 51 个测试文件**；
- GUI 复验（`HANDOVER.md` §18）：表格、引用（灰底 + 竖线）、图片、数学、Mermaid 正常；
- 已知限制：引用竖线依赖行首 `>` 的字符替换；自绘 fragment 背景方案会崩溃或合并引用行，不采用。

## 回退方式

`MarkdownTextView` 改回 `usingTextLayoutManager: false`，并还原 `ScrollViewBox` 的 TextKit 1 查询
（见 git 历史：`textkit-2` 分支的父提交）。

## 后果

- 布局按需、非连续；滚动定位与布局失效查询改用 `NSTextLayoutManager`；
- 系统查找栏能力收窄，统一降级到自带查找面板；
- 渲染仍是全量 `apply` + 缓存，「只重建可见区」的增量渲染尚未实现（TextKit 2 已提供基础）；
- 表格仍由 `NSTextTable` 承担，不采用自绘 `NSTextLayoutFragment`。
