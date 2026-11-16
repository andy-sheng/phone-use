# automation 插件自动化

automation 是 iPhone 与 Android 设备自动化宿主：负责 MaaFramework、OCR、任务进程、取消、日志和原生界面；设备连接、预览和输入来自 PhoneUseKit framework。任务行为通过用户独立安装的 Python 插件提供，界面按插件描述渲染。应用不附带任何插件。

Automation 与 PhoneUse 是两个独立应用（`cn.andysheng.automation` / `cn.andysheng.phoneuse`），只共享 PhoneUseKit，不互相依赖。Automation 启动自己的守护进程，状态放在 `~/Library/Application Support/cn.andysheng.automation`。

## Android 设备

设备列表保留原来的 Available / Unavailable 分组，每台设备显示 iPhone、iPad 或 Android 标识。Android USB、已连接的 ADB Wi-Fi 设备及模拟器使用 `android:<adb serial>` 标识；未授权和离线设备有独立提示。首次连接请开启开发者选项与 USB 调试，在手机上允许此电脑。Wi-Fi 设备须先通过 Android platform-tools 完成配对与 `adb connect`，应用不自动配对。

开发环境先安装 Android SDK platform-tools，再运行 `scripts/setup-dev.sh` 安装设备守护进程依赖（不含 MaaFramework）并准备固定版本的 scrcpy 服务端，运行 `scripts/setup-automation.sh` 安装 MaaFramework 运行时。ADB 自动从 PATH、`ANDROID_HOME`、`ANDROID_SDK_ROOT`、macOS 默认 Android SDK 目录及 Homebrew 查找；也可用 `DEVICEHUB_ADB=/absolute/path/to/adb` 指定。Release 构建会把本机 ADB 及其 NOTICE 打包进应用；找不到 ADB 时构建会明确失败，避免发布没有安卓控制工具的安装包。运行时优先使用用户已安装的 ADB，内置 ADB 仅作兜底，避免与 Android Studio 等工具的 ADB server 版本冲突、互相重启。用户无需另装 Python、ADB 或 scrcpy。

视频资产使用 [Genymobile/scrcpy 官方 v3.3.4 发布](https://github.com/Genymobile/scrcpy/releases/tag/v3.3.4)，不依赖全局 scrcpy 或 Homebrew 安装。也可单独运行 `python3 scripts/prepare-android-video.py --download`，将服务端缓存到 `.build/android/scrcpy-server-v3.3.4`；已有文件通过 SHA256 校验后直接复用。版本、下载地址、官方校验文件来源及固定哈希记录在 [资产清单](../scripts/android-assets.json)。`DEVICEHUB_SCRCPY_SERVER=/absolute/path/to/scrcpy-server-v3.3.4` 可指定本地副本，但必须匹配同一版本及哈希。Release 打包只校验并复制已准备的资产，不会临时下载；缺失或校验失败会中止构建。服务端及其 Apache-2.0 `LICENSE`、来源 `NOTICE` 随应用放在 `Contents/Resources/android/`。

Android 复用现有屏幕面板、任务区和日志界面，支持原生尺寸无损截图、单指点击/拖动/滑动、长按、Home/返回/最近任务/音量/锁屏及按包名启动应用。预览使用 scrcpy H.264 视频流，长边上限 1920 像素、帧率上限 60 fps，不传输音频；实际帧率取决于设备编码器和传输条件。视频资产不可用或视频启动失败时，界面提示原因并降级为截图预览；已运行的视频发生错误时显示重新连接入口。任务截图与识别仍使用原生尺寸截图，不依赖视频分辨率。平台边界、视频连接生命周期和恢复策略见 [平台设计说明](../Documentation/DevicePlatforms.md)。

输入与视频预览的权限独立。预览中的手动操作使用 PhoneUseKit 的 scrcpy 控制通道；任务运行时由 MaaFramework 的 AdbController（MaaTouch/minitouch）直接操作设备，设备若不支持会报告连接失败；部分厂商还需开启「USB 调试（安全设置）」以允许模拟输入，权限不足时会明确报错，截图和启动应用仍可使用。横竖屏切换、折叠屏展开等导致截图尺寸改变时停止坐标输入，并显示重新连接入口；运行任务期间须先停止任务才能重连。尺寸不变的 180° 旋转无法通过此检查发现，固定坐标任务应锁定屏幕方向。

自动任务先通过 `automation-bridge`（基于 PhoneUseKit 的私有 stdio 连接，经环境变量继承应用的守护进程身份）解析设备。Android 设备随后改由 MaaFramework 原生的 AdbController 控制，使用守护进程报告的同一个 adb，运行前检查输入权限，并原生支持按键、文本输入和停止应用；iOS 设备继续通过 bridge 截图和触控，Maa 识别坐标会转换回原生像素。原有任务与插件无须修改。插件的设备布局、模板和安全区须由插件作者验证；设备控制能力不代表任意自动化任务均可直接运行。

## 界面与任务

右侧面板一次只加载一个插件，通过「更换…」选择并加载另一个插件；关闭插件后保留各插件的任务和配置。主面板只显示当前任务详情、参数、日志和运行控制。每个插件分别记住上次打开的任务，再次加载时恢复；没有已选任务时，从「任务库…」进入独立页面选择或导入。

任务库的搜索、计数、删除和导入都限定当前插件。「打开」会返回主面板，不会自动执行；直接返回则保留原来的当前任务。删除当前导入任务后回到未选择任务状态。运行期间可以浏览任务库，但不能更换或关闭插件、打开其他任务、导入或删除任务，停止后恢复操作。

插件管理支持从 `.dhplugin` 插件文件或 HTTP(S) 下载链接安装，并兼容已有 ZIP 文件；安装后需选择并加载插件。导入方式、帮助链接、参数和执行阶段均来自插件描述。参数支持整数、开关、文本和单选，保存到各任务自己的配置中。运行时显示插件的阶段与通用日志；运行中的设备会禁用手动触控及设备控制按钮。

插件包与任务记录分别管理：

- 插件：Python 代码、`plugin.json`、Maa Pipeline、图片及许可证。安装于 `~/Library/Application Support/DeviceHub/Plugins/<id>/<version>`。
- 导入任务：原始文档、来源和插件生成的展示信息。保存于 `~/Library/Application Support/DeviceHub/TaskLibrary`，删除任务不卸载插件。
- 运行记录：保存事件 JSONL、运行日志和诊断图像。收起面板不会停止任务。

旧 `devicehub.task.v1` 记录会重新交由对应插件解析为 `devicehub.task.v2`，保留文件名、原始文档和已有标题等元数据。旧参数通过插件声明的 `legacy_key` 迁移。插件缺失或不兼容时保留任务并显示原因；不会删除用户的作业。插件升级后重新校验任务和参数；不兼容的参数阻止运行并提示修改。

## 开发与运行

```sh
./scripts/setup-dev.sh
./scripts/setup-automation.sh
PYTHONPATH=Automation .venv-maa/bin/python -m devicehub_runtime catalog
# 用户自行获取插件文件后安装，再按插件说明导入或运行任务。
PYTHONPATH=Automation .venv-maa/bin/python -m devicehub_runtime install \
  --package /path/to/plugin.dhplugin
PYTHONPATH=Automation .venv-maa/bin/python -m unittest discover -s Automation/tests -v
swift build && swift run automation-app   # 任务使用 .build/debug/automation-bridge
./scripts/build-app.sh automation          # dist/Automation.app
```

设备层测试：

```sh
PYTHONPATH=Daemon .venv-daemon/bin/python -m unittest discover -s Daemon/tests -v
swift test
```

设置脚本只准备 Python 依赖和 `.build/maa-core` 中的共享 OCR。App 内嵌 Python、通用运行时和 OCR，使用者无需另装 Python。插件需单独获取并通过文件或 URL 安装；源码目录和构建缓存不会被自动扫描。

## 插件协议 v1

独立插件目录结构：

```text
my-plugin/
  plugin.json
  python/my_plugin/plugin.py
  resources/pipeline/...
  resources/image/...
```

`plugin.json` 使用 `schema: devicehub.plugin.v1` 和 `api_version: 1`，定义稳定的 `id`、数值版本 `version`、`entrypoint: my_plugin.plugin:create_plugin`、相对 `python_path`、资源目录与运行时/Python/MaaFramework 版本要求。`requires.capabilities` 声明设备能力；`tasks` 为内置任务，`task_types` 为导入任务类型。两者可声明 `parameters` 和 `phases`，界面统一渲染。

`imports` 提供 `source` 或 `file` 入口，每种最多一个，分别可声明占位符、扩展名和帮助链接。旧任务迁移根据插件声明的 `detect` 字段选择解析器；通用流程可声明 `fallback`。导入规则由插件描述提供。

入口工厂返回对象，提供以下方法：

- `inspect_document(document, *, source, author, fallback_title)`：返回 `task_id`、标题、说明、问题及备注等任务元数据；不连接设备。
- `fetch_source(source)`：可选，处理分享码等字符串，返回 `(document, author, origin)`。
- `prepare(context, task_id, document, config)`：返回 SDK 的 `PreparedTask`，包含入口、资源包、Pipeline、超时和结果转换函数。内置任务的 `document` 为 `None`。

`RuntimeContext` 提供 Maa Resource、自定义事件输出、停止信号和受限于插件目录的资源路径解析。插件可注册 Maa 自定义识别与动作；Controller、Tasker、JSONL 输出和生命周期由运行时统一管理。插件结果转换为 `completed`、`failed` 或 `cancelled`，任务专属状态可另附字段。

目录扫描只读取描述，不执行 Python。应用仅刷新当前加载插件的任务；未加载插件时不执行任务刷新。导入、任务刷新及运行在独立 worker 进程中按需加载当前插件，不会同时加载其他插件。CLI 的 `refresh-library --plugin ID --library PATH` 提供相同的范围限定，省略 `--plugin` 的全库刷新仅用于显式维护。worker 将插件标准输出转到日志，保留协议输出；运行前重新校验任务、参数及资源，按真实设备 UDID 持有跨进程排他锁。停止先请求 Maa 结束并释放连接，超时才结束 worker。

插件是受信任的 Python 代码，子进程隔离不等于权限沙箱。v1 使用宿主提供的 Python 依赖，不自动执行安装脚本或安装 pip 依赖；也暂不提供远程插件市场和任意自定义界面。

## 插件分发

标准分发文件使用 `.dhplugin` 扩展名，建议命名为 `<id>-<version>.dhplugin`。它是根目录直接包含 `plugin.json` 的 ZIP 压缩包，沿用 `devicehub.plugin.v1` 描述和 SDK v1。详细结构、版本与安装约定见 [插件文件格式](PLUGIN_FORMAT.md)。

```sh
# 打包准备好的插件（包含资源）
PYTHONPATH=Automation .venv-maa/bin/python -m devicehub_runtime pack \
  --plugin /path/to/prepared-plugin --output /path/to/plugin-1.0.0.dhplugin
# 安装本地插件文件
PYTHONPATH=Automation .venv-maa/bin/python -m devicehub_runtime install \
  --package /path/to/plugin-1.0.0.dhplugin
# 从直接下载链接安装；URL 不要求以 .dhplugin 结尾
PYTHONPATH=Automation .venv-maa/bin/python -m devicehub_runtime install \
  --url 'https://example.com/releases/plugin-1.0.0.dhplugin'
```

App 的「安装插件」菜单只提供文件和 URL 两个安装入口，并兼容已有 `.zip` 包。CLI 的 `--package` 仍兼容开发用插件目录。链接必须直接返回插件压缩包，不能是发布说明或下载网页；支持 HTTP(S) 和下载重定向，HTTPS 不允许重定向降级到 HTTP。

文件安装与 URL 安装使用同一验证流程，检查版本兼容、相对路径、符号链接、文件数与大小；声明了 `assets.json` 的插件还须通过资源完整性校验，缺失资源不会在安装时另外下载。临时展开验证后原子移动；相同版本相同内容可重复安装，不允许用不同内容覆盖同一版本。安装成功只更新可用插件列表，不自动加载或运行任务；若安装的是当前插件，会先关闭它，保留任务与配置，等待手动重新加载。

默认只扫描用户插件目录，选择同 ID 的最高兼容版本。旧版本文件保留，但 v1 尚无版本切换/回退 UI。CLI 可重复传 `--plugin-root PATH` 使用独立测试目录。

## 验证边界

测试覆盖通用控制器、插件发现、无代码执行扫描、版本兼容、迁移、参数、设备锁、取消、插件包和 URL 安装契约，测试用临时描述和最小执行桩生成，不依赖任何具体插件。离线测试不代表真机操作已验证。构建产物和缓存位于 `.build`。
