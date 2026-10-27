# TodoBar

A lightweight native macOS menu bar to-do app for capturing work before it slips away. TodoBar is built with SwiftUI and keeps tasks local to your Mac.

> 中文文档请见 [README.zh-CN.md](README.zh-CN.md)。安装前请先阅读 [INSTALL_BEFORE_USE.txt](INSTALL_BEFORE_USE.txt)。

## Highlights

| Capability | Details |
| --- | --- |
| Menu bar workflow | Keep the task list one click away without a Dock window. |
| Glass desktop widget | Pin the panel to the desktop from the menu-bar panel: real-time acrylic blur, draggable and auto-snapped to the left or right screen edge; the menu-bar icon toggles between expanded and collapsed; the panel header shows today's completion progress. |
| Three-step creation | Create a task in order: content, priority, then date. |
| Global quick capture | Press `Option + Command + T` from any app to capture a task. |
| Evening desktop reminder | At 9 PM, TodoBar shows its own floating desktop window for unfinished tasks due today. |
| Date-aware groups | See **Overdue**, **Due today**, and **Upcoming** tasks separately. |
| Bilingual UI | Right-click the menu-bar icon → Settings → Language to switch between Simplified Chinese and English; the right-click menu also opens the panel, toggles the desktop widget, and quits. |
| Local-first data | Tasks are stored locally in your Application Support directory. |

## Requirements

TodoBar currently targets **macOS 13 or later** on **Apple Silicon** Macs.

## Build locally

```bash
chmod +x build.sh
./build.sh
open dist/TodoBar.app
```

The built application is placed at `dist/TodoBar.app`.

> Note: if the build fails with `plugin for module 'SwiftUIMacros' not found`, your Command Line Tools is missing the SwiftUI macro plugin (a known issue in some CLT versions). Install full Xcode, or extract a standalone [swift.org toolchain](https://www.swift.org/install/macos/) into `~/Library/Developer/Toolchains/` — `build.sh` automatically prefers it.

## Install safely

Read [INSTALL_BEFORE_USE.txt](INSTALL_BEFORE_USE.txt) before opening a downloaded release. Public release builds are not Apple-notarized; verify the checksum and use Finder’s standard **Control-click → Open** flow only after confirming the release source.

## Release automation

GitHub Actions builds an arm64 macOS package on every push to `main` and uploads it as a workflow artifact. Push a version tag such as `v1.0.0` to create a GitHub Release containing:

- `TodoBar-macos-arm64.zip`
- `SHA256SUMS.txt`

```bash
git tag v1.0.0
git push origin v1.0.0
```

## Project structure

```text
Sources/TodoBarApp.swift       SwiftUI application source
Resources/Info.plist           App metadata and localization declaration
Resources/TodoBar.icns         Midnight-blue pixel app icon
build.sh                       Local macOS build script
.github/workflows/release.yml  CI build and tag-release workflow
```

## Notes

Keep TodoBar running if you want the 9 PM desktop reminder. It does not schedule macOS notification banners. If `Option + Command + T` does not open quick capture, check for another app using the same shortcut.
