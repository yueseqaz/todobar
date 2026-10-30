#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

# Compile tests alongside the app types without launching the app's entry point.
sed '/^@main$/d' "$ROOT/Sources/TodoBarApp.swift" > "$TEST_DIR/WidgetEdgeTabTests.swift"
cat "$ROOT/Tests/InlineTaskComposerTests.swift" >> "$TEST_DIR/WidgetEdgeTabTests.swift"
cat "$ROOT/Tests/InlineTaskEditingTests.swift" >> "$TEST_DIR/WidgetEdgeTabTests.swift"
cat "$ROOT/Tests/ReminderSettingsTests.swift" >> "$TEST_DIR/WidgetEdgeTabTests.swift"
cat "$ROOT/Tests/ReminderTimeInputTests.swift" >> "$TEST_DIR/WidgetEdgeTabTests.swift"
cat "$ROOT/Tests/WidgetEdgeTabTests.swift" >> "$TEST_DIR/WidgetEdgeTabTests.swift"
swiftc -swift-version 5 -parse-as-library \
  -sdk "${SDKROOT:-$(xcrun --show-sdk-path)}" \
  -target "$(uname -m)-apple-macosx13.0" \
  -framework SwiftUI -framework AppKit -framework Carbon -framework UserNotifications \
  "$TEST_DIR/WidgetEdgeTabTests.swift" -o "$TEST_DIR/WidgetEdgeTabTests"
"$TEST_DIR/WidgetEdgeTabTests"
