#!/bin/zsh
# prune-dist.sh —— 清理 dist/ 里旧的发布包 zip，只保留最近 N 个版本。
#
# 为什么需要：每次 release 都会在 dist/ 留下一个 Markable-<版本>.zip，
# 版本攒多了会占上百 MB（dist/ 不入 git，属纯本地构建产物）。
# 本脚本按**版本号**（不是 mtime、也不是字符串）排序，保留最新 N 个，删除其余。
#
# 用法：
#   scripts/prune-dist.sh                     # 演练：只打印将删除的清单与可释放空间
#   scripts/prune-dist.sh --keep 3            # 演练 + 自定义保留数量（默认 5）
#   scripts/prune-dist.sh --yes               # 真正删除（保留最近 5 个）
#   scripts/prune-dist.sh --keep 10 --yes     # 真正删除（保留最近 10 个）
#   scripts/prune-dist.sh --keep 5 --yes -q   # 静默模式：只输出结果行（release.sh 用）
#
# 安全约定：
#   - **未指定 --yes 时等价于 --dry-run**（只打印，不删），避免误删；
#   - 只处理 dist/Markable-<版本>.zip 与 dist/.DS_Store，不碰 dist/Markable.app 或其它文件；
#   - 版本按数字段比较（1.0.9 < 1.0.10），不是字符串排序；
#   - Markable-backup.zip 这类非版本命名会跳过并提示。
#
# 环境变量：
#   MARKABLE_DIST_DIR   覆盖 dist 目录（默认 <仓库>/dist），便于在临时目录演练或测试。
#
# 退出码：0 成功（含「无需清理」）；2 参数错误。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST="${MARKABLE_DIST_DIR:-$ROOT/dist}"

# zsh 默认在 glob 无匹配时报错退出；bash 则保留字面量（下面用 -e 判断跳过）。
# 这里统一成「无匹配 → 空列表」，两种 shell 行为一致。
if [[ -n "${ZSH_VERSION:-}" ]]; then
  setopt null_glob
fi

KEEP=5
DRY=0
ASSUME_YES=0
QUIET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)
      [[ $# -ge 2 ]] || { echo "--keep 需要数量" >&2; exit 2; }
      KEEP="$2"
      shift
      ;;
    --dry-run) DRY=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    --quiet|-q) QUIET=1 ;;
    -h|--help) awk 'NR > 1 && /^set -euo/ { exit } NR > 1 { print }' "$0"; exit 0 ;;
    *)
      echo "未知参数：$1" >&2
      echo "用 --help 查看用法" >&2
      exit 2
      ;;
  esac
  shift
done

[[ "$KEEP" =~ ^[0-9]+$ ]] || { echo "--keep 需要正整数：$KEEP" >&2; exit 2; }
(( KEEP >= 1 )) || { echo "--keep 至少为 1（当前 $KEEP）" >&2; exit 2; }

# 未显式 --yes 时退化为演练：默认不删任何东西（--dry-run 与 --yes 同时给时也按演练）。
if (( ASSUME_YES == 0 )); then
  DRY=1
fi

# 进度输出（--quiet 时全部抑制，只保留最终结果行）。
say() {
  if (( QUIET == 0 )); then
    echo "$@"
  fi
}

format_mb() {
  awk -v b="${1:-0}" 'BEGIN { printf "%.1f MB", b / 1048576 }'
}

# macOS 的 stat：精确字节数；文件不存在时返回 0。
bytes_of() {
  stat -f%z "$1" 2>/dev/null || echo 0
}

# 版本号排序键：数字段补零到 9 位（保证 1.0.9 < 1.0.10），
# 非数字段（如 -rc1 / +build5）按字面保留，只作次级比较。
version_key() {
  printf '%s' "$1" | awk -F'[.+-]' '{
    key = ""
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^[0-9]+$/) key = key sprintf("%09d.", $i)
      else key = key $i "."
    }
    print key
  }'
}

# 输出：按版本升序的版本号，每行一个（不含路径与 .zip）。
# 只收版本号以数字开头的文件；Markable-backup.zip 这类非版本命名不参与清理。
sorted_versions() {
  local f base ver key
  {
    for f in "$DIST"/Markable-*.zip; do
      [[ -e "$f" ]] || continue
      base="${f##*/}"
      ver="${base#Markable-}"
      ver="${ver%.zip}"
      case "$ver" in
        [0-9]*) ;;
        *)
          echo "跳过非版本命名：$base（只清理 Markable-<版本>.zip）" >&2
          continue
          ;;
      esac
      key="$(version_key "$ver")"
      printf '%s\t%s\n' "$key" "$ver"
    done
  } | sort -k1,1 | cut -f2
}

if [[ ! -d "$DIST" ]]; then
  echo "dist 目录不存在：$DIST"
  echo "没有可清理的构建产物。"
  exit 0
fi

VERSIONS=()
while IFS= read -r v; do
  [[ -n "$v" ]] && VERSIONS+=("$v")
done < <(sorted_versions)
TOTAL=${#VERSIONS[@]}

DELETE_COUNT=$(( TOTAL - KEEP ))
(( DELETE_COUNT < 0 )) && DELETE_COUNT=0

TOTAL_BYTES=0
for v in "${VERSIONS[@]}"; do
  TOTAL_BYTES=$(( TOTAL_BYTES + $(bytes_of "$DIST/Markable-$v.zip") ))
done

DOOMED=()
DOOMED_BYTES=0
KEPT=()
i=0
for v in "${VERSIONS[@]}"; do
  i=$(( i + 1 ))
  if (( i <= DELETE_COUNT )); then
    DOOMED+=("$v")
    DOOMED_BYTES=$(( DOOMED_BYTES + $(bytes_of "$DIST/Markable-$v.zip") ))
  else
    KEPT+=("$v")
  fi
done

HAS_DS_STORE=0
if [[ -f "$DIST/.DS_Store" ]]; then
  HAS_DS_STORE=1
  DOOMED_BYTES=$(( DOOMED_BYTES + $(bytes_of "$DIST/.DS_Store") ))
fi

say "dist 清理（按版本号保留最近 $KEEP 个 zip）"
say "目录：$DIST"
say "现有：$TOTAL 个 zip，共 $(format_mb "$TOTAL_BYTES")"
say

if (( ${#KEPT[@]} > 0 )); then
  say "将保留 ${#KEPT[@]} 个："
  for v in "${KEPT[@]}"; do
    say "  $v"
  done
else
  say "将保留：0 个"
fi
say

if (( ${#DOOMED[@]} == 0 && HAS_DS_STORE == 0 )); then
  echo "✅ 无需清理（zip 数量未超过保留数，且没有 .DS_Store）"
  exit 0
fi

if (( ${#DOOMED[@]} > 0 )); then
  say "将删除 ${#DOOMED[@]} 个："
  for v in "${DOOMED[@]}"; do
    say "$(printf '  %-26s %s' "Markable-$v.zip" "$(format_mb "$(bytes_of "$DIST/Markable-$v.zip")")")"
  done
  say
fi

if (( HAS_DS_STORE == 1 )); then
  say "将同时清理：$DIST/.DS_Store"
  say
fi

RELEASE_MB="$(format_mb "$DOOMED_BYTES")"
say "可释放：$RELEASE_MB"
say

if (( DRY == 1 )); then
  if (( ASSUME_YES == 0 )); then
    say "（演练模式：未删除任何文件；加 --yes 执行）"
  else
    say "（演练模式：未删除任何文件）"
  fi
  exit 0
fi

for v in "${DOOMED[@]}"; do
  rm -f -- "$DIST/Markable-$v.zip"
done
if (( HAS_DS_STORE == 1 )); then
  rm -f -- "$DIST/.DS_Store"
fi

KEPT_LIST=""
for v in "${KEPT[@]}"; do
  KEPT_LIST="$KEPT_LIST $v"
done
KEPT_SHOW="${KEPT_LIST# }"
if (( ${#DOOMED[@]} > 0 && HAS_DS_STORE == 1 )); then
  echo "✅ 已删除 ${#DOOMED[@]} 个 zip 与 .DS_Store，释放 $RELEASE_MB"
elif (( ${#DOOMED[@]} > 0 )); then
  echo "✅ 已删除 ${#DOOMED[@]} 个 zip，释放 $RELEASE_MB"
else
  echo "✅ 已删除 .DS_Store（没有需要删除的 zip），释放 $RELEASE_MB"
fi
echo "   保留：${KEPT_SHOW:-（无）}"
