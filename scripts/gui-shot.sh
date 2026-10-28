#!/bin/zsh
# gui-shot.sh —— 自动化 GUI 截图：启动 Markable → 等待 → 截其窗口 → 关闭。
#
# 用法：
#   scripts/gui-shot.sh [输出PNG路径] [--keep]
#     --keep  截图后不关闭应用（便于人工继续查看）
#
# 前提：终端/宿主已获「屏幕录制」权限（screencapture 可用）。
# 说明：用 CoreGraphics 按属主名找到窗口号后，`screencapture -l <id>` 截该窗口，
#       因此不需要窗口位于前台（也不需要「辅助功能」权限）。

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="$APP_DIR/.build/debug/Markable"

OUT="${1:-/private/var/folders/q4/t09jsrg911lbv35z4879571r0000gn/T/opencode/markable-win.png}"
KEEP=0
for a in "$@"; do [ "$a" = "--keep" ] && KEEP=1; done

if [ ! -x "$BIN" ]; then
  echo "未找到可执行文件：$BIN（请先在 Markable/ 目录执行 swift build）" >&2
  exit 2
fi

TMPWIN="$(mktemp -t markablewin)"
cat > "$TMPWIN.swift" <<'SWIFT'
import CoreGraphics
import Foundation
let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
if let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] {
    for w in list {
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        if owner == "Markable" {
            if let num = w[kCGWindowNumber as String] as? Int { print(num) }
            break
        }
    }
}
SWIFT

# 清掉已有实例，保证截到的是本次启动的窗口
pkill -x Markable 2>/dev/null || true
sleep 1

"$BIN" >/dev/null 2>&1 &
APP_PID=$!
sleep 8

WIN="$(swift "$TMPWIN.swift" 2>/dev/null | head -1)"
if [ -n "${WIN:-}" ]; then
  screencapture -x -l "$WIN" "$OUT" 2>/dev/null
  echo "SHOT=$OUT"
else
  echo "NO_WINDOW"
fi

if [ "$KEEP" -eq 0 ]; then
  kill "$APP_PID" 2>/dev/null || true
  pkill -x Markable 2>/dev/null || true
fi
rm -f "$TMPWIN.swift"
