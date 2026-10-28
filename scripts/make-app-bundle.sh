#!/bin/zsh
# make-app-bundle.sh —— 把 SwiftPM 可执行文件打包成可发布的 `Markable.app`，并可安装到本地。
#
# 为什么需要：命令行可执行文件没有 bundle，LaunchServices 无法把 `markable://` 路由过来，
# 也不会读取 App Intents 元数据。打包成 .app、写入 Info.plist（URL scheme + 图标），
# 并把 `Metadata.appintents` 放进 Resources 后，这些能力才真正可用。
#
# 用法：
#   scripts/make-app-bundle.sh [--release] [--install] [--zip] [--no-bump] [输出目录]
#     --release  用 release 配置构建（默认 debug）
#     --install  复制到 /Applications（不可写时退到 ~/Applications）并注册到 LaunchServices
#     --zip      额外生成可分发的 zip（放在输出目录）
#     --no-bump  保留当前 VERSION（只刷新构建号），供 CI / 冒烟验证使用
#
# 默认输出：<仓库>/dist/Markable.app
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$APP_DIR"

CONFIG="debug"
INSTALL=0
MAKE_ZIP=0
NO_BUMP=0
OUT_DIR=""
VERSION=""
BUILD_NUMBER=""

for a in "$@"; do
  case "$a" in
    --release) CONFIG="release" ;;
    --debug)   CONFIG="debug" ;;
    --install) INSTALL=1 ;;
    --zip)     MAKE_ZIP=1 ;;
    --no-bump) NO_BUMP=1 ;;
    -*)        echo "未知参数：$a" >&2; exit 2 ;;
    *)         OUT_DIR="$a" ;;
  esac
done
OUT_DIR="${OUT_DIR:-$APP_DIR/dist}"

# ── 版本号：默认每次打包自动 patch +1；--no-bump 保留当前版本（仅刷新构建号）──
if [ "$NO_BUMP" -eq 1 ]; then
  echo "▶︎ 保留当前版本号（--no-bump）"
  VERSION="$("$SCRIPT_DIR/bump-version.sh" --set "$(tr -d '[:space:]' < "$APP_DIR/VERSION")")"
else
  echo "▶︎ 递增版本号"
  VERSION="$("$SCRIPT_DIR/bump-version.sh")"
fi
# 构建号以 bump 生成的值为准，保证 Info.plist 与 App 内「关于」显示一致
BUILD_NUMBER="$(sed -n 's/.*static let build = "\([0-9][0-9]*\)".*/\1/p' \
  "$APP_DIR/Sources/App/GeneratedVersion.swift" | head -1)"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
echo "   版本：v${VERSION}（build ${BUILD_NUMBER}）"

echo "▶︎ swift build -c $CONFIG（带 -emit-const-values，供 App Intents 元数据抽取）"
swift build -c "$CONFIG" -Xswiftc -emit-const-values

BIN_DIR="$APP_DIR/.build/$CONFIG"
BIN="$BIN_DIR/Markable"
[ -x "$BIN" ] || { echo "未找到可执行文件：$BIN" >&2; exit 2; }

APP="$OUT_DIR/Markable.app"
TMP="$(mktemp -d -t markable-pkg)"
trap 'rm -rf "$TMP"' EXIT

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Markable"

# SwiftPM 资源 bundle（KaTeX 等）
for bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# 许可与第三方声明：随分发物携带，满足 MIT / Apache-2.0 / BSD 的再分发要求
for doc in LICENSE THIRD-PARTY-NOTICES.md; do
  [ -e "$APP_DIR/$doc" ] && cp "$APP_DIR/$doc" "$APP/Contents/Resources/"
done

# ── 应用图标 ──
echo "▶︎ 生成应用图标"
ICON_SRC="$TMP/icon-1024.png"
if swift "$SCRIPT_DIR/make-icon.swift" "$ICON_SRC" >/dev/null 2>&1; then
  ICONSET="$TMP/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1
    sips -z $((size * 2)) $((size * 2)) "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1
  done
  if iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
    echo "✅ 图标已嵌入 AppIcon.icns"
  else
    echo "⚠️ iconutil 生成失败，使用默认图标"
  fi
else
  echo "⚠️ 图标生成失败，使用默认图标"
fi

# ── Info.plist ──
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleExecutable</key><string>Markable</string>
    <key>CFBundleIdentifier</key><string>com.markable.reader</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Markable</string>
    <key>CFBundleDisplayName</key><string>Markable</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>com.markable.reader.command</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>CFBundleURLSchemes</key>
            <array><string>markable</string></array>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Markdown 文档</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>net.daringfireball.markdown</string><string>public.plain-text</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# ── App Intents 元数据抽取（SwiftPM 无 Xcode 构建阶段，手动补上）──
TOOLCHAIN="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
PROCESSOR="$TOOLCHAIN/usr/bin/appintentsmetadataprocessor"
if [ -x "$PROCESSOR" ]; then
  XCODE_VERSION="$(xcodebuild -version 2>/dev/null | sed -n '2p' | awk '{print $3}')"
  SDK_ROOT="$(xcrun --show-sdk-path)"
  ARCH="$(uname -m)"
  find "$APP_DIR/Sources" -name '*.swift' | sort > "$TMP/srcs.txt"
  find "$APP_DIR/.build" -type d -name 'Objects-normal' -path "*Markable.build*" -exec find {} -name '*.swiftconstvalues' \; \
    | sort > "$TMP/constvals.txt"

  if [ -s "$TMP/constvals.txt" ]; then
    "$PROCESSOR" --output "$TMP/out" \
      --toolchain-dir "$TOOLCHAIN" \
      --module-name Markable \
      --sdk-root "$SDK_ROOT" \
      --xcode-version "${XCODE_VERSION:-1.0}" \
      --platform-family macosx \
      --deployment-target 14.0 \
      --target-triple "${ARCH}-apple-macos14.0" \
      --source-file-list "$TMP/srcs.txt" \
      --swift-const-vals-list "$TMP/constvals.txt" \
      --force --quiet-warnings >/dev/null 2>&1 || true

    if [ -d "$TMP/out/Metadata.appintents" ]; then
      cp -R "$TMP/out/Metadata.appintents" "$APP/Contents/Resources/"
      echo "✅ App Intents 元数据已嵌入"
    else
      echo "⚠️ App Intents 元数据未生成（不影响其余功能）"
    fi
  fi
fi

# ── 签名（ad-hoc，本地运行足够）──
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
  && echo "✅ 已 ad-hoc 签名" || echo "⚠️ 签名失败（本地仍可运行）"

# ── 注册 ──
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true

# ── 归档 ──
if [ "$MAKE_ZIP" = "1" ]; then
  ZIP="$OUT_DIR/Markable-${VERSION}.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "✅ 已归档：$ZIP"
fi

# ── 安装 ──
if [ "$INSTALL" = "1" ]; then
  pkill -x Markable >/dev/null 2>&1 || true
  if [ -w /Applications ]; then
    DEST="/Applications/Markable.app"
  else
    mkdir -p "$HOME/Applications"
    DEST="$HOME/Applications/Markable.app"
  fi
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  # 重新注册，并让 LaunchServices 尽快看到这份新安装
  [ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
  echo "✅ 已安装：$DEST"
  # 把 .md 的默认打开程序指向刚安装的版本（Finder 双击即打开最新版）
  if swift "$SCRIPT_DIR/set-default-md.swift" "$DEST"; then
    echo "✅ .md 默认打开程序 → $DEST"
  else
    echo "⚠️ 未能设置 .md 默认关联（可手动：右键 .md → 显示简介 → 打开方式）"
  fi
  echo "   启动：open -a '$DEST'"
  echo "   URL： open 'markable://open?path=%2Ftmp%2Fdemo.md'"
fi

echo "✅ 打包完成：$APP（$CONFIG，v${VERSION}）"
