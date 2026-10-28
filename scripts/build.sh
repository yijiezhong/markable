#!/bin/zsh
# build.sh —— 每次编译前自动把 patch 版本号 +1，再执行 swift build。
#
# 为什么需要包装：SwiftPM 没有「构建前跑脚本」的钩子（Build Tool Plugin 又限制在沙盒内，
# 无法把递增结果写回 VERSION）。所以用本脚本代替裸 `swift build`：
#
#   scripts/build.sh              # 版本 +1 后 swift build
#   scripts/build.sh -c release   # 透传 swift build 的参数
#
# 直接跑 `swift build` 仍然可以，只是版本号不会递增。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$("$ROOT/scripts/bump-version.sh")"
echo "▶︎ 版本号 → v${VERSION}"
cd "$ROOT"
exec swift build "$@"
