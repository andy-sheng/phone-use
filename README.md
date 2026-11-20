# phone-use

在 macOS 上连接、预览和操作 iPhone 与 Android 真机以及本机的 iOS 模拟器，提供原生应用、命令行和 MCP 服务。iOS 与 Android 的连接、输入和视频流分别实现，共用设备列表与预览界面。

本仓库目前同时包含三部分，稳定后会拆分为独立仓库：

| 部分 | 内容 | 面向 |
| --- | --- | --- |
| PhoneUseKit | 设备 framework：`PhoneUseKit`、`PhoneUseUI` 与 Python 守护进程 `devicehubd` | 两个应用 |
| phone-use | 应用、CLI、MCP 服务 | 开发者与 AI 代理 |
| automation | 基于 MaaFramework 的插件运行底座，见[插件自动化](Automation/README.md) | 游戏代打用户 |

两个应用都只依赖 PhoneUseKit，各自带一份守护进程，状态目录也彼此独立。

## 获取仓库资源

仓库使用 Git LFS 管理测试图片等二进制资源。安装 Git LFS 后，在克隆的仓库中执行：

```sh
git lfs install --local
git lfs pull
```

下载生成的 ADB、OCR 模型和 scrcpy由下方的准备脚本写入 `.build/`，不提交到 Git。
项目协作、目录职责和测试命令见 [AGENTS.md](AGENTS.md)。

## 开发运行

需要 Apple silicon Mac、macOS 15 或更新版本、Xcode 和 Python 3.13。生成 Xcode 工程还需要 XcodeGen。Android 支持使用独立的 Android SDK Platform-Tools，无需安装 Android Studio；`setup-dev.sh` 会下载并校验固定版本的 ADB 和 scrcpy。

```sh
scripts/setup-dev.sh
swift run phone-use-app

# automation 另需插件运行环境；任务通过 .build/debug/automation-bridge 连接设备。
scripts/setup-automation.sh
swift build && swift run automation-app
```

应用运行后，可以使用 CLI 操作已连接设备：

```sh
.build/debug/phone-use list
.build/debug/phone-use --device android:SERIAL screenshot .build/android.png
```

Android 设备需要启用 USB 调试并授权电脑；输入控制还可能需要厂商的 USB 调试安全设置。

### 本地 Web 视频预览

应用或守护进程运行后，可用 CLI 启动本地 HTTP 视频预览与控制：

```sh
swift build --product phone-use
.build/debug/phone-use serve 8765
# 指定设备（省略时选择第一台就绪设备）
.build/debug/phone-use --device android:SERIAL serve 8765
```

打开 `http://127.0.0.1:8765/`。`/stream.mjpeg` 是可直接用于 `<img>` 的 MJPEG 流，
`/snapshot.jpg` 返回流的最新画面，`/health` 返回设备、视频来源和输出帧数。
服务只监听本机 IPv4 回环地址，按 Ctrl-C 停止；USB iPhone 首次使用需要允许摄像头权限。

在网页画面上点击、长按或拖动后松开，可执行点击、长按和直线滑动（最长两秒）；按 Esc
或切出网页可取消尚未提交的手势。下方提供 Home、音量和锁屏 / 唤醒，Android 另外提供返回和多任务。
手势在松开后执行，不是实时跟手拖拽，不支持多指触控。设备操作失败会显示原因，不自动重试。
物理 iPhone 的触控使用竖屏坐标；画面方向与设备输入尺寸不一致时会拒绝触控，避免点错位置。

网页通过 `POST /input` 提交操作，使用每次服务启动随机生成的 `X-PhoneUse-Token`，
并校验来源和 JSON 参数；不同网页的操作不会并发执行。服务重启后需要刷新网页。设备尚未输出视频时页面保持等待，`/health` 的 `frames` 为 0，截图返回 503。
单独嵌入下方 `<img>` 只显示视频，不包含控制界面。

MCP 的 `connect_device` 会校验 Web 地址，并仅在连接结果中提示 agent 用自己的内置网页预览打开它。
例如在 T3 Code 中，先检查 `preview_status`，需要新标签页时把返回的 URL 传给 `preview_open`。
需要重新查询地址或使用自定义端口时，可调用 `get_web_preview`（`device?`、`port?`，默认 8765）。
详见 [MCP 页面引导](Documentation/MCP.md#引导模型打开实时控制页)。

```html
<img src="http://127.0.0.1:8765/stream.mjpeg" alt="设备实时画面">
```

画面来自 USB 视频、Android scrcpy、iOS Mirror 或模拟器帧缓冲，不循环调用设备截图接口。
网页优先使用 VideoToolbox 硬件 H.264 编码、WebSocket 传输和 WebCodecs 解码，目标 60 fps，
保留源分辨率（最长边最多 4096 像素，尺寸对齐偶数），不含音频。实际更新率受设备视频源、编码和浏览器性能限制。
浏览器不支持 WebCodecs 或硬件编码不可用时自动回退到 MJPEG（最长边 1920、目标 30 fps）；
`/snapshot.jpg` 保留最长边 4096 的高质量画面。慢客户端只保留有界的在途帧，H.264 丢帧后等待关键帧恢复，避免延迟积累。
页面只显示手机画面和基本按键；点击、长按、滑动直接在画面上操作，↻ 刷新连接。
其他网页嵌入时仍受浏览器混合内容和本地网络访问策略约束。

在侧栏选中设备后，点击屏幕中央的「连接」才会建立预览会话并加载画面。连接过程中可取消，失败后可点击「重试」；切换设备后需要重新点击连接。

## ADB 依赖下载

首次运行 `scripts/setup-dev.sh` 会从 Google 官方下载固定版本的 macOS Platform-Tools，缓存 ZIP 和解压后的工具位于 `.build/android/`。再次运行会校验并复用缓存。只需单独准备 ADB 时：

```sh
python3.13 scripts/prepare-android-tools.py --download
```

版本、下载地址、ZIP 和解压文件的 SHA-256、上游校验来源及许可证信息记录在 `scripts/android-assets.json`。缓存不完整时会从已校验的 ZIP 重建或重新下载；下载文件校验失败会停止，不使用未验证的文件。只提取运行 ADB 必需的 `adb`、`lib64/libc++.dylib`、原始 `NOTICE.txt` 和 `source.properties`。

离线机器可先从清单中的官方地址获取同一版本 ZIP，再导入（同样校验 SHA-256）：

```sh
python3.13 scripts/prepare-android-tools.py --archive /path/to/platform-tools_r37.0.1-darwin.zip
```

开发运行优先复用 PATH、Android SDK 或 Homebrew 中已有的 ADB，找不到时自动使用 `.build/android/platform-tools/adb`，无需修改 PATH。可以通过 `DEVICEHUB_ADB=/absolute/path/to/adb` 显式指定其他工具。

## iPhone / iPad 无线连接

点击侧栏底部或工具栏的「配对附近设备」，允许 phone-use 访问本地网络，并让设备与 Mac 连接同一 Wi-Fi。
首次不插线配对需要 iOS / iPadOS 27 或更新版本：

1. 在设备的「设置 › 隐私与安全性」中开启「开发者模式」，按提示重启并确认。
2. 打开「设置 › 开发者 › 已配对的 Mac」，选择名称带有 `phone-use` 的这台电脑。
3. 在设备上输入应用配对窗口显示的验证码。若可配对设备直接出现在窗口列表中，也可以点击「配对」，然后在设备上确认。

配对成功后设备会自动加入列表，后续在同一局域网中可被自动发现。关闭配对窗口会停止本次发现、广播及未完成的配对；窗口最多保持三分钟。
系统已信任并通过 Wi-Fi 暴露给 usbmuxd 的设备（包括 Xcode 已连接的设备）会直接出现在列表中，无需重新配对；应用复用系统连接，不导入 Xcode 的配对密钥。
旧版系统或未显示开发者模式时，先通过 USB 连接、信任并完成设置；后台会尝试建立无线配对，之后可拔线重连。USB 与 Wi-Fi 同时可用时优先使用 USB。
设备不再接受这台 Mac 的无线配对时（例如在设备上移除了已信任的电脑），设备会显示「Wi-Fi pairing expired」且不再反复重试。用 USB 连接一次即可自动重新配对，设备上不会出现提示；没有数据线时也可以重新进行附近配对。
设备通过 USB 连接时，检查器中的「Wi-Fi through macOS」开关相当于 Finder 的「在 Wi-Fi 上显示此 iPhone」，开启后应用自身的无线配对失效时仍可通过系统连接使用 Wi-Fi。

## iOS 模拟器

本机已启动或有使用记录的 iOS / iPadOS 模拟器会自动出现在设备列表中，连接方式显示为「Simulator」，ID 形如 `simulator:<UDID>`。
从未使用过的关机模拟器默认不显示；首次在 Simulator / Xcode 中启动后会自动加入。已删除的模拟器会从列表移除。
需要安装 Xcode，并通过 `xcode-select` 或 `DEVELOPER_DIR` 选中它；无需配对、开发者模式或 USB。
可以在 Simulator / Xcode 中启动模拟器，也可以运行 `xcrun simctl boot <UDID>`；关机后设备在列表中显示为未连接。

预览直接显示模拟器的帧缓冲，触控、Home、锁屏和音量键通过 Simulator 的 HID 通道发送，启动应用使用 `simctl launch`。
截图在预览或自动化会话收到画面刷新后直接读取帧缓冲，否则通过 `xcrun simctl io` 截取。返回、多任务键仅适用于 Android。

```sh
xcrun simctl boot "iPhone 17 Pro"
.build/debug/phone-use --device simulator:<UDID> screenshot .build/simulator.png
```

## 构建应用

```sh
scripts/build-app.sh             # dist/PhoneUse.app
scripts/build-app.sh automation  # dist/Automation.app
```

`dist/PhoneUse.app` 包含 Python 运行时、CLI、MCP 服务和独立 ADB；使用者无需安装 Android Studio 或自行下载 ADB。`dist/Automation.app` 包含同样的守护进程运行时（额外安装 MaaFramework）、`automation-bridge`、插件运行时和 OCR 资源。Xcode 工程由 `project.yml` 生成，名称为 `phone-use.xcodeproj`，scheme 为 `phone-use` 和 `automation`。

打包前先完成上述依赖准备。Release 构建会在编译前检查 Android 资源，打包阶段只校验、复制已准备的固定版本并签名，不自动联网下载 Android 资源。ADB、所需动态库及上游许可证位于 `Contents/Resources/android/platform-tools/`。如需打包自定义版本，可显式设置 `DEVICEHUB_ADB`；此时使用指定工具及其相邻的 `lib64/`、`NOTICE.txt`、`source.properties`，不应用固定版本校验。

| 入口 | SwiftPM 产品 | 应用包内位置 |
| --- | --- | --- |
| 原生应用 | `phone-use-app` | `Contents/MacOS/phone-use` |
| 命令行 | `phone-use` | `Contents/Helpers/phone-use` |
| MCP 服务 | `phone-use-mcp` | `Contents/Helpers/phone-use-mcp` |

### 连接 AI 助手（MCP）

MCP 使用标准输入输出传输，启动命令为应用包中 MCP 服务的绝对路径，无需先启动应用。最简单的方式是在应用中打开「设置 › AI 助手」（⌘, 或 phone-use 菜单 ›「连接 AI 助手…」）：页面列出本机 MCP 服务的实际路径，检测到 `claude` / `codex` 命令时可一键添加或更新，也可以复制终端命令或 JSON 配置。手动配置时，以安装在 `/Applications` 为例：

```sh
# Claude Code（对所有项目生效）
claude mcp add -s user phone-use -- /Applications/PhoneUse.app/Contents/Helpers/phone-use-mcp

# Codex（写入 ~/.codex/config.toml）
codex mcp add phone-use -- /Applications/PhoneUse.app/Contents/Helpers/phone-use-mcp
```

Claude Desktop、Cursor 等使用 JSON 配置的客户端，在 MCP 配置中加入：

```json
{
  "mcpServers": {
    "phone-use": { "command": "/Applications/PhoneUse.app/Contents/Helpers/phone-use-mcp" }
  }
}
```

已有配置如引用 `DeviceHub.app` 或 `devicehub-mcp`，需要更新为上述路径；设置页会将其显示为「指向其他位置」，点击「更新」即可。设备未就绪时，工具错误会提示助手请用户在 PhoneUse 中完成配对等准备。

`phone-use-mcp` 只是转发层：`initialize`、`tools/list` 由它直接应答，工具调用通过 `~/Library/Application Support/DeviceHub/mcp.sock`（可用 `DEVICEHUB_MCP_SOCKET` 覆盖）转交应用，在应用进程内执行，与预览共用守护进程和设备会话。首次调用工具时若应用未运行，会以 `--background` 在后台启动应用，不显示窗口、不抢占焦点；点击 Dock 图标或「窗口」菜单可打开主窗口。没有窗口且没有 MCP 客户端连接时，应用在约一分钟后自动退出；有客户端连接时关闭主窗口不会退出应用。应用退出时尚未返回的调用会以工具错误结束，下一次调用会重新连接并按需再次启动应用。

`DEVICEHUB_APP` 可指定要启动的 `.app` 或 `phone-use-app` 可执行文件；SwiftPM 构建中默认使用同目录的 `phone-use-app`。命令行 `phone-use` 仍直接连接守护进程，需要应用已在运行。

MCP 也可通过 `list_devices` → `select_device` → `connect_device` 完成界面的选中与连接流程；选择与界面同步，连接成功后请求预览。省略 `device` 时使用当前选择，并发 agent 应显式指定设备。

工具定义、模拟器 UI 树与文本输入、手势、坐标单位及旧调用兼容见 [MCP 操作约定](Documentation/MCP.md)。

## 应用沙箱文件

选择就绪的 iPhone 或 iPad，打开工具栏「…」菜单中的「应用沙箱…」，搜索并选择应用，再点击「在 Finder 中打开」。
应用列表按需加载设备上安装的真实应用图标；图标不可用时显示默认图标。
沙箱会挂载成 Finder 原生的只读卷，可使用列表/分栏浏览、快速查看、拖拽复制到 Mac。
重复打开同一应用会复用挂载；在 Finder 或应用选择弹窗中「弹出」即可断开。
关闭选择弹窗不会卸载卷；设备连接结束或守护进程退出时会清理挂载。

Finder 挂载通过现有设备连接上的 House Arrest/AFC 服务，以本机回环地址的 WebDAV 提供，
每个卷使用随机访问地址，仅允许读取，不需要安装 Samba 或额外的文件系统驱动。
目录和文件内容可能被 Finder 缓存，设备端文件变化后可弹出并重新挂载刷新。
应用列表仍通过 Xcode/CoreDevice 获取，需本机提供 `devicectl` 且能识别目标设备。
应用是否开放容器以实际请求结果为准，开发签名或 Debug 名称本身并不保证权限。
Finder 挂载暂不支持模拟器和 Android；任意系统路径、Keychain、iCloud Drive 和第三方文件提供器
不在此功能范围内。

MCP 保留独立的 CoreDevice 文件接口，不依赖 Finder 挂载，沿用设备选择规则，也可显式传入 `device`：

- `list_apps`：可选 `search`，返回应用及容器访问权限。
- `list_sandbox_files`：必填 `bundle_id`，`path` 默认为 `.`；返回文件类型、大小、修改时间，
  支持 `offset` / `limit` 分页（默认 200，最多 500），存在后续条目时返回 `next_offset`。
- `read_sandbox_file`：传入 `bundle_id` 和容器相对 `path`，返回最多 64 KiB 的 UTF-8 文本。
- `download_sandbox_file`：另传 `destination`（运行 PhoneUse 的 Mac 上的绝对文件路径），
  下载成功后返回 `local_path`。不递归下载目录，不跟随所选符号链接。

例如先列出应用，再用返回的 Bundle ID 浏览 `Library`。所有远端路径都相对应用数据容器，
不接受绝对路径或 `..`。运行中的 SQLite 数据库可能依赖 WAL/SHM；单独下载 `.db` 文件不代表
取得了一份一致的数据库备份。

## 自动更新与发布

正式应用通过 Sparkle 检查并安装更新；安装包由 GitHub Releases 提供，更新清单由 GitHub Pages 托管。推送 `vMAJOR.MINOR.PATCH` 标签可触发 Actions 完成测试、签名、公证和发布。首次配置、密钥管理与验证步骤见 [自动更新与发布](Documentation/AutomaticUpdates.md)。

## 改名兼容

项目由 DeviceHub 改名为 phone-use，应用名为 PhoneUse，应用标识为 `cn.andysheng.phoneuse`（原 `dev.devicehub.app`，改标识后需重新授予摄像头等系统权限）。为延续现有设备记录，`~/Library/Application Support/DeviceHub`、日志目录和 `DEVICEHUB_*` 环境变量保持兼容。Swift framework 改名为 `PhoneUseKit`；Python 模块沿用原名。

## 连接故障与诊断日志

PhoneUse 和 Automation 默认保存诊断日志。发生连接、截图或任务超时后，在出现问题的应用中选择 **帮助 → 导出诊断日志…**，保存 ZIP，并说明发生时间、USB / Wi-Fi 连接方式及操作步骤。无需连接开发机，也无需提前开启调试模式。只有安装包含此功能的版本之后发生的问题才会有这些记录。

- PhoneUse：`~/Library/Logs/DeviceHub/`。
- Automation：`~/Library/Logs/cn.andysheng.automation/`。
- 「帮助 → 打开诊断日志文件夹」可直接查看原始文件；`DEVICEHUB_HOME` / `DEVICEHUB_LOG_DIR` 自定义身份仍生效。

结构化 JSONL 记录应用版本、macOS 版本、UTC 时间、进程与会话 ID，以及设备连接类型、设备系统版本、截图起止、服务重连、底层超时、预览错误和守护进程输出。设备 ID 在新增的结构化字段中用摘要表示。请求不记录参数或图像内容；日志不写入 CLI、MCP 或桥接协议的 stdout。守护进程和 worker 的 stderr 由应用持续收集，关闭应用后仍可查看。

每个 Swift 进程日志文件上限约 2 MiB，保留一个轮转文件；同一应用目录最多保留 40 个该类日志文件（约 80 MiB，创建/轮转时清理）。导出至多包含这 40 个文件；每个文件只取末尾 2 MiB，截断情况和读取失败会写入 `manifest.json`。Automation 另外收集最近三次运行的文本日志，详情见 [Automation 文档](Automation/README.md#诊断日志)。磁盘不可写时诊断功能降级，不阻止设备操作。

诊断包不收集截图、配对凭据、插件资源、任务文件或环境变量。原有守护进程及插件的文本消息仍可能包含设备名称、网络地址、路径及用户内容，分享前可解压检查。导出不会自动发送任何数据。

插件与任务功能已移至 Automation 应用（`cn.andysheng.automation`）。它继续读取原有的插件目录 `~/Library/Application Support/DeviceHub/Plugins` 和任务库，插件格式不变；守护进程状态放在 `~/Library/Application Support/cn.andysheng.automation`。

详见[插件自动化](Automation/README.md)和[平台隔离与视频流](Documentation/DevicePlatforms.md)。
