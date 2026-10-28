#!/bin/zsh
# export-github.sh —— 生成「GitHub 公开仓库」快照（脱敏后）。
#
# 用法：
#   scripts/export-github.sh [输出目录]     # 默认 dist/github
#
# 做的事：
#   1) 用 `git archive HEAD` 导出**已提交**的文件（不含未提交改动、不含 .git）；
#   2) 剔除内部文件：HANDOVER.md（交接日志，含内网地址）、第三方商标样例图；
#   3) 校验快照里没有内网地址 / 本机路径 / 用户名，命中即失败。
#
# 说明：为什么用「干净快照」而不是直接推现有历史——
#   历史提交里 HANDOVER.md 的旧版本含内网 NAS 地址，直接推会一并公开。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist/github}"

rm -rf "$OUT"
mkdir -p "$OUT"
cd "$ROOT"

git archive --format=tar HEAD | tar -x -C "$OUT"

# 内部文件 / 第三方商标样例
rm -f "$OUT/HANDOVER.md" "$OUT/samples/deepseek-logo.png"

# 脱敏校验
PATTERN='10\.0\.0\.6|gitcommiter|/Users/yijiezhong|yijiezhong@'
if grep -rIn -E "$PATTERN" "$OUT" --exclude=export-github.sh 2>/dev/null; then
  echo "❌ 快照里仍有敏感信息（见上），已终止" >&2
  exit 1
fi

# 必需要件检查
for required in README.md LICENSE THIRD-PARTY-NOTICES.md Package.swift; do
  [[ -f "$OUT/$required" ]] || { echo "❌ 快照缺少 $required" >&2; exit 1; }
done

echo "✅ GitHub 快照：$OUT"
echo "   文件数：$(find "$OUT" -type f | wc -l | tr -d ' ')"
echo "   版本：$(cat "$OUT/VERSION" 2>/dev/null || echo '?')"
