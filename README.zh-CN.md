# TodoBar

一个轻量、原生的 macOS 菜单栏待办应用。原地记录和编辑事项，将清单收纳到桌面侧边，按自己的节奏设置提醒。使用 SwiftUI 构建，采用克制的毛玻璃界面，任务保存在本机。

[English](README.md) · [v1.1.0 正式版](https://github.com/yueseqaz/todobar/releases/tag/v1.1.0) · [下载 Apple Silicon 安装包](https://github.com/yueseqaz/todobar/releases/download/v1.1.0/TodoBar-macos-arm64.zip) · [更新说明](RELEASE_NOTES.md)

## 下载与安装

**当前正式版：v1.1.0。适用于 macOS 13 及以上的 Apple Silicon（M 系列）Mac，发布包不支持 Intel Mac。**

1. 从[官方 Release](https://github.com/yueseqaz/todobar/releases/tag/v1.1.0) 下载 `TodoBar-macos-arm64.zip` 和 `SHA256SUMS.txt`。
2. 将两个文件放在同一文件夹，在终端进入该文件夹后校验：

   ```bash
   shasum -a 256 -c SHA256SUMS.txt
   ```

   确认输出为 `TodoBar-macos-arm64.zip: OK` 后再继续。
3. 解压安装包，将 `TodoBar.app` 移至「应用程序」。如果旧版正在运行，请先退出，再打开新版。
4. 启动后，在菜单栏找到**清单图标**。TodoBar 不显示 Dock 图标，这是预期行为。

发布包由 GitHub Actions 编译并临时签名，但**未经 Apple Developer ID 签名或 Apple 公证**。首次运行前请阅读[安装说明](INSTALL_BEFORE_USE.txt)。若被 macOS 拦截，请确认来源后按当前系统版本提供的安全提示处理，不要关闭 Gatekeeper 或运行来源不明的绕过命令。

## 主要功能

| 功能 | 说明 |
| --- | --- |
| 简洁菜单栏 | 使用固定的单色清单图标，不显示待办数量，不占用 Dock。 |
| 毛玻璃桌面小组件 | 收起时是紧贴屏幕侧边的小标签，展开为毛玻璃待办面板；支持左右停靠、上下拖动、按屏幕保存位置，以及仅主屏幕或所有屏幕显示。 |
| 原地新建 | 在待办列表顶部输入内容，回车即可添加；默认中优先级、今天，可按需调整优先级和日期。未提交的草稿在收起面板或编辑其他事项后仍会保留。 |
| 原地编辑 | 点击事项直接在条目内修改内容、优先级和日期；回车或点击别处保存并收起，空标题不会覆盖原事项。主动点到输入区外会释放焦点。 |
| 轻量完成状态 | 已完成事项使用删除线和弱化文字；鼠标悬停或键盘聚焦时出现「完成 / 恢复」入口，不使用醒目的圆形勾选框。 |
| 全局快速收集 | 在任意应用中按 `Option + Command + T`，打开轻量输入窗口，使用相同的内容、优先级和日期控件。 |
| 自定义桌面提醒 | 默认每天 15:00 和 21:00 显示「今日待办清单」；在独立设置窗口添加、修改或删除时间点，自定义每天提醒次数。仅提醒当天到期且未完成的事项，无待办时不打扰。 |
| 日期分组 | 明确区分**已推迟**、**当天待完成**与**未来待完成**。 |
| 集中设置 | 右键菜单栏图标 → 设置…，在独立窗口统一管理提醒、桌面小组件、显示屏幕、停靠侧边及语言（简体中文 / English）；更改自动保存。 |
| 本地优先 | 任务仅保存在本机的 Application Support 目录。 |

## 日常使用

| 操作 | 方式 |
| --- | --- |
| 打开待办 | 点击菜单栏清单图标；开启桌面小组件后，点击图标可展开或收起小组件。 |
| 新建事项 | 在列表顶部输入内容，回车添加；默认中优先级、今天到期。 |
| 编辑事项 | 点击事项文字原地修改，回车或点击输入区外保存。 |
| 完成或恢复 | 鼠标悬停在条目上，或通过键盘聚焦操作入口，再点击「完成 / 恢复」。 |
| 快速收集 | 按 `Option + Command + T`，输入后回车添加并关闭窗口。 |
| 打开设置 | 右键菜单栏图标，选择「设置…」。 |
| 移动侧边标签 | 在设置中开启「常驻桌面」，将收起的小标签上下拖动。 |

### 提醒设置

- 默认每天提醒两次：**15:00、21:00**，使用 Mac 的本地时间。
- 在设置中添加、删除或修改时间点；时间点数量就是每天提醒次数，同一时间不能重复添加。
- 时间输入采用 24 小时制，输入两位小时后自动选中分钟；例如先输入 `15`，再输入 `30`，即为 `15:30`。
- 开关开启时显示蓝色；关闭提醒后保留已设时间，所有设置更改自动保存。
- 「今日待办清单」**仅提醒明确设置为今天到期、且尚未完成的事项**，不包含逾期或未设日期的事项；没有符合条件的待办时不弹窗。
- 请保持 TodoBar 运行。提醒以应用自己的窗口显示，不是 macOS 通知横幅；重新打开应用或电脑唤醒后，只补提醒当天最近一个尚未处理的时间点，不连续补弹多个提醒。
- 提醒窗口支持「30 分钟后再提醒」。

### 本地数据

任务文件保存在 `~/Library/Application Support/TodoBar/tasks.json`；提醒时间、语言和小组件选项保存在本机的 macOS 偏好设置中。当前版本不提供云同步。

## 本地构建

```bash
chmod +x build.sh
./build.sh
open dist/TodoBar.app
```

完整应用包（含应用图标）位于 `dist/TodoBar.app`。`.build/TodoBar` 只是裸可执行文件，运行和分发请使用 `.app` 应用包。

> 提示：若编译报错 `plugin for module 'SwiftUIMacros' not found`，说明当前 Command Line Tools 缺少 SwiftUI 宏插件（部分版本的已知问题）。安装完整 Xcode，或将 [swift.org 独立工具链](https://www.swift.org/install/macos/) 解压到 `~/Library/Developer/Toolchains/` 即可解决；`build.sh` 会自动优先使用后者。

## 运行测试

```bash
zsh Tests/run-widget-tests.sh
```

测试覆盖原地新建与编辑、焦点和外部点击、侧边标签拖动与位置、提醒持久化与调度，以及分段时间输入。测试按当前机器架构运行，发布应用仍构建为 arm64。

## 自动发布

每次推送到 `main`，GitHub Actions 会执行回归测试、编译 arm64 应用、检查签名和应用图标，并上传构建产物。

推送版本标签（`vX.Y.Z`）后，工作流还会使用 [RELEASE_NOTES.md](RELEASE_NOTES.md) 创建 GitHub Release，包含：

- `TodoBar-macos-arm64.zip`
- `SHA256SUMS.txt`

维护者发布新版本时，应选择未使用过的标签，并与 `Resources/Info.plist` 中的 `CFBundleShortVersionString` 一致；工作流会检查标签与应用版本是否匹配。不要移动已有发布标签来替换构建。

## 项目结构

```text
Sources/TodoBarApp.swift       SwiftUI 应用源码
Resources/Info.plist           应用元数据与语言声明
Resources/TodoBar.icns         午夜蓝像素风应用图标
Tests/                        回归测试
RELEASE_NOTES.md               当前版本更新说明
build.sh                       本地 macOS 构建脚本
.github/workflows/release.yml  CI 构建与标签发布工作流
```

## 提示

- Dock 中没有图标是正常现象：TodoBar 是菜单栏应用。
- 若 `Option + Command + T` 无法打开快速收集，请检查是否与其他应用的快捷键冲突。
- 更新时先退出旧版再替换应用。应用包与本地任务文件分开存放，替换应用不会修改任务文件；有需要时可提前备份该文件。
