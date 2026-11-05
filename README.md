# phone-use

在 macOS 上连接、预览和操作 iPhone 与 Android 真机，提供原生应用、命令行、MCP 服务及插件自动化。iOS 与 Android 的连接、输入和视频流分别实现，共用设备列表与任务界面。

## 获取仓库资源

仓库使用 Git LFS 管理测试图片等二进制资源。安装 Git LFS 后，在克隆的仓库中执行：

```sh
git lfs install --local
git lfs pull
```

下载生成的 OCR 模型、scrcpy 和插件资源由下方的准备脚本写入 `.build/`，不提交到 Git。
项目协作、目录职责和测试命令见 [AGENTS.md](AGENTS.md)。

## 开发运行

需要 Apple silicon Mac、macOS 15 或更新版本、Xcode 和 Python 3.13。生成 Xcode 工程还需要 XcodeGen。Android 支持需要 Android SDK Platform-Tools，并确保 `adb` 在 PATH 中；也可以通过 `DEVICEHUB_ADB` 指定路径。

```sh
scripts/setup-dev.sh
scripts/setup-automation.sh
swift run phone-use-app
```

应用运行后，可以使用 CLI 操作已连接设备：

```sh
.build/debug/phone-use list
.build/debug/phone-use --device android:SERIAL screenshot .build/android.png
```

Android 设备需要启用 USB 调试并授权电脑；输入控制还可能需要厂商的 USB 调试安全设置。

在侧栏选中设备后，点击屏幕中央的「连接」才会建立预览会话并加载画面。连接过程中可取消，失败后可点击「重试」；切换设备后需要重新点击连接。

## iPhone / iPad 无线连接

点击侧栏底部或工具栏的「配对附近设备」，允许 phone-use 访问本地网络，并让设备与 Mac 连接同一 Wi-Fi。
首次不插线配对需要 iOS / iPadOS 27 或更新版本：

1. 在设备的「设置 › 隐私与安全性」中开启「开发者模式」，按提示重启并确认。
2. 打开「设置 › 开发者 › 已配对的 Mac」，选择名称带有 `phone-use` 的这台电脑。
3. 在设备上输入应用配对窗口显示的验证码。若可配对设备直接出现在窗口列表中，也可以点击「配对」，然后在设备上确认。

配对成功后设备会自动加入列表，后续在同一局域网中可被自动发现。关闭配对窗口会停止本次发现、广播及未完成的配对；窗口最多保持三分钟。
系统已信任并通过 Wi-Fi 暴露给 usbmuxd 的设备（包括 Xcode 已连接的设备）会直接出现在列表中，无需重新配对；应用复用系统连接，不导入 Xcode 的配对密钥。
旧版系统或未显示开发者模式时，先通过 USB 连接、信任并完成设置；后台会尝试建立无线配对，之后可拔线重连。USB 与 Wi-Fi 同时可用时优先使用 USB。

## 构建应用

```sh
scripts/build-app.sh
```

输出为 `dist/phone-use.app`，包含 Python 运行时、CLI 和 MCP 服务。Xcode 工程由 `project.yml` 生成，名称为 `phone-use.xcodeproj`，scheme 为 `phone-use`。

| 入口 | SwiftPM 产品 | 应用包内位置 |
| --- | --- | --- |
| 原生应用 | `phone-use-app` | `Contents/MacOS/phone-use` |
| 命令行 | `phone-use` | `Contents/Helpers/phone-use` |
| MCP 服务 | `phone-use-mcp` | `Contents/Helpers/phone-use-mcp` |

MCP 使用标准输入输出传输。将客户端的启动命令设为应用包中 MCP 服务的绝对路径，并先启动应用。已有配置如引用 `DeviceHub.app` 或 `devicehub-mcp`，需要更新为上述路径。

## 改名兼容

项目与对外产物由 DeviceHub 改名为 phone-use。为延续现有安装的权限、任务和设备记录，应用标识 `dev.devicehub.app`、`~/Library/Application Support/DeviceHub`、日志目录、`DEVICEHUB_*` 环境变量及插件数据格式保持兼容。内部 Swift 模块 `DeviceHubKit` 和 Python 模块也沿用原名。

详见[插件自动化](Automation/README.md)和[平台隔离与视频流](Documentation/DevicePlatforms.md)。
