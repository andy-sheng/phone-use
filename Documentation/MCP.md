# PhoneUse MCP 操作约定

PhoneUse 的工具命名和操作参数以 **sim-use 0.16.0** 为主要参照，并参考
XcodeBuildMCP（现已改名为 MobileBuildMCP）的 UI 自动化定义。工具在应用进程内通过
PhoneUseKit 的共享设备会话执行；无需另装 sim-use、idb、XcodeBuildMCP 或测试 runner。

## 发现、观察、操作、验证

1. 调用 `list_devices`，查看设备状态及 `capabilities`。`state: ready` 表示可连接。另看 `lock_state` 判断屏幕是否锁定。自建或此前用过的关机模拟器也会列出，可用 `start_simulator` 启动。
2. 调用 `select_device` 选择设备，再调用 `connect_device` 建立连接并请求预览，对应界面的选中与连接。
   `select_device` 不连接设备，也可选择尚需配对等准备的设备；`connect_device` 只连接 `ready` 设备。
   省略 `device` 时使用 PhoneUse 当前选中设备；没有选中设备时，只能自动选取唯一的就绪设备。
   当前选择与界面、所有 MCP 客户端共享，并发 agent 应显式传入完整标识。名称匹配不唯一会报错。
   当前选中设备不可用时不会静默换到另一台设备。
   连接成功后会重新查询 `lock_state`。若为 `locked`，先按 `unlock_hint` 解锁，再启动应用或发送输入。若为 `unknown`，先观察当前界面。黑屏本身无法确认锁屏状态。
3. iOS 模拟器和真机中的开发签名应用优先用 `describe_ui` 读取界面，并用 `id`、`label` 或 `label_contains` 定位。
   真机中的系统/App Store/TestFlight 应用、Android 或自绘控件使用 `screenshot`，根据返回图像的坐标操作。
4. 操作后再次读取 UI 树或截图验证。返回 `input_sent: true` 仅表示输入已发送，
   `ui_change_verified` 仍为 `false`，不表示页面或字段已经按预期变化。

### 引导模型打开实时控制页

读取 `connect_device` 的结果后再安排后续设备操作。连接成功后，工具会检查 Web 服务的身份、设备标识和首帧。
验证成功时，结果直接提供 URL、打开指引和下一步参数。每次连接只提供一次指引。截图、UI 树、启动应用和输入工具只返回各自的操作结果。

`connect_device` 的 `structuredContent` 包含以下字段：

| 字段 | 含义 |
| --- | --- |
| `lock_state` | 本次读取的屏幕状态，取值为 `locked`、`unlocked` 或 `unknown` |
| `passcode_required`、`unlocked_since_boot` | iOS 真机有系统回读时提供。仅凭当前无需密码，仍可能无法确定屏幕是否锁定 |
| `unlock_hint` | 已确认锁屏时提供。若重启后尚未首次解锁，提示用户手动解锁 |
| `web_preview.available`、`web_preview.url` | 服务是否验证成功；只有成功时才附 URL |
| `web_preview_pending` | 当前未取得已验证的 URL |
| `next_required_action` | 有已验证的地址时为 `open_url` |
| `next_action_target`、`next_action_arguments` | `client_browser` 和 `{ "url": "…" }`，供 agent 的内置网页预览使用 |
| `web_preview.browser_opened_by_tool` | 始终为 `false`，页面由 agent 打开 |

`open_url` 指使用 **agent 自带的网页预览工具** 打开 `web_preview.url`。在 T3 Code 中，先用
`preview_status` 查看标签页。需要新开标签页时，用 `preview_open` 传入连接结果中的 URL、
`open: true` 和 `reuseExistingTab: false`。同一 URL 已打开时可复用现有标签页。
预览工具需能访问 PhoneUse 所在 Mac 的回环地址。若当前工具无法访问，或用户及宿主限制打开页面，
可分享已验证的链接并继续使用设备工具。

Web 服务由 CLI 启动，例如 `phone-use --device <UDID> serve 8765`。检查失败时，`connect_device`
保留连接成功结果，在 `web_preview.error` 提供原因，截图及输入仍可继续。启动服务后，可用
`get_web_preview` 重新验证并取得地址。该工具只查询状态和 URL，自定义端口会用于同一设备后续的连接检查。
更新后需重新启动 PhoneUse 宿主并重连 MCP 客户端，以加载新工具和初始化说明。

```json
{"name": "get_web_preview", "arguments": {"device": "<UDID>", "port": 8765}}
```

## 调用记录

PhoneUse 右侧“调用记录”页签实时显示 agent 发起的 MCP 工具调用，包括工具名、请求中的设备、
开始时间、执行中/已完成/失败状态、耗时及结果摘要。展开一条记录可查看参数和文本结果或错误。
记录覆盖所有设备，最新调用置顶；不传 `device` 时显示“自动选择设备”。
应用后台启动时也会记录，打开窗口后可查看；仅在内存中保留最近 200 条，退出即清空。
“清空记录”不取消正在执行的调用。参数和文本结果有长度上限，截图只显示类型，不保留图片编码。
这里记录的是 MCP `tools/call`，不包括侧栏自动刷新的 UI 树或手动操作；“已完成”表示工具返回成功，
不代表设备界面变化已经验证。

## 录屏

调用 `start_recording` 后可以继续使用其他工具，完成操作后将返回的 `recording_id` 传给 `stop_recording`。每台设备同时支持一段 MCP 录屏，切换选中设备不会改变这段录屏的目标。录屏可在后台进行，文件保存在运行 PhoneUse 的 Mac 上，默认目录为 `~/Library/Application Support/DeviceHub/Recordings/`。

iOS 模拟器录制开始时的活动屏幕。iOS 真机按连接能力使用原生录屏、USB 视频或 Mirror 视频。仅有截图的连接和 Android 设备当前不支持 MCP 录屏。

## 工具

PhoneUse 窗口右侧的“界面结构”页签会实时显示同一份 `describe_ui` 文本。
先连接所选 iOS 设备，面板打开时每次读取完成后刷新：模拟器间隔 1 秒、真机间隔 3 秒，错误后至少等待 5 秒。支持暂停、立即刷新和复制。
切换页签、隐藏面板或进入紧凑窗口后停止读取；切换设备时清空旧内容，并忽略旧请求的迟到结果。
读取失败会显示错误及上次成功更新时间，后续刷新继续尝试。它复用预览会话，单纯选中设备不会建立连接。

| 工具 | 主要参数 | 支持范围与含义 |
| --- | --- | --- |
| `list_devices` | 无 | 列出 iOS / Android 真机以及运行中或此前启动过的 iOS 模拟器，返回设备状态和能力 |
| `select_device` | `device` | 切换 PhoneUse 界面选中设备，不建立连接 |
| `connect_device` | `device?` | 连接设备、请求原生界面预览，并自动校验 Web 地址，返回浏览器下一步 |
| `unlock_device` | `device?` | 使用 PhoneUse 为该设备保存的数字密码解锁，返回 `status` 和 `unlock_verified` |
| `get_web_preview` | `device?`, `port?: 8765` | 检查已运行的本地 Web 服务，返回匹配设备的控制页地址 |
| `start_recording` | `device?` | 开始录制 MP4，返回 `recording_id`、设备标识和 Mac 上的 `local_path` |
| `stop_recording` | `recording_id` | 按开始时返回的 ID 停止录制，等待文件写完后返回 `local_path` |
| `screenshot` | `device?` | JPEG 图像、尺寸、平台、坐标单位与原点 |
| `describe_ui` | `device?`, `format?: outline/json` | iOS 模拟器或真机开发签名应用的 UI 树；默认简洁文本，不附加原始私有对象 |
| `tap` | `x, y` 或一个元素选择器；`duration?` | 坐标点击支持可选按住时长；元素点击使用实时无障碍激活 |
| `long_press` | `x, y, duration?` | 长按，默认 **0.8 秒** |
| `touch_path` | `points, duration?, return_screen?` | 单指沿多个坐标连续拖动，全程一次按下和抬起 |
| `swipe` | `start_x, start_y, end_x, end_y, duration?` | 单指拖动，默认 **0.3 秒** |
| `gesture` | `preset, duration?` | 四个滚动和四个边缘手势；滚动默认 **0.5 秒**，边缘默认 **0.3 秒** |
| `button` | `button, duration?` | 硬件按钮，可指定按住时长 |
| `install_app` | `path` 或 `url` | 选择 Mac 上的绝对路径或 HTTP(S) 直链。iOS 真机使用签名 IPA，Android 使用单个 APK。iOS 模拟器使用本地 .app 或顶层包含一个模拟器版 .app 的网络 ZIP。成功后返回目标设备标识、包文件名和 `installed: true`。 |
| `launch_app` | `bundle_id` | iOS bundle ID 或 Android 包名/activity，启动或重新启动已安装的应用 |
| `type_text` | `text`，可选元素选择器 | iOS 模拟器及 iOS 27+ 真机 HID 键盘输入；指定选择器时先激活文本框 |

`connect_device` 等待设备会话打开后返回 `session_connected: true` 和 `preview_requested: true`；
这不代表已收到视频首帧（`first_frame_verified: false`）。窗口可见时启动预览，后台无窗口时保留请求，
打开窗口后开始预览；不会主动弹出窗口。已有会话会被复用。连接期间若用户切换选择，旧请求不会切回设备，
并报告选择已改变。配对、信任和开发者模式仍由设备与应用设置完成。
旧的直接调用方式仍可用：`screenshot`、`tap` 等会按需建立共享会话，无须强制先执行这两个新工具。

在 PhoneUse 设备列表中右击目标设备，选择「设置解锁密码…」，选择「无密码」，或输入设备已有的 4 位、6 位数字密码，再点「保存」。这只设置本机 PhoneUse 的解锁方式。iOS 模拟器默认先尝试无密码解锁。「设备设置 → 设备解锁」显示当前密码状态，点击「设置密码…」或「更改密码…」即可打开同一弹窗。已保存密码的设备在列表中显示钥匙图标。GUI 的「一键解锁」和
`unlock_device` 共用这项配置。MCP 调用只接受设备标识。无密码的普通锁屏可以直接尝试解锁。
iPhone 的 USB 镜像可能只显示密码页背景。iOS 解锁会先读取本机钥匙串，再从第一张可识别的原生截图确认空密码框和十个数字键。
PhoneUse 按这张图上的坐标连续输入整个 PIN，最后回读系统锁屏状态。键盘无法确认或输入框已有内容时返回 `needs_user_unlock`。
iOS 密码键盘识别支持简体中文、繁体中文和英文。真机重启后首次解锁需要用户操作。Android 需要已授权 ADB，
PhoneUse 在读取钥匙串后，从一次系统界面快照确认空密码框和十个数字键的位置，连续点按，再回读锁屏状态。点按期间会检查系统密码页是否仍可见。无法快速读取密码页状态的机型会重新核对布局，需要按回车的设备会再确认密码框已有输入。

`unlocked` 和 `already_unlocked` 表示回读成功。`no_passcode_required` 表示真机当前无需密码，
但系统没有提供锁屏界面状态。`needs_saved_pin` 要求用户在 GUI 保存密码，`needs_user_unlock` 要求用户在设备上解锁。
`unlock_unconfirmed` 或输入中断后，请核对设备和已保存的密码。一次输入结果未确认时，PhoneUse 会暂停使用该密码，直到用户重新保存。

输入操作（不含选择、连接与解锁）共同支持 `device`、`pre_delay`、`post_delay` 和 `return_screen`。
新参数 `duration`、`pre_delay`、`post_delay` 均以**秒**为单位；时长须大于 0 且不超过
10 秒，延迟允许 0–10 秒。`return_screen: true` 在操作及 `post_delay` 后再等待 0.6 秒截图。
截图失败会明确报告“操作已发送、截图失败”，不会将它伪装成输入失败或自动重发输入。

### 设备管理、旋转与折叠

先调用 `list_management_actions` 查询所选设备在当前状态下可用的管理操作。每次执行时会重新检查设备与本机工具链。关机模拟器可从 `list_devices` 取标识后直接传给 `start_simulator`；它会等待启动完成，设备发现列表可能稍后刷新。

| 工具 | 参数与效果 |
| --- | --- |
| `list_simulator_options` | 列出本机已安装的 iOS 运行时和各版本兼容的 iPhone / iPad 机型，无需选择设备 |
| `create_simulator` | 传入同一组选项中的运行时标识 `runtime` 与机型标识 `device_type`，可选 `name`。返回新设备的 `simulator:<UDID>`，保持关机，等待设备发现刷新后即可管理 |
| `start_simulator`、`shutdown_simulator` | 启动或关闭指定的模拟器 |
| `restart_device`、`rename_device` | 对模拟器或支持该能力的 iPhone / iPad 重启、改名；改名传 `name` |
| `erase_simulator`、`delete_simulator` | 分别抹掉应用、数据与设置，或删除整台模拟器；均须显式传完整设备标识 `device` |
| `unpair_device` | 解除与 Xcode 的配对；须显式传完整真机标识 `device` |
| `show_device_in_finder`、`open_carplay_simulator` | 前者在 Mac 打开设备目录并返回路径；后者为有线 iPhone 打开已安装的 CarPlay Simulator |
| `collect_sysdiagnose` | 从支持的真机收集诊断，`directory` 为 Mac 上已有目录的绝对路径，调用可能持续数分钟 |
| `rotate_simulator` | `direction` 为 `left` 或 `right`，每次 90° |
| `set_simulator_posture` | 支持折叠的模拟器接受 `closed`、`partiallyOpen`、`openFlat` |

旋转和折叠使用当前设备会话；返回的 `width`、`height` 单位为 points。改变屏幕形态前会结束目标设备上的录屏；有 MCP 录屏时，结果的 `saved_recording.local_path` 提供文件路径。下一次触摸前应重新截图。

### 应用沙箱文件

对就绪的 Android 真机或模拟器，先调用 `list_apps`，选择 `containerAccessible: true` 的包名作为 `bundle_id`。随后可用 `list_sandbox_files` 浏览根目录或子目录、用 `read_sandbox_file` 读取最多 64 KiB 的 UTF-8 文本、用 `download_sandbox_file` 将单个文件保存到 Mac 上尚不存在的绝对路径。Android 使用当前用户授权的 ADB 和 `run-as`，iOS 使用 CoreDevice。两者都可以在设备预览关闭时读取。

### 设备设置

`get_device_settings` 的 `group` 可取 `appearance`、`voice_over`、`audio`、`locations`。各组独立读取，并返回当前后端 `source`。外观值和可用选项依赖设备及 Xcode 版本，位置组返回可用的模拟位置预设。

- `set_appearance` 每次写一个字段。支持 `style`、`tinted_glass`、`glass_opacity`、`text_size`、`color_filter`、`reduce_motion`、`increase_contrast`、`reduce_transparency`、`show_borders`、`voice_over`。例如 `{"style":"dark"}` 或 `{"voice_over":true}`。
- `set_audio` 可设置整数音量 `volume`（0 到 100），以及 `input`、`output`。路由使用音频组列出的设备 UID，或 `systemDefault`。
- `set_location` 可传 `preset`，也可传一对 `latitude`、`longitude`。传 `{"clear":true}` 恢复真实位置。

### 连续触摸

`touch_path` 在一个调用内保持单指接触，按顺序经过 2 到 256 个点。沿相邻点线性移动，每段平分请求时长，可重复同一点实现停留。默认时长为 0.5 秒，最长 10 秒；实际投递速度受设备影响。所有坐标在按下前完成校验。支持现有输入工具的 `pre_delay`、`post_delay` 和 `return_screen`。

```json
{"name":"touch_path","arguments":{"points":[{"x":40,"y":160},{"x":120,"y":160},{"x":120,"y":80}],"duration":0.6,"return_screen":true}}
```

### 坐标和 UI 树

- `screenshot` 返回的一个图像像素对应一个输入坐标：iOS 为 **points**，Android 为 **pixels**。
  原点为左上角，X 向右、Y 向下。坐标和截图使用同一尺寸。
- iOS 坐标为设备的**原生竖屏 framebuffer** 坐标，Android 为当前显示坐标。
  这与 sim-use 默认的方向校准 UI 坐标有区别；不要将横屏 UI 树的 frame 直接当作截图坐标。
- 模拟器 `describe_ui` 的 frame 使用无障碍 UI 点坐标，`coordinateSpace` 为
  `accessibility-ui-points`。元素点击走无障碍激活，不靠猜测旋转或换算 frame。
- 元素包含 `type`、`id`、`label`、`value`、`enabled`、`frame`、`depth`。
  安全文本框不返回其值。遍历最多 500 个元素、32 层；到达上限会返回 `truncated: true`。
  读取有超时限制，不自动重启模拟器或它的无障碍服务。
- 真机使用 `coordinateSpace: unavailable`，不返回 `frame` 或 `value`，未报告的启用状态省略 `enabled`。
  保留设备返回的角色名称用于 `element_type` 匹配，不通过坐标推测元素位置。
  层级查询使用 `_AXHierarchyElementsAttribute`，不移动检查器焦点，也不会为读取树主动滚动页面。
  真机读取/操作最多执行 30 秒（含排队，不含有限的清理时间）；截断树不能证明匹配唯一，因此拒绝按元素操作。
- 自绘界面、部分 WebView 和跨进程弹层可能缺失控件；UI 树不保证覆盖所有可见内容。
  缺失时查看截图；无障碍服务错误不会伪造空树或成功操作。

### 元素选择器和输入

`tap` 和 `type_text` 接受以下三者之一：

```json
{"id": "login.email"}
{"label": "登录", "element_type": "Button"}
{"label_contains": "回复", "element_type": "Button"}
```

`id` 和 `label` 精确匹配，`label_contains` 为区分大小写的子串匹配；`element_type`
是可选角色过滤器。每次操作重新读取树，必须恰好匹配一个元素；已知禁用或忽略的元素会拒绝。真机无法确认启用状态时不伪造状态，激活后需验证。
找不到或匹配多项时返回候选，要求重新读取并细化选择器，不选择第一项。
选择器不能混用，`tap` 的选择器也不能与坐标或 `duration` 混用。
当前没有 sim-use 的 `@N`/列表缓存别名，也不承诺 MobileBuildMCP 的 `elementRef` 快照协议兼容。

`type_text` 与 sim-use 的 HID `type` 一样支持 US 键盘字符：英文字母、数字、标点、空格、
换行和 Tab，模拟器单次最多 10000 字符、真机最多 500 字符。它在当前光标/选区输入，不清空整个文本框，
并遵循设备当前键盘、输入法及智能标点设置；输入法组合态和候选需要另外确认。
中文、emoji 等需要在屏幕输入法中输入；整段包含不支持字符时，会在激活文本框或发送任何键之前拒绝。
未指定选择器时，应先点击输入框；指定选择器时，目标必须为文本输入控件。
键盘发送途中出错会释放按键和修饰键，提示先检查已输入的内容，不自动重放整段文字。

示例 `tools/call` 参数：

```json
{"name": "list_devices", "arguments": {}}
{"name": "select_device", "arguments": {"device": "simulator:<UDID>"}}
{"name": "connect_device", "arguments": {}}
{"name": "describe_ui", "arguments": {"device": "simulator:<UDID>"}}
{"name": "tap", "arguments": {"device": "simulator:<UDID>", "id": "login.submit"}}
{"name": "type_text", "arguments": {"device": "simulator:<UDID>", "id": "login.email", "text": "user@example.com"}}
{"name": "gesture", "arguments": {"device": "simulator:<UDID>", "preset": "scroll-up", "duration": 0.5}}
```

### 手势和按钮

手势名与 sim-use / XcodeBuildMCP 的单指预设一致：

`scroll-up`、`scroll-down`、`scroll-left`、`scroll-right`、
`swipe-from-left-edge`、`swipe-from-right-edge`、`swipe-from-top-edge`、`swipe-from-bottom-edge`。

方向表示**手指及内容移动方向**：`scroll-up` 向上拖动内容，显示下方内容（阅读顺序的下一页）。
手势根据实际屏幕尺寸计算。iOS 方向沿原生竖屏坐标轴；边缘手势的具体系统行为取决于 OS 和页面。
暂不支持 pinch、双指旋转或多指手势。

按钮名为 `home`、`lock`、`side-button`、`siri`、`volume-up`、`volume-down`、`back`、`recents`。
`side-button` 映射到锁屏按钮，`recents` 映射到 Android 应用切换。
`back/recents` 仅 Android 支持，`siri` 仅 iOS 支持；不支持的组合会在发送输入前拒绝。
暂不提供 sim-use 的 Apple Pay 双击按钮。

## 兼容与边界

`tools/list` 发布新名称，同时继续接受旧调用：

| 旧调用 | 新调用 |
| --- | --- |
| `get_screen` | `screenshot` |
| `press_button` | `button` |
| `swipe.from_x/from_y/to_x/to_y` | `start_x/start_y/end_x/end_y` |
| `long_press/swipe.duration_ms` | `duration`，将毫秒换算为秒 |
| `app_switch`、`volume_up`、`volume_down` 按钮值 | `recents`、`volume-up`、`volume-down` |

另接受 `ui` 和 `snapshot_ui` 作为 `describe_ui` 的调用别名，但不实现其他工具的完整协议。
新旧坐标字段或新旧时长字段不能同时提交；错误类型、超范围、未知参数不会被静默忽略。

iOS 真机的 UI 树和元素定位需要设备已配对、解锁、启用开发者模式，并且前台应用为
**开发签名（`get-task-allow=true`）**。系统、App Store、TestFlight 和分发签名应用不支持此层级接口，
继续使用截图及坐标操作。PhoneUse 复用现有 RSD 隧道和 Developer Disk Image；无需安装额外 Runner。

真机 `type_text` 使用当前依赖提供的临时 Universal HID 键盘，要求 **iOS 27+** 的屏幕流认证。
它复用已有屏幕流，不停止其他消费者的流；临时硬件键盘可能暂时收起屏幕键盘，结束时释放按键并关闭键盘连接。
不指定选择器时可向已聚焦输入框发送按键；指定选择器仍受开发签名限制。发送失败不自动重试。
Android 暂不支持 UI 树、元素定位和直接文本输入，原有截图、坐标输入、按钮与应用启动能力不变。
Framework 不依赖 MCP 或第三方工具，PhoneUse 和 Automation 仍保持相互独立。

## 参考来源

研究日期：2026-11-17。上游定义会变化，因此这是语义对齐，不是整个 API 的替代实现。

- [sim-use](https://github.com/lycorp-jp/sim-use)，本机 0.16.0 的 `--help` 和技能文档。
- [MobileBuildMCP UI automation](https://github.com/getsentry/MobileBuildMCP/tree/2998ac77ebbca59544e88a27f34bfb830db9d924/src/mcp/tools/ui-automation)。
  当前 `tap/swipe/type_text` 基于元素引用，且 `long_press.duration` 使用毫秒；
  PhoneUse 统一采用 sim-use 的秒语义，避免同名参数在不同操作间换单位。
- [Meta idb 对 CoreSimulator 无障碍桥接的说明](https://github.com/meta/idb/blob/v1.1.0/FBSimulatorControl/Commands/FBSimulatorAccessibilityCommands.m)。
  PhoneUse 使用独立的运行时桥接实现，没有引入 idb framework。

## 验证

离线回归：`swift test`。它验证工具分发、兼容参数、坐标换算、无效输入、设备歧义、
平台限制、选择器匹配和键盘映射；不代表实际设备输入成功。

已启动模拟器的只读检查：

```sh
DEVICEHUB_SIMULATOR_UDID=<UDID> swift test --filter UIAutomationTests.testLiveSimulatorAccessibility
```

输入检查必须另外显式启用，并先在测试模拟器打开“设置”首页。测试会进入“通用”、返回、
在搜索框键入 `424242`，再从新的 UI 树确认精确字段值；同时检查原生坐标点击。普通回归不会操作设备：

```sh
DEVICEHUB_SIMULATOR_UDID=<UDID> PHONEUSE_LIVE_UI_ACTIONS=1 swift test --filter UIAutomationTests.testLiveSimulatorInteractions
```


真机只读集成检查（先解锁并打开开发签名应用，普通测试不会连接设备）：

```sh
PHONEUSE_PHYSICAL_UDID=<UDID> PHONEUSE_PHYSICAL_CONNECTION=usb \
PYTHONPATH=Daemon .venv-daemon/bin/python -m unittest discover -s Daemon/tests -p test_ios_ui.py -k test_live_physical_hierarchy -v
```

无线设备可将 connection 设为 `network`，需要 PhoneUse 已有可用的配对通道。
该检查只验证层级读取，不代表元素激活、文字送达或 macOS 侧边栏视觉效果已验证。
