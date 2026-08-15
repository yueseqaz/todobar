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

swiftc \
  -swift-version 5 \
  -parse-as-library \
  -target arm64-apple-macosx13.0 \
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
