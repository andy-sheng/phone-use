# PhoneUse MCP 操作约定

PhoneUse 的工具命名和操作参数以 **sim-use 0.16.0** 为主要参照，并参考
XcodeBuildMCP（现已改名为 MobileBuildMCP）的 UI 自动化定义。工具在应用进程内通过
PhoneUseKit 的共享设备会话执行；无需另装 sim-use、idb、XcodeBuildMCP 或测试 runner。

## 发现、观察、操作、验证

1. 调用 `list_devices`，查看设备状态及 `capabilities`。只有 `ready` 设备可操作。
2. 多台设备就绪时必须传 `device`，优先使用返回的完整标识；名称匹配不唯一时也会报错。
3. iOS 模拟器和真机中的开发签名应用优先用 `describe_ui` 读取界面，并用 `id`、`label` 或 `label_contains` 定位。
   真机中的系统/App Store/TestFlight 应用、Android 或自绘控件使用 `screenshot`，根据返回图像的坐标操作。
4. 操作后再次读取 UI 树或截图验证。返回 `input_sent: true` 仅表示输入已发送，
   `ui_change_verified` 仍为 `false`，不表示页面或字段已经按预期变化。

## 调用记录

PhoneUse 右侧“调用记录”页签实时显示 agent 发起的 MCP 工具调用，包括工具名、请求中的设备、
开始时间、执行中/已完成/失败状态、耗时及结果摘要。展开一条记录可查看参数和文本结果或错误。
记录覆盖所有设备，最新调用置顶；不传 `device` 时显示“自动选择设备”。
应用后台启动时也会记录，打开窗口后可查看；仅在内存中保留最近 200 条，退出即清空。
“清空记录”不取消正在执行的调用。参数和文本结果有长度上限，截图只显示类型，不保留图片编码。
这里记录的是 MCP `tools/call`，不包括侧栏自动刷新的 UI 树或手动操作；“已完成”表示工具返回成功，
不代表设备界面变化已经验证。

## 工具

PhoneUse 窗口右侧的“界面结构”页签会实时显示同一份 `describe_ui` 文本。
先连接所选 iOS 设备，面板打开时每次读取完成后刷新：模拟器间隔 1 秒、真机间隔 3 秒，错误后至少等待 5 秒。支持暂停、立即刷新和复制。
切换页签、隐藏面板或进入紧凑窗口后停止读取；切换设备时清空旧内容，并忽略旧请求的迟到结果。
读取失败会显示错误及上次成功更新时间，后续刷新继续尝试。它复用预览会话，单纯选中设备不会建立连接。

| 工具 | 主要参数 | 支持范围与含义 |
| --- | --- | --- |
| `list_devices` | 无 | iOS/Android 真机与已启动的 iOS 模拟器；返回每台设备的能力 |
| `screenshot` | `device?` | JPEG 图像、尺寸、平台、坐标单位与原点 |
| `describe_ui` | `device?`, `format?: outline/json` | iOS 模拟器或真机开发签名应用的 UI 树；默认简洁文本，不附加原始私有对象 |
| `tap` | `x, y` 或一个元素选择器；`duration?` | 坐标点击支持可选按住时长；元素点击使用实时无障碍激活 |
| `long_press` | `x, y, duration?` | 长按，默认 **0.8 秒** |
| `swipe` | `start_x, start_y, end_x, end_y, duration?` | 单指拖动，默认 **0.3 秒** |
| `gesture` | `preset, duration?` | 四个滚动和四个边缘手势；滚动默认 **0.5 秒**，边缘默认 **0.3 秒** |
| `button` | `button, duration?` | 硬件按钮，可指定按住时长 |
| `launch_app` | `bundle_id` | iOS bundle ID 或 Android 包名/activity，启动或重新启动已安装的应用 |
| `type_text` | `text`，可选元素选择器 | iOS 模拟器及 iOS 27+ 真机 HID 键盘输入；指定选择器时先激活文本框 |

输入操作共同支持 `device`、`pre_delay`、`post_delay` 和 `return_screen`。
新参数 `duration`、`pre_delay`、`post_delay` 均以**秒**为单位；时长须大于 0 且不超过
10 秒，延迟允许 0–10 秒。`return_screen: true` 在操作及 `post_delay` 后再等待 0.6 秒截图。
截图失败会明确报告“操作已发送、截图失败”，不会将它伪装成输入失败或自动重发输入。

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
