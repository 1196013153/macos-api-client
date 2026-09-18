#!/usr/bin/env bash
#
# 打包成可双击运行的 macOS .app。
#
#   ./Scripts/build-app.sh              # release
#   CONFIGURATION=debug ./Scripts/build-app.sh
#
# 产物：dist/API Client.app
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="API Client"
EXECUTABLE="APIClient"
BUNDLE_ID="dev.leafwin.apiclient"
SHORT_VERSION="1.0.0"
BUILD_VERSION="1"

echo "==> 编译（${CONFIGURATION}）"
swift build -c "$CONFIGURATION"

BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "==> 组装 bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"

# 图标缺失时也能构建，只是 Dock 里显示默认图标
ICON_ENTRY=""
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  ICON_ENTRY="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
  echo "    （未找到 Resources/AppIcon.icns，跳过图标；可执行 swift Scripts/make-icon.swift Resources 生成）"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  $ICON_ENTRY
</dict>
</plist>
PLIST

# 本地自用无需开发者证书；ad-hoc 签名能让系统稳定记住 bundle 身份（Dock 图标、权限授权）。
if command -v codesign >/dev/null 2>&1; then
  if codesign --force --sign - "$APP" >/dev/null 2>&1; then
    echo "==> 已做 ad-hoc 签名"
  else
    echo "==> 跳过签名（不影响本机运行）"
  fi
fi

echo ""
echo "构建完成：$APP"
echo "启动：open \"$APP\""
