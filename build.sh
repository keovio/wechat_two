#!/bin/bash
# 组装 WeChatMulti.app。
#
# 关键：管理器自身**不能启用 App Sandbox**，否则无法写 ~/Library/Application Support/WeChatMulti、
# 无法对任意路径执行 codesign、也读不到 /Applications/WeChat.app。
# 这里用 ad-hoc 签名且不带任何 entitlements，因此天然无沙盒。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="WeChatMulti"
# 版本号可由 CI 注入：APP_VERSION=0.2.0 APP_BUILD=12 ./build.sh
APP_VERSION="${APP_VERSION:-0.2.0}"
APP_BUILD="${APP_BUILD:-1}"

# ---- 工具链选择 ----------------------------------------------------------
# 本机 CommandLineTools 的 swiftc 与它自带的 MacOSX15.0.sdk 版本错配
# （SDK 由 swiftlang-6.0.0.7.24 构建，swiftc 是 6.0.0.9.10），会报
# "this SDK is not supported by the compiler"。Xcode 16.2 的 Swift 6.0.3 + SDK 15.2 是匹配的，
# 所以只要装了 Xcode 就优先用它。
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# ---- 缓存重定向 ----------------------------------------------------------
# 某些受限环境下 ~/Library/Caches 与 /var/folders 不可写，
# 把模块缓存与临时目录一起挪到工程内。
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang"
export TMPDIR="$PWD/.cache/tmp"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$TMPDIR"

echo "==> 工具链：$( xcrun --find swiftc 2>/dev/null || echo 系统默认 )"
echo "==> 编译（release）"
# --disable-sandbox：SwiftPM 默认会再套一层 sandbox-exec，在被沙箱限制的进程里会失败。
swift build -c release --disable-sandbox \
    --cache-path .cache/spm --scratch-path .cache/scratch

APP=".cache/scratch/release/$APP_NAME.app"
BIN=".cache/scratch/release/$APP_NAME"

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>WeChatMulti</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.wechatmulti</string>
    <key>CFBundleName</key>
    <string>微信多开</string>
    <key>CFBundleDisplayName</key>
    <string>微信多开</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> 生成 App 图标"
ICON_SRC="Resources/AppIcon-1024.png"
if [ -f "$ICON_SRC" ]; then
    ICONSET=".cache/tmp/AppIcon.iconset"
    rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    for sz in 16 32 128 256 512; do
        sips -z $sz $sz "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
        sips -z $((sz*2)) $((sz*2)) "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" "$APP/Contents/Info.plist"

echo "==> 签名（ad-hoc，无 entitlements）"
codesign --force --sign - --timestamp=none "$APP"
codesign -v --verbose=2 "$APP" 2>&1 | head -3 || true

# 让 LaunchServices 立刻认识它，否则 open 可能找不到。
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$(pwd)/$APP" || true

echo
echo "完成：$(pwd)/$APP"
echo "运行：open '$(pwd)/$APP'"
