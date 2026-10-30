# TodoBar 1.1.1

## 中文

- `Option + Command + T` 支持切换快速收集窗口：按一次打开，再按一次关闭，未提交的内容、优先级和日期会保留。
- 添加成功后关闭输入窗口，在原位置显示轻量的「已添加」提示和事项名称，约 1 秒后淡出；不抢焦点、不拦截点击，也不发送系统通知。
- 加固快速开关窗口时的焦点与回调处理，避免之前排队的失焦或提交回调影响当前输入。
- 增加快捷键切换、草稿保留、空内容与重复提交保护，以及提示窗口焦点行为的回归测试。
- 中英文 README 同步功能说明，并配上快速收集与成功提示截图。

## English

- `Option + Command + T` toggles quick capture open and closed, preserving the unsent title, priority, and date.
- Successful capture closes the input and briefly shows Added with the task title in the same location. The confirmation fades after about a second, without taking focus, intercepting clicks, or sending a system notification.
- Guarded focus and submission callbacks prevent a previous opening from interfering with the current capture session.
- Added regression coverage for toggling, draft retention, blank and duplicate submissions, and nonactivating feedback windows.
- Updated both README guides with quick-capture instructions and screenshots.

## 安装 / Installation

- 适用于 Apple Silicon（M 系列）Mac，macOS 13 或更高版本。
- Download `TodoBar-macos-arm64.zip`, extract it, and move `TodoBar.app` to Applications.
- 下载后请解压，将 `TodoBar.app` 移至「应用程序」，并核对 `SHA256SUMS.txt`。
- Built and ad-hoc signed by GitHub Actions; not Apple Developer ID signed or notarized. Review [installation guidance](https://github.com/yueseqaz/todobar/blob/v1.1.1/INSTALL_BEFORE_USE.txt) before first launch.
- 发布包未经 Apple Developer ID 签名或 Apple 公证，首次运行可能出现 macOS 安全提示；请先阅读安装说明，不要关闭系统安全保护。
