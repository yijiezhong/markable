#!/bin/zsh
# release.sh —— 默认交付流程：版本 +1 → release 构建 → 打包 → 安装到 /Applications
#              → 注册 LaunchServices → 把 .md 默认打开程序指向新装的版本。
#
# 为什么需要：Finder 双击 .md 走的是 LaunchServices 的默认关联，
# 只有把最新构建**覆盖安装**到固定位置并重新注册，双击打开才会是最新版本。
#
# 用法：
#   scripts/release.sh            # 默认：release 构建 + 安装 + 打 zip
#   scripts/release.sh --debug    # 调试构建（更快），其余相同
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

CONFIG_FLAG="--release"
if [[ "${1:-}" == "--debug" ]]; then
  CONFIG_FLAG="--debug"
  shift
fi

"$SCRIPT_DIR/make-app-bundle.sh" "$CONFIG_FLAG" --install --zip "$@"

echo
echo "✅ 交付完成"
echo "   应用：/Applications/Markable.app（或 ~/Applications/Markable.app）"
echo "   Finder 双击 .md → 打开的即上面这份最新版本"

# 清理旧的发布包：dist/ 只保留最近 5 个 zip。
# 失败不阻断交付，也不改变本脚本的退出码。
if [[ -x "$SCRIPT_DIR/prune-dist.sh" ]]; then
  if "$SCRIPT_DIR/prune-dist.sh" --keep 5 --yes -q; then
    echo "🧹 dist/：旧 zip 已清理（保留最近 5 个）"
  else
    echo "⚠️  旧 zip 清理失败（不影响本次交付）"
  fi
fi
