# 项目协作指南

本文件适用于整个仓库。修改前先阅读相关源码及目录文档，遵循现有实现约定。

## 项目与环境

本仓库目前包含三层，后续将拆分为独立仓库，现阶段用 target 隔离依赖：

- **PhoneUseKit framework**：设备发现、连接、输入、屏幕流、Python 守护进程和共享设备界面，不依赖任何应用。
- **phone-use**：面向开发者 / AI 代理的应用、CLI 和 stdio MCP 服务。
- **automation**：面向游戏代打用户、基于 MaaFramework 的插件运行底座。

两个应用都只依赖 framework，彼此不依赖；各自启动并管理自己的守护进程。

- 开发环境：Apple silicon Mac、macOS 15+、Xcode、Python 3.13；生成 Xcode 工程需要 XcodeGen。
- Swift 工具版本为 6.0，代码语言模式为 Swift 5，以 `Package.swift` 和 `project.yml` 为准。
- Android 功能需要 ADB，可通过 `DEVICEHUB_ADB` 指定路径。
- 主要文档：`README.md`、`Documentation/DevicePlatforms.md`、`Automation/README.md`、`Automation/PLUGIN_FORMAT.md`。

## 目录与边界

| 路径 | 层 | 职责 |
| --- | --- | --- |
| `Sources/PhoneUseKit/` | framework | 设备会话、平台连接适配器、屏幕流、守护进程客户端、`PhoneUseConfiguration` |
| `Sources/PhoneUseUI/` | framework | 共享设备界面：设备列表、预览、输入、配对、`DeviceWorkspace`、守护进程启动 |
| `Daemon/devicehubd/` | framework | Python 设备发现、连接、worker 与 Android 视频生命周期 |
| `Sources/PhoneUseApp/` | phone-use | 应用、设备设置面板、MCP 宿主与自动更新 |
| `Sources/PhoneUseCLI/` | phone-use | `phone-use` CLI |
| `Sources/PhoneUseMCP/`、`Sources/PhoneUseMCPServer/` | phone-use | MCP 工具与 `phone-use-mcp` 服务 |
| `Sources/AutomationApp/` | automation | 应用与插件、任务、运行界面 |
| `Sources/AutomationBridge/` | automation | `automation-bridge`：Maa 运行时的私有设备连接 |
| `Automation/devicehub_runtime/` | automation | 通用自动化运行时和插件 SDK |
| `Tests/`、`Daemon/tests/`、`Automation/tests/` | 各层 | Swift / Python 回归测试与必要的测试素材 |
| `scripts/`、`Support/` | 各层 | 环境准备、构建打包、应用权限与元数据 |

- 依赖方向只能是应用 → framework。framework 不引用 MCP、插件或 MaaFramework 相关代码；phone-use 与 automation 互不引用。
  新增代码先判断所属层；两个应用都需要的设备能力放进 framework。
- 应用在启动时设置 `PhoneUseConfiguration.current`，守护进程和辅助进程通过 `DEVICEHUB_HOME`、
  `DEVICEHUB_LOG_DIR`、`DEVICEHUB_DISPLAY_NAME` 继承同一身份。framework 内不写死应用名称或数据目录。

- App、CLI、MCP 和自动化通过共享设备会话工作；iOS / Android 的连接、输入和视频实现保持分离。
- UI 屏幕模型不直接操作 ADB、CoreMediaIO 或视频 socket；平台准备与恢复由对应 provider 负责。
- 仓库及应用不附带具体插件的实现、资源、示例或说明；任务行为由外部插件提供。通用宿主不按插件 ID 分支。扫描及安装插件时只读取元数据，不执行插件代码。
- MCP 等协议使用的 stdout 不得混入诊断文本；诊断信息走日志或 stderr。
- 应用名为 PhoneUse / Automation，应用标识为 `cn.andysheng.phoneuse` / `cn.andysheng.automation`；CLI、MCP 服务名仍为 `phone-use`。
  phone-use 保留 `DEVICEHUB_*`、`~/Library/Application Support/DeviceHub` 的兼容性；
  automation 使用 `cn.andysheng.automation` 同名数据目录。Python 模块名 `devicehubd`、`devicehub_runtime`、
  插件格式 `devicehub.plugin.v1` 及现有插件与任务库目录保持兼容。Swift framework 名为 `PhoneUseKit`。

## 开发与构建

以下命令均从仓库根目录运行。优先复用现有虚拟环境和缓存；只有缺失或依赖发生变化时才重新准备。

```sh
# 首次准备；这些脚本可能下载依赖及固定版本的资源。
PYTHON=python3.13 scripts/setup-dev.sh
scripts/setup-automation.sh

# 运行原生应用；automation 运行任务时使用 .build/debug/automation-bridge，先完整构建一次。
swift run phone-use-app
swift build && swift run automation-app

# 生成 Xcode 工程并打包至 dist/PhoneUse.app 或 dist/Automation.app。
scripts/build-app.sh
scripts/build-app.sh automation
```

- `project.yml` 是 Xcode 配置来源；不要手改生成的 `phone-use.xcodeproj` 或历史 `DeviceHub.xcodeproj`。
- SwiftPM 产品：framework 为 `PhoneUseKit`、`PhoneUseUI`；phone-use 为 `phone-use`、`phone-use-mcp`、
  `phone-use-app`；automation 为 `automation-app`、`automation-bridge`。
- phone-use 打包只嵌入守护进程运行时（`scripts/embed-daemon.sh`）；automation 额外嵌入插件运行时与 OCR 资源
  （`scripts/embed-automation.sh`）。
- 构建、下载和测试输出放在 `.build/`，发布产物放在 `dist/`。
- `Automation/assets.json` 和 `scripts/android-assets.json` 固定上游资源与哈希。
  更新资源时同步更新清单及来源/许可证，不绕过校验；Android Release 打包缺少已准备的 scrcpy 资产时应失败。

## 验证

代码修改完成后，必须主动执行与变更范围相符的构建、测试及必要检查；只有用户明确说“不用验证”或明确要求跳过对应检查时才可省略。不得以未被单独要求验证为由跳过，也不得把尚未执行的检查报告为通过。

按变更范围选择相关检查。文档或 Git 配置修改只需验证对应配置，无需完整打包。

```sh
# 共享库及应用连接逻辑的 SwiftPM 测试。
swift test

# Python 守护进程测试。
PYTHONPATH=Daemon .venv-daemon/bin/python -m unittest discover -s Daemon/tests -v

# 通用自动化运行时测试；部分用例需要 MaaFramework 和已准备的 OCR 资源。
PYTHONPATH=Automation .venv-maa/bin/python -m unittest discover -s Automation/tests -v

# 独立的界面选择逻辑测试，不包含在 swift test 中。
mkdir -p .build
swiftc Sources/AutomationApp/AutomationSelection.swift Tests/AutomationSelectionTests.swift -o .build/test-selection
.build/test-selection
```

- 沙箱内运行 Swift 时，按需使用 `CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"`、
  `SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-module-cache"`，以及 SwiftPM 的
  `--cache-path .build/swift-cache --config-path .build/swift-config --security-path .build/swift-security`。
- 优先增加能够复现实际行为问题的测试，不为低风险文档变更添加无意义测试。
- 区分离线单元测试、识图回放和真机验证；前两者通过不代表真机操作已经验证。
- 汇报实际执行的检查、结果及未覆盖的部分。

## Git 与大文件

- `.gitignore` 排除虚拟环境、构建缓存、生成工程、发布包、日志及本地配置；源码、资源清单、
  `Package.resolved`（如生成）、许可证和测试素材应保留在版本控制中。
- `.gitattributes` 将 PNG/JPEG/GIF/WebP/ICNS 图片、MP4/MOV 视频和 ONNX 模型交给 Git LFS；
  Swift、Python、JSON、SVG 等文本继续使用普通 Git。
- 首次克隆后运行 `git lfs install --local` 和 `git lfs pull`，确保测试图片是实际内容而非 LFS 指针。
- 已有自定义 Git hooks 时，将 LFS hooks 接入现有调用链，不使用 `--force` 覆盖它们。
- 下载生成的模型和 scrcpy 资源仍放在 `.build/`，不因启用 LFS 就提交缓存或发布包。
- 新增需要版本控制的二进制格式时更新 `.gitattributes`；提交前检查 `git lfs ls-files` 和 `git diff --check`。
- 对已跟踪资源启用 LFS 时，仅重新索引明确匹配的文件，并将 `.gitattributes` 与指针文件一起提交。
  不擅自改写历史、强推或提交无关改动。

## Tool execution preferences

- Use the existing sandbox permissions for routine reads, edits, builds, and tests. Request escalation only when a concrete capability is missing or a sandbox failure establishes the need; include that reason. Do not preemptively request unrestricted execution merely to avoid a possible retry. Preserve all applicable approval and security requirements.
- Keep build outputs, package caches, and temporary files inside the current workspace or already permitted temporary directories when the tool supports it. Reuse existing dependencies and caches before downloading or reinstalling them.
- Batch independent read-only inspections into one tool call and run them concurrently when supported. Keep privileged or mutating actions separate so their approval scope stays clear.
- Use resumable sessions for long-running commands. Poll according to their expected runtime, and distinguish an active background process from a blocked command.
- Keep tool output bounded: search first, read relevant ranges, and summarize large results. After a long task phase, preserve decisions, changed files, and remaining work in a concise checkpoint.
