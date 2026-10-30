# TodoBar

A lightweight native macOS menu bar to-do app for capturing work before it slips away. TodoBar is built with SwiftUI and keeps tasks local to your Mac.

> 中文文档请见 [README.zh-CN.md](README.zh-CN.md)。安装前请先阅读 [INSTALL_BEFORE_USE.txt](INSTALL_BEFORE_USE.txt)。

## Highlights

| Capability | Details |
| --- | --- |
| Menu bar workflow | Keep the task list one click away without a Dock window. |
| Glass desktop widget | Pin the panel to the desktop from the menu-bar panel: real-time acrylic blur, draggable and auto-snapped to the left or right screen edge; show it on the main display or on every display from Settings; the menu-bar icon toggles between expanded and collapsed; the panel header shows today's completion progress. |
| Inline creation | Add tasks at the top of the list and press Return; medium priority and today are the defaults, with optional priority and date controls. Unsent drafts survive collapsing the panel or editing another task. |
| Inline editing | Edit content, priority, and date directly in a task row. Return or clicking elsewhere saves valid changes and closes the editor; empty titles leave the original task intact. Outside clicks release input focus. |
| Global quick capture | Press `Option + Command + T` from any app to capture a task. |
| Custom daily reminders | A floating Today's to-do list shows unfinished tasks due today at 3 PM and 9 PM by default. Add, edit, or remove times in Settings to choose your daily frequency. No tasks, no interruption. |
| Date-aware groups | See **Overdue**, **Due today**, and **Upcoming** tasks separately. |
| Consolidated Settings | Right-click the menu-bar icon → Settings… to manage reminders, the desktop widget, displays, dock side, and language (Simplified Chinese / English) in one window. Changes save automatically. |
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

Keep TodoBar running to receive desktop reminders. The default is twice daily (3 PM and 9 PM); change, add, remove, or disable reminder times in Settings. After launch or wake, only the latest unhandled reminder for today is shown, never a burst of missed reminders. It does not schedule macOS notification banners. If `Option + Command + T` does not open quick capture, check for another app using the same shortcut.
