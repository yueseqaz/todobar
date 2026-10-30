# TodoBar

A lightweight native macOS menu bar to-do app. Capture and edit tasks in place, keep a compact list at the edge of your desktop, and set reminders that follow your daily rhythm. Built with SwiftUI, with a restrained frosted-glass interface and local task storage.

[中文](README.zh-CN.md) · [v1.1.0 release](https://github.com/yueseqaz/todobar/releases/tag/v1.1.0) · [Download for Apple Silicon](https://github.com/yueseqaz/todobar/releases/download/v1.1.0/TodoBar-macos-arm64.zip) · [Release notes](RELEASE_NOTES.md)

## Download and install

**Current release: v1.1.0. Requires an Apple Silicon (M-series) Mac running macOS 13 or later. The release package does not support Intel Macs.**

1. Download `TodoBar-macos-arm64.zip` and `SHA256SUMS.txt` from the [official release](https://github.com/yueseqaz/todobar/releases/tag/v1.1.0).
2. Place both files in the same folder and verify the archive from Terminal:

   ```bash
   shasum -a 256 -c SHA256SUMS.txt
   ```

   Continue only if the output is `TodoBar-macos-arm64.zip: OK`.
3. Extract the archive and move `TodoBar.app` to Applications. Quit any older running copy before opening the new one.
4. Open the app and look for the **checklist icon in the menu bar**. TodoBar intentionally has no Dock icon.

Release packages are built and ad-hoc signed by GitHub Actions, but are **not Apple Developer ID signed or Apple-notarized**. Read [the installation guidance](INSTALL_BEFORE_USE.txt) before first launch. If macOS blocks the app, follow the security prompts for your macOS version after confirming the source; do not disable Gatekeeper or run unknown bypass commands.

## Highlights

| Capability | Details |
| --- | --- |
| Clean menu bar | A stable, monochrome checklist icon opens your tasks, without a task count or a Dock window. |
| Glass desktop widget | A compact edge tab expands into a frosted-glass task panel. Dock it on either side, drag it vertically, and save its position per display; choose the main display or all displays in Settings. |
| Inline creation | Add tasks at the top of the list and press Return; medium priority and today are the defaults, with optional priority and date controls. Unsent drafts survive collapsing the panel or editing another task. |
| Inline editing | Edit content, priority, and date directly in a task row. Return or clicking elsewhere saves valid changes and closes the editor; empty titles leave the original task intact. Outside clicks release input focus. |
| Quiet completion controls | Completed titles use strikethrough and dimmed text. Complete / Restore actions appear on hover or keyboard focus, without prominent circular checkboxes. |
| Global quick capture | Press `Option + Command + T` from any app to open a compact capture window with the same title, priority, and date controls. |
| Custom daily reminders | A floating Today's to-do list shows unfinished tasks due today at 3 PM and 9 PM by default. Add, edit, or remove times in Settings to choose your daily frequency. No tasks, no interruption. |
| Date-aware groups | See **Overdue**, **Due today**, and **Upcoming** tasks separately. |
| Consolidated Settings | Right-click the menu-bar icon → Settings… to manage reminders, the desktop widget, displays, dock side, and language (Simplified Chinese / English) in one window. Changes save automatically. |
| Local-first data | Tasks are stored locally in your Application Support directory. |

## Everyday use

| Action | How |
| --- | --- |
| Open tasks | Click the menu-bar checklist icon. With the desktop widget enabled, this expands or collapses the widget. |
| Add a task | Type at the top of the list and press Return. Priority defaults to Medium and the date to Today. |
| Edit a task | Click its text, edit in place, then press Return or click outside the editor to save. |
| Complete or restore | Hover over a row, or focus its action with the keyboard, then choose Complete / Restore. |
| Quick capture | Press `Option + Command + T`; Return adds the task and closes the capture window. |
| Open Settings | Right-click the menu-bar icon and choose Settings… |
| Move the desktop tab | Enable Pin to desktop in Settings, then drag the collapsed edge tab up or down. |

### Reminders

- Default: **twice daily, at 15:00 and 21:00**, using your Mac's local time.
- In Settings, add, remove, or edit reminder times. The number of saved times determines the daily frequency; duplicate times are not allowed.
- Time entry uses 24-hour hours and minutes: typing two hour digits automatically selects minutes. For example, type `15`, then `30`, for `15:30`.
- Enabled switches are blue. Turning reminders off preserves your saved times; all setting changes save automatically.
- The reminder shows **only unfinished tasks with a due date of today**, not overdue or undated tasks. No matching tasks means no popup.
- Keep TodoBar running. Reminders use TodoBar's own window, not macOS notification banners. After launch or wake, only the latest unhandled time for today is caught up, not every missed time.
- The reminder window offers a 30-minute snooze.

### Local data

Tasks are saved at `~/Library/Application Support/TodoBar/tasks.json`. Reminder times, language, and widget preferences are saved in local macOS preferences. This version does not provide cloud sync.

## Build locally

```bash
chmod +x build.sh
./build.sh
open dist/TodoBar.app
```

The full application bundle, including its app icon, is placed at `dist/TodoBar.app`. `.build/TodoBar` is only the executable; use the `.app` bundle to launch or distribute TodoBar.

> Note: if the build fails with `plugin for module 'SwiftUIMacros' not found`, your Command Line Tools is missing the SwiftUI macro plugin (a known issue in some CLT versions). Install full Xcode, or extract a standalone [swift.org toolchain](https://www.swift.org/install/macos/) into `~/Library/Developer/Toolchains/` — `build.sh` automatically prefers it.

## Tests

```bash
zsh Tests/run-widget-tests.sh
```

Tests cover inline creation and editing, focus and outside-click behavior, edge-tab dragging and placement, reminder persistence and scheduling, and segmented time entry. The tests run on the host architecture; release applications are built for arm64.

## Release automation

GitHub Actions runs the regression tests, builds the arm64 application, verifies its signature and bundled icon, and uploads build artifacts on pushes to `main`.

Version tags (`vX.Y.Z`) additionally create a GitHub Release using [RELEASE_NOTES.md](RELEASE_NOTES.md), with:

- `TodoBar-macos-arm64.zip`
- `SHA256SUMS.txt`

For maintainers: use an unused tag matching `CFBundleShortVersionString` in `Resources/Info.plist`. The workflow checks that the tag and app version match. Do not move existing release tags to publish a different build.

## Project structure

```text
Sources/TodoBarApp.swift       SwiftUI application source
Resources/Info.plist           App metadata and localization declaration
Resources/TodoBar.icns         Midnight-blue pixel app icon
Tests/                        Regression tests
RELEASE_NOTES.md               Current release notes
build.sh                       Local macOS build script
.github/workflows/release.yml  CI build and tag-release workflow
```

## Notes

- No Dock icon is expected: TodoBar is a menu-bar application.
- If `Option + Command + T` does not open quick capture, check for another app using the same shortcut.
- When updating, quit the running copy before replacing it. Replacing the app does not change the separate local task file; back up that file if needed.
