# ADR 0001：TextKit 2 迁移评估

状态：**已迁移（2026-10-24 推翻原「不迁移」结论；正文渲染改为 TextKit 2）**

日期：2026-10-24

决策人：维护者（Lead）

关联：`docs/ARCHITECTURE.md` §12.3 第 2 项；实施记录见 [ADR 0002](0002-textkit-2-migration.md)、`HANDOVER.md` §18–§19

## 背景

> **状态提示（2026-10-24 更新）**：本 ADR 原结论「不迁移」已被维护者推翻，正文渲染已切到 TextKit 2。
> 下文「背景」「硬依赖」「阻碍」「成本」「决策」「触发条件」「备注」保留为**历史评估记录**；
> 现状与实施方案见文末「决策更新」、[ADR 0002](0002-textkit-2-migration.md) 与 `HANDOVER.md` §18。

Markable 的正文渲染当时建立在 **TextKit 1** 上：`NSTextView(usingTextLayoutManager: false)` + `NSLayoutManager` + `NSTextStorage`。架构报告把「TextKit 2 迁移」列为长期演进项。本 ADR 给出评估结论与触发条件。

## 当时对 TextKit 1 的硬依赖（历史）

`LivePreviewController`（1,269 行）与导出/测试中以下能力都依赖 TextKit 1 的语义：

| 能力 | 依赖 |
|---|---|
| 表格真网格 | `NSTextTable` + `NSTextTableBlock`（`fixedLayoutAlgorithm`、列宽、边框、单元格内联样式） |
| 引用整块背景 | `NSParagraphStyle.textBlocks` + `NSTextBlock` 背景/内边距 |
| 图片 / Mermaid / 数学 / 水平线 / 竖线 | `NSTextAttachment` 附件（`U+FFFC` 占位、`bounds` 控制尺寸） |
| 隐藏标记 | 按字符设置 0.1pt 字体 + 透明色（不删字符），依赖属性级渲染 |
| 布局查询 | `NSLayoutManager.ensureLayout` / `usedRect` / `lineRange`，用于滚动定位、快照尺寸 |
| 只读选择与复制 | `NSTextView.isSelectable` + TextKit 1 选区行为 |

## 当时的 TextKit 2 主要差异与阻碍（历史；第 1 / 2 / 5 条已被实测推翻）

1. **表格**：TextKit 2 的 `NSTextLayoutManager` 不提供 `NSTextTable` 的等价布局；表格需要改用 `NSTextTable` 之外的方案（例如自绘 `NSTextLayoutFragment` 或把表格降级为文本块），会丢失网格线与列宽语义；
2. **附件布局**：TextKit 2 的附件由 `NSTextAttachmentViewProvider` / `NSTextLayoutFragment` 控制，现有「图片附件 + `bounds` + 行高」的经验与测试不适用；
3. **属性渲染**：「0.1pt 隐藏标记」在 TextKit 2 中仍可行，但行 fragment 的测量与换行行为不同，现有 90+ 条渲染测试需要整体回归；
4. **布局查询 API**：`NSTextLayoutManager` 用 `textLayoutFragment(for:)` / `enumerateTextLayoutFragments`，滚动定位、`.usedRect` 快照、表格列宽测量都要重写；
5. **收益不确定**：TextKit 2 的核心优势是视口化/非连续布局；Markable 当前文档规模（±1MB）用缓存 + 局部替换已能覆盖，尚未出现必须迁移的性能证据。

## 迁移成本估算

- 渲染核心：约 400 行直接调用 TextKit 1 API 的代码需要重写（表格重建 ~150 行、附件 ~100 行、布局查询 ~80 行、滚动/选择 ~70 行）；
- 测试：36+ 个套件中约 12 个依赖 TextKit 1 行为，需要重写断言；
- 回归风险：隐藏标记、表格、引用块、数学/图片附件的视觉一致性需要逐项 GUI 复核；
- 预计 3–5 人日（不含灰度验证），且没有明确的产品收益。

## 决策（已被推翻）

> **本决策已废弃（2026-10-24）**：维护者决定迁移 TextKit 2。实际方案、踩坑与验证见
> [ADR 0002](0002-textkit-2-migration.md) 与 `HANDOVER.md` §18。以下内容保留为历史记录。

**不迁移 TextKit 2。** 采用以下替代优化（当轮已落地）：

1. 语法扫描缓存（apply 入口 2 次扫描，collect 阶段复用）；
2. 渲染结果缓存（同源同参数直接复用 attributed string）；
3. 数学公式渲染完成后**局部替换占位**，不再触发全量重建；
4. 后续如需更大文档，优先做「按段落/可见区分块」的增量渲染，而不是迁移布局引擎。

## 触发条件（重新评估，历史）

满足任一条件时重新评估 TextKit 2：

- 出现 >10MB 的单文档，且缓存 + 分块仍无法满足输入/滚动延迟；
- 需要 TextKit 2 独有能力（例如复杂文本选择、无障碍子结构、视口化布局）；
- TextKit 2 对表格/附件提供与 TextKit 1 等价的公开 API。

## 备注（历史）

本 ADR 撰写时不改动代码；当时 TextKit 1 仍是唯一渲染路径。

## 实施记录（2026-10-24 后续）

在 TextKit 1 约束下，「按可见区分块」落地为**分块让出式渲染**（`LivePreviewController.apply`）：

- 超过 256KB 的文档，在属性渲染阶段每 128 个 `StyledRange` 调用一次
  `RunLoop.current.run(until: Date())` 让出主线程，避免打开大文档时界面长时间冻结
  （首屏基础排版先显示，样式逐块补齐）；
- 渲染结果缓存（同源/同字号/同宽度/同排版参数直接复用 attributed string）；
- 数学公式渲染完成后只替换占位符，不再触发全量重建；
- 分块让出期间若窗口 resize 触发重入，直接跳过，下一次 `applyIfNeeded` 补齐。

真正的「只渲染可见区」仍需 TextKit 2（见触发条件）；本轮分块让出与缓存已让 1MB 文档的
打开与重复渲染不再长时间阻塞主线程。

## 决策更新（2026-10-24）：已迁移 TextKit 2

维护者决定推翻原「不迁移」结论，正文渲染已切到 TextKit 2：

- `MarkdownTextView` 改用 `ReaderTextView(usingTextLayoutManager: true)`；
- 布局查询：`NSTextLayoutManager.textLayoutFragment(for:)` + `ensureLayout(for:)` 替代
  `NSLayoutManager.glyphRange/boundingRect/characterIndex`（`ScrollViewBox.scrollToCharacter` /
  `visibleTopCharacterIndex`）；
- 布局失效：`NSTextLayoutManager.invalidateLayout(for:)` 替代
  `NSLayoutManager.invalidateLayout(forCharacterRange:)`。

实测结论：

- 表格：`NSTextTable` + `NSTextTableBlock` 在 TextKit 2 下**正常绘制**（列宽/网格线/单元格样式）；
  `TableRendering` / `TableExtras` 测试全过；
- 引用：`NSTextBlock` 灰底正常；**左边框方案会把多行引用压成一行**（不可用）；逐行竖线附件在
  TextKit 2 下位置有偏移，最终改为把行首 `>` **原地替换为字符 `│`**
  （`collectQuoteBarReplacements`，`tertiaryLabelColor` + `makeBlockquoteStyle()`），不插入附件、不自绘；
- 附件（图片/数学/Mermaid/水平线）：正常；
- 隐藏标记（0.1pt + 透明色）：正常；
- 滚动定位：`scrollToCharacter` / `visibleTopCharacterIndex` 有专项测试（`TextKit2Scrolling`，2 条）；
- 系统查找栏：TextKit 2 不支持 `NSTextFinder` 的 Find Bar，`⌥⌘F` 降级到自带查找面板；
- 全量测试 **253 条 / 49 套件**通过（迁移当时为 250 条，后续补测至 253 条）。

回退方式：`MarkdownTextView.makeNSView` 改回 `usingTextLayoutManager: false`，并还原
`ScrollViewBox` 的 TextKit 1 查询（见 git 历史：`textkit-2` 分支的父提交）。
