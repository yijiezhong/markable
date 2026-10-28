# 代码字体方案：苹果官方字体 + 字距补偿

版本：1.0
日期：2026-10-24
适用：Markable 的代码块、行内代码、表格内代码，以及 HTML / PDF 导出
结论：苹果官方字体经字距补偿后，8–60pt、各字重下中英文均保持 2:1 等宽（实测误差 0.0000pt）

## 1. 背景

代码块要求「中文与英文都等宽」，才能保证中英混排时列对齐。苹果官方字体存在两个事实：

1. 官方**等宽西文字体**（SF Mono / Menlo / Monaco / Courier New / Courier / Andale Mono / PT Mono）的半角宽度是 0.60–0.618 em；
2. 官方**中文字体**（苹方 / 宋体 / 楷体 / 黑体 / 冬青黑体）的中文都是全角 1 em，但西文是比例字体。

因此「中文全角」与「西文半角」的宽度比是 1.62–1.67，不是 2:1，混排时列会错位；而宋体/楷体虽然中西比接近 1.96–1.98，但西文本身不等宽（`i` 3.78 vs `m` 10.99），同样不能用于代码对齐。

## 2. 方案

用「等宽西文 + 中文全角字体 + 中文逐字字距补偿」组合出严格 2:1。

### 2.1 非衬线场景

| 角色 | 字体 | 14pt 实测 |
|---|---|---|
| 西文（等宽） | SF Mono（`SFMono-Regular`） | 半角 8.65 |
| 中文（非衬线） | PingFang SC（`PingFangSC-Regular`） | 全角 14.00 |
| 字距补偿 | 中文（含全角标点）逐字加 kern | +3.31pt |

### 2.2 衬线场景

| 角色 | 字体 | 14pt 实测 |
|---|---|---|
| 西文（衬线等宽） | Courier New（`CourierNewPSMT`） | 半角 8.40 |
| 中文（衬线） | Songti SC（`STSongti-SC-Regular`） | 全角 14.00 |
| 字距补偿 | 中文（含全角标点）逐字加 kern | +2.80pt |

> 宋体只使用其中文字形；它的西文是比例字体，不参与代码西文排版。

### 2.3 kern 公式

```
kern = 2 × 西文半角宽 − 中文全角宽 = (2 × 半角比例 − 1) × 字号
```

| 西文字体 | 半角比例 | kern 系数 | 8pt | 20pt | 32pt | 48pt | 60pt |
|---|---|---|---|---|---|---|---|
| SF Mono | 0.618 | 0.2363 | 1.89 | 4.73 | 7.56 | 11.34 | 14.18 |
| Courier New | 0.600 | 0.2002 | 1.60 | 4.00 | 6.41 | 9.61 | 12.01 |

字重不影响系数（各字重的半角/全角比例一致），因此只需按字体族计算一次。

## 3. 全字号 × 字重实测

测法：构造「中文中文ab」，期望宽度 = 6 个半角宽，比较实测值；误差 < 0.12pt 记为通过。

| 场景 | 组合 | 字号 | 字重 | 组合数 | 通过 | 最大误差 |
|---|---|---|---|---|---|---|
| 非衬线 | SF Mono + PingFang SC | 8–60（14 档） | 6 档（Light/Regular/Medium/Semibold/Bold/Heavy） | 84 | 84/84 | 0.0000pt |
| 衬线 | Courier New + Songti SC | 8–60（14 档） | 4 档（Light/Regular/Bold/Black） | 56 | 56/56 | 0.0000pt |

补充验证：

| 验证项 | 结果 |
|---|---|
| 长串累积误差（5 中文 + 5 西文，14 个字号） | 最大误差 0.0000pt |
| 全角标点 `，。；：！？`（14 个字号） | 最大误差 0.0000pt |
| 8pt 小字号（kern 1.89 / 1.60） | 精确对齐 |
| 60pt 大字号（kern 14.18 / 12.01） | 精确对齐 |

## 4. 实现

### 4.1 阅读渲染（TextKit 1）

核心在 `Sources/Editor/CodeTypography.swift`：

1. 遍历代码范围，按「全角 / 半角」分段（`isWide(_:)` 覆盖 CJK 基本区、扩展 A、假名、谚文、全角标点、兼容区）；
2. 全角段设中文字体并加 `.kern = 系数 × 字号`；半角段设西文字体；
3. 代码块 / 行内代码 / 表格内代码统一走 `applyCodeFont(to:range:size:style:)`；
4. 代码字体风格随正文字体族切换：正文字体为衬线时用衬线组合，否则用非衬线组合。

### 4.2 导出（HTML / PDF）

`Sources/Export/HtmlRenderer.swift`：

- 代码文本按「全角 / 半角」分段，中文段包 `<span class="code-cjk">`；
- CSS 用 `letter-spacing` 模拟 kern：

```css
code, pre { font-family: "SF Mono", Menlo, monospace; }
code .code-cjk, pre .code-cjk { font-family: "PingFang SC"; letter-spacing: 0.2363em; }
```

衬线风格对应 `"Courier New"` + `"Songti SC"` + `letter-spacing: 0.2002em`。

导出调用点（`DocumentScene`）统一通过 `makeHtmlRenderer()` 传入当前正文字体对应的 `codeStyle`。

## 5. 测试样例

`samples/markdown-syntax-full.md` 第 9.6 节「中英文等宽（字体专项）」按 8 个分类覆盖对齐场景：

1. 纯西文基线（等宽字体对照基准）
2. 纯中文（每个中文 = 2 个西文宽）
3. 中英混排（同一行 2:1 比例）
4. 缩进层级（2 空格 = 1 西文 = 半个中文）
5. 全角标点（，。；：！？ 也是 2 个西文宽）
6. 代码注释中英混排（真实场景）
7. 列对齐（用中英文拼的表格化文本）
8. 行内代码与正文混排

渲染验证：分类 1 的 10 个西文与分类 2 的 5 个中文等宽；分类 3 的「中文 ab」与「ab 中文」等长；各分类首尾对齐。

## 6. 关于字体内嵌

**本方案不内嵌字体文件。** Apple 系统字体（SF Mono / PingFang SC / Courier New / Songti SC）受 macOS EULA 限制，只允许在系统上使用，不允许复制进应用分发包；因此项目不包含 `Resources/Fonts`，方案只依赖 macOS 自带字体。

若未来需要「不依赖系统字体」的发行方式，应改用可再分发的开源等宽 CJK 字体（如 Noto Sans Mono CJK SC、Sarasa Mono，均为 OFL），这类字体本身原生 2:1，无需字距补偿。

## 7. 测试与验证

单元测试：`Tests/Unit/CodeFontTests.swift`（5 项）

| 测试 | 结果 |
|---|---|
| 代码块西文 SF Mono、中文苹方（含 kern 属性） | 通过 |
| 代码块中英混排宽度 = 6 个半角宽（2:1） | 通过 |
| 衬线场景：Courier New + 宋体 | 通过 |
| HTML 导出：`code-cjk` + `letter-spacing: 0.2363em` | 通过 |
| HTML 导出（衬线）：`letter-spacing: 0.2002em` | 通过 |

运行方式：

```bash
swift test --filter CodeFont
```
