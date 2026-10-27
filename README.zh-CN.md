# TodoBar

一个轻量、原生的 macOS 菜单栏待办应用。TodoBar 使用 SwiftUI 构建，将任务保留在本机，帮助你先记下要做的事，再安排完成节奏。

> English documentation: [README.md](README.md)。安装前请阅读 [INSTALL_BEFORE_USE.txt](INSTALL_BEFORE_USE.txt)。

## 主要功能

| 功能 | 说明 |
| --- | --- |
| 菜单栏工作流 | 不需要常驻 Dock 窗口，点击菜单栏即可查看任务。 |
| 玻璃桌面小组件 | 在菜单栏面板点击图钉，即可把待办常驻到桌面：实时亚克力模糊质感、可拖动换位、右键可吸附到屏幕四角；点收纳按钮缩成小玻璃圆标，点击圆标随时恢复。 |
| 三步创建 | 依次填写待办内容、选择优先级、选择日期。 |
| 全局快速收集 | 在任意应用中按 `Option + Command + T`，即可快速记下一件待办。 |
| 夜间桌面提醒 | 每晚 21:00，直接在桌面显示当天未完成待办的小窗口。 |
| 日期分组 | 明确区分**已推迟**、**当天待完成**与**未来待完成**。 |
| 中英文切换 | 在菜单栏面板顶部的语言控件中切换简体中文或 English。 |
| 本地优先 | 任务仅保存在本机的 Application Support 目录。 |

## 系统要求

当前版本面向 **macOS 13 或更高版本**的 **Apple Silicon（M 系列）Mac**。

## 本地构建

```bash
chmod +x build.sh
./build.sh
open dist/TodoBar.app
```

构建结果位于 `dist/TodoBar.app`。

> 提示：若编译报错 `plugin for module 'SwiftUIMacros' not found`，说明当前 Command Line Tools 缺少 SwiftUI 宏插件（部分版本的已知问题）。安装完整 Xcode，或将 [swift.org 独立工具链](https://www.swift.org/install/macos/) 解压到 `~/Library/Developer/Toolchains/` 即可解决；`build.sh` 会自动优先使用后者。

## 安全安装

下载 Release 后，请先阅读 [INSTALL_BEFORE_USE.txt](INSTALL_BEFORE_USE.txt)。公开 Release 未经过 Apple 公证；请先核对校验值，再仅通过 Finder 的 **Control 点击 → 打开** 标准流程启动可信来源的应用。

## 自动发布

GitHub Actions 会在每次推送到 `main` 时构建 arm64 macOS 包，并上传为工作流构建产物。推送版本标签后，例如 `v1.0.0`，工作流会自动创建 GitHub Release，内容包括：

- `TodoBar-macos-arm64.zip`
- `SHA256SUMS.txt`

```bash
git tag v1.0.0
git push origin v1.0.0
```

## 项目结构

```text
Sources/TodoBarApp.swift       SwiftUI 应用源码
Resources/Info.plist           应用元数据与语言声明
Resources/TodoBar.icns         午夜蓝像素风应用图标
build.sh                       本地 macOS 构建脚本
.github/workflows/release.yml  CI 构建与标签发布工作流
```

## 提示

若希望收到每晚 21:00 的桌面提醒，请让 TodoBar 保持运行。该提醒不会调度 macOS 系统通知横幅；若 `Option + Command + T` 没有唤起快速收集，请检查是否与其他应用快捷键冲突。
