#!/bin/zsh
# bump-version.sh —— 版本号递增工具（x.y.z 个位数进位制），并生成 App 内可读的版本文件。
#
# 版本规则（全局通用）：x.y.z 每一位都是 0–9 的个位数；
#   patch 满 9 后再 +1 → 归 0、minor +1；minor 满 9 后再 +1 → 归 0、major +1。
#
# 版本唯一来源是仓库根的 VERSION 文件；每次执行都会：
#   1) 递增版本号并写回 VERSION；
#   2) 生成 Sources/App/GeneratedVersion.swift（供「关于」窗口等显示）。
#
# 用法：
#   scripts/bump-version.sh                 # patch +1（1.0.0 → 1.0.1）
#   scripts/bump-version.sh --minor         # minor +1，patch 归零
#   scripts/bump-version.sh --major         # major +1，minor/patch 归零
#   scripts/bump-version.sh --set 2.3.4     # 直接设定版本
#   scripts/bump-version.sh --print         # 只打印当前版本（不修改）
#   scripts/bump-version.sh --dry-run       # 打印递增后的版本（不写文件）
#
# 输出：递增后的版本号（stdout，便于脚本捕获）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT/VERSION"
GENERATED="$ROOT/Sources/App/GeneratedVersion.swift"

MODE="patch"
DRY=0
PRINT_ONLY=0
SET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --major)   MODE="major" ;;
    --minor)   MODE="minor" ;;
    --patch)   MODE="patch" ;;
    --print)   PRINT_ONLY=1 ;;
    --dry-run) DRY=1 ;;
    --set)     SET="${2:?--set 需要版本号}"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
  shift
done

[[ -f "$VERSION_FILE" ]] || echo "1.0.0" > "$VERSION_FILE"
CURRENT="$(tr -d '[:space:]' < "$VERSION_FILE")"

if [[ "$PRINT_ONLY" == "1" ]]; then
  echo "$CURRENT"
  exit 0
fi

if [[ -n "$SET" ]]; then
  NEW="$SET"
else
  IFS='.' read -r major minor patch <<< "$CURRENT"
  major="${major:-1}"; minor="${minor:-0}"; patch="${patch:-0}"
  case "$MODE" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor)
      minor=$((minor + 1))
      patch=0
      if (( minor > 9 )); then
        minor=0
        major=$((major + 1))
      fi
      ;;
    patch)
      patch=$((patch + 1))
      if (( patch > 9 )); then
        patch=0
        minor=$((minor + 1))
        if (( minor > 9 )); then
          minor=0
          major=$((major + 1))
        fi
      fi
      ;;
  esac
  NEW="$major.$minor.$patch"
fi

BUILD_NUMBER="$(date +%Y%m%d%H%M)"

if [[ "$DRY" == "1" ]]; then
  echo "$NEW"
  exit 0
fi

echo "$NEW" > "$VERSION_FILE"
mkdir -p "$(dirname "$GENERATED")"
cat > "$GENERATED" <<SWIFT
// 由 scripts/bump-version.sh 生成，勿手改。
// 每次编译（scripts/build.sh）或打包（scripts/make-app-bundle.sh）自动递增后覆盖。
enum AppVersion {
    /// 版本号（x.y.z，每位 0–9，满 9 进位）
    static let short = "$NEW"
    /// 构建号（递增时间）
    static let build = "$BUILD_NUMBER"
    /// 「关于」窗口显示的一行
    static var display: String { "v\(short) (\(build))" }
}
SWIFT

echo "$NEW"
