# PhoneUse MCP 操作约定

PhoneUse 的工具命名和操作参数以 **sim-use 0.16.0** 为主要参照，并参考
XcodeBuildMCP（现已改名为 MobileBuildMCP）的 UI 自动化定义。工具在应用进程内通过
PhoneUseKit 的共享设备会话执行；无需另装 sim-use、idb、XcodeBuildMCP 或测试 runner。

## 发现、观察、操作、验证

1. 调用 `list_devices`，查看设备状态及 `capabilities`。只有 `ready` 设备可操作。
2. 多台设备就绪时必须传 `device`，优先使用返回的完整标识；名称匹配不唯一时也会报错。
3. iOS 模拟器优先用 `describe_ui` 读取界面，并用 `id`、`label` 或 `label_contains` 定位。
   真机、Android 或自绘控件使用 `screenshot`，根据返回图像的坐标操作。
4. 操作后再次读取 UI 树或截图验证。返回 `input_sent: true` 仅表示输入已发送，
   `ui_change_verified` 仍为 `false`，不表示页面或字段已经按预期变化。

## 工具

PhoneUse 窗口右侧的“界面结构”页签会实时显示同一份 `describe_ui` 文本。
先连接所选模拟器，面板打开时每次读取完成后间隔 1 秒刷新，支持暂停、立即刷新和复制。
切换页签、隐藏面板或进入紧凑窗口后停止读取；切换设备时清空旧内容，并忽略旧请求的迟到结果。
读取失败会显示错误及上次成功更新时间，后续刷新继续尝试。它复用预览会话，单纯选中设备不会建立连接。

| 工具 | 主要参数 | 支持范围与含义 |
| --- | --- | --- |
| `list_devices` | 无 | iOS/Android 真机与已启动的 iOS 模拟器；返回每台设备的能力 |
| `screenshot` | `device?` | JPEG 图像、尺寸、平台、坐标单位与原点 |
| `describe_ui` | `device?`, `format?: outline/json` | iOS 模拟器前台应用的 UI 树；默认简洁文本，不附加原始私有对象 |
| `tap` | `x, y` 或一个元素选择器；`duration?` | 坐标点击支持可选按住时长；元素点击使用实时无障碍激活 |
| `long_press` | `x, y, duration?` | 长按，默认 **0.8 秒** |
| `swipe` | `start_x, start_y, end_x, end_y, duration?` | 单指拖动，默认 **0.3 秒** |
| `gesture` | `preset, duration?` | 四个滚动和四个边缘手势；滚动默认 **0.5 秒**，边缘默认 **0.3 秒** |
| `button` | `button, duration?` | 硬件按钮，可指定按住时长 |
| `launch_app` | `bundle_id` | iOS bundle ID 或 Android 包名/activity，启动或重新启动已安装的应用 |
| `type_text` | `text`，可选元素选择器 | iOS 模拟器原生 HID 键盘输入；指定选择器时先激活文本框 |

输入操作共同支持 `device`、`pre_delay`、`post_delay` 和 `return_screen`。
新参数 `duration`、`pre_delay`、`post_delay` 均以**秒**为单位；时长须大于 0 且不超过
10 秒，延迟允许 0–10 秒。`return_screen: true` 在操作及 `post_delay` 后再等待 0.6 秒截图。
截图失败会明确报告“操作已发送、截图失败”，不会将它伪装成输入失败或自动重发输入。

### 坐标和 UI 树

- `screenshot` 返回的一个图像像素对应一个输入坐标：iOS 为 **points**，Android 为 **pixels**。
  原点为左上角，X 向右、Y 向下。坐标和截图使用同一尺寸。
- iOS 坐标为设备的**原生竖屏 framebuffer** 坐标，Android 为当前显示坐标。
  这与 sim-use 默认的方向校准 UI 坐标有区别；不要将横屏 UI 树的 frame 直接当作截图坐标。
- `describe_ui` 的 frame 使用无障碍 UI 点坐标，`coordinateSpace` 为
  `accessibility-ui-points`。元素点击走无障碍激活，不靠猜测旋转或换算 frame。
- 元素包含 `type`、`id`、`label`、`value`、`enabled`、`frame`、`depth`。
  安全文本框不返回其值。遍历最多 500 个元素、32 层；到达上限会返回 `truncated: true`。
  读取有超时限制，不自动重启模拟器或它的无障碍服务。
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
是可选角色过滤器。每次操作重新读取树，必须恰好匹配一个启用的元素。
找不到或匹配多项时返回候选，要求重新读取并细化选择器，不选择第一项。
选择器不能混用，`tap` 的选择器也不能与坐标或 `duration` 混用。
当前没有 sim-use 的 `@N`/列表缓存别名，也不承诺 MobileBuildMCP 的 `elementRef` 快照协议兼容。

`type_text` 与 sim-use 的 HID `type` 一样支持 US 键盘字符：英文字母、数字、标点、空格、
换行和 Tab，单次最多 10000 字符。它在当前光标/选区输入，不清空整个文本框，
并遵循设备当前键盘、输入法及智能标点设置；输入法组合态和候选需要另外确认。
中文、emoji 等需要在屏幕输入法中输入；整段包含不支持字符时，会在激活文本框或发送任何键之前拒绝。
未指定选择器时，应先点击输入框；指定选择器时，目标必须为文本输入控件。
键盘发送途中出错会释放按键和修饰键，提示先检查已输入的内容，不自动重放整段文字。

示例 `tools/call` 参数：

```json
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

UI 树、元素定位和直接文本输入目前仅适用于 **iOS 模拟器**。iOS 真机和 Android 保留
现有截图、坐标输入、按钮与应用启动能力；没有这些新增能力时会明确给出替代操作。
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
