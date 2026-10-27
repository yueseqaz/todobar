#!/bin/zsh
set -euo pipefail
setopt NULL_GLOB

ROOT="${0:A:h}"
APP_NAME="TodoBar"
BUILD_DIR="$ROOT/.build"
APP_DIR="$ROOT/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$BUILD_DIR" "$APP_DIR"
mkdir -p "$BUILD_DIR" "$MACOS_DIR" "$RESOURCES_DIR"

# 优先使用已安装的 Swift.org 工具链：部分 Command Line Tools 版本缺少
# SwiftUI 宏插件（libSwiftUIMacros），会导致 @State 等宏无法展开
SWIFTC="$(command -v swiftc)"
for candidate in \
  "$HOME/Library/Developer/Toolchains"/*.xctoolchain/usr/bin/swiftc \
  "/Library/Developer/Toolchains"/*.xctoolchain/usr/bin/swiftc; do
  if [[ -x "$candidate" ]]; then
    SWIFTC="$candidate"
    break
  fi
done

SDK_ARGS=()
if command -v xcrun >/dev/null 2>&1; then
  sdk_path="$(xcrun --show-sdk-path 2>/dev/null || true)"
  if [[ -n "$sdk_path" ]]; then
    SDK_ARGS=(-sdk "$sdk_path")
  fi
fi

"$SWIFTC" \
  -swift-version 5 \
  -parse-as-library \
  -target arm64-apple-macosx13.0 \
  ${SDK_ARGS[@]} \
  -framework SwiftUI \
  -framework AppKit \
  -framework Carbon \
  -framework UserNotifications \
  "$ROOT/Sources/TodoBarApp.swift" \
  -o "$BUILD_DIR/$APP_NAME"

cp "$BUILD_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
if [[ -f "$ROOT/Resources/TodoBar.icns" ]]; then
  cp "$ROOT/Resources/TodoBar.icns" "$RESOURCES_DIR/TodoBar.icns"
fi
for localization in "$ROOT"/Resources/*.lproj; do
  [[ -d "$localization" ]] || continue
  cp -R "$localization" "$RESOURCES_DIR/"
done

codesign --force --deep --sign - "$APP_DIR"

echo "构建完成：$APP_DIR"
