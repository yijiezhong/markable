#!/bin/zsh
# lint.sh —— Swift 静态检查入口：默认只读检查，--fix 才自动修复。
#
# 用法：
#   scripts/lint.sh            # 检查：swiftlint + swift-format（只读，默认只报告）
#   scripts/lint.sh --strict   # 有 error 级问题时退出码 1（门禁用）
#   scripts/lint.sh --fix      # 自动修复，只作用于 Sources/ 与 Tests/
#
# 退出码策略：
#   0  默认模式：只报告，不因历史告警判红；两个工具都没安装也返回 0
#   1  --strict 且 swiftlint 有 error 级问题，或 swift-format 自身执行失败
#   2  参数用法错误
#
# 为什么工具缺失时返回 0：CI 与新机器未必预装这两个工具；缺工具不应该把构建判红。
# 为什么 warning 不阻断：仓库还有成百上千条历史告警，先让问题可见，等配置收紧
# （排除 Vendor/、放宽 identifier_name、统一 lineLength）后再改成硬门禁。
# 为什么默认不自动修复：swiftlint --fix / swift-format -i 会在历史代码里产生大面积
# 与业务无关的格式 diff，并和正在进行的编辑冲突；只有显式 --fix 才动手，且永不碰 Vendor/。

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FIX=0
STRICT=0
for arg in "$@"; do
  case "$arg" in
    --fix) FIX=1 ;;
    --strict) STRICT=1 ;;
    -h|--help)
      sed -n '2,19p' "$0" | sed -E 's/^# ?//'
      exit 0
      ;;
    *)
      echo "用法：scripts/lint.sh [--strict] [--fix]" >&2
      exit 2
      ;;
  esac
done

SWIFTLINT="$(command -v swiftlint 2>/dev/null || true)"
SWIFT_FORMAT="$(command -v swift-format 2>/dev/null || true)"
STATUS=0
LIMIT=80   # 每类最多显示多少条明细，避免 2000+ 行刷屏

if [[ -z "$SWIFTLINT" && -z "$SWIFT_FORMAT" ]]; then
  echo "⚠️  未安装 swiftlint / swift-format，跳过（brew install swiftlint swift-format）"
  exit 0
fi

show_head() {  # $1 = 输出文件，$2 = 总条数
  head -n "$LIMIT" "$1"
  if (( $2 > LIMIT )); then
    echo "  …（共 $2 条，上面只显示前 $LIMIT 条）"
  fi
}

if [[ -n "$SWIFTLINT" ]]; then
  if (( FIX )); then
    echo "▶︎ swiftlint --fix（仅 Sources/ Tests/）"
    "$SWIFTLINT" lint --fix --quiet --config "$ROOT/.swiftlint.yml" Sources Tests >/dev/null 2>&1 || true
  fi

  echo "▶︎ swiftlint lint --quiet"
  SL_OUT="$(mktemp)"
  "$SWIFTLINT" lint --quiet --config "$ROOT/.swiftlint.yml" >"$SL_OUT" 2>&1
  SL_RC=$?
  SL_ERR=$(grep -cE ':[0-9]+:[0-9]+: error: ' "$SL_OUT" || true)
  SL_WARN=$(grep -cE ':[0-9]+:[0-9]+: warning: ' "$SL_OUT" || true)
  show_head "$SL_OUT" $(( SL_ERR + SL_WARN ))
  rm -f "$SL_OUT"
  if (( SL_RC == 0 )); then
    echo "  ✓ swiftlint：${SL_ERR} 条 error / ${SL_WARN} 条 warning"
  elif (( STRICT )); then
    echo "  ✗ swiftlint：${SL_ERR} 条 error / ${SL_WARN} 条 warning（--strict 判失败）" >&2
    STATUS=1
  else
    echo "  ⚠️  swiftlint：${SL_ERR} 条 error / ${SL_WARN} 条 warning" >&2
    echo "      默认只报告；加 --strict 才让 error 判失败" >&2
  fi
else
  echo "⚠️  未安装 swiftlint，跳过（brew install swiftlint）"
fi

if [[ -n "$SWIFT_FORMAT" ]]; then
  if (( FIX )); then
    echo "▶︎ swift-format format -i（仅 Sources/ Tests/）"
    "$SWIFT_FORMAT" format -i --recursive --configuration "$ROOT/.swift-format" Sources Tests || true
  fi

  echo "▶︎ swift-format lint --recursive Sources Tests"
  SF_OUT="$(mktemp)"
  "$SWIFT_FORMAT" lint --recursive --configuration "$ROOT/.swift-format" Sources Tests >"$SF_OUT" 2>&1
  SF_RC=$?
  SF_WARN=$(grep -cE 'warning: \[' "$SF_OUT" || true)
  show_head "$SF_OUT" "$SF_WARN"
  rm -f "$SF_OUT"
  if (( SF_RC == 0 )); then
    echo "  ✓ swift-format：${SF_WARN} 条 warning（风格建议，不阻断）"
  else
    echo "  ✗ swift-format：执行失败（exit ${SF_RC}）" >&2
    STATUS=1
  fi
else
  echo "⚠️  未安装 swift-format，跳过（brew install swift-format）"
fi

echo
if (( STATUS == 0 )); then
  if (( STRICT )); then
    echo "✅ lint 通过（--strict，无 error）"
  else
    echo "✅ lint 完成（默认只报告；加 --strict 以在 error 时失败，--fix 自动修复）"
  fi
else
  echo "❌ lint 失败（--strict 门禁或工具执行错误，见上）"
fi
exit $STATUS
