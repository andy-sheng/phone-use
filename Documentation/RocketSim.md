# RocketSim 功能调研与 PhoneUse 迁移评估

调研日期为 2026-11-27。对象是 macOS 上已安装的 RocketSim **16.9.0（340）**，最低系统版本为 macOS 15.2。官方变更记录把 11 月 19 日的 16.9.0 列为最新正式版，把 16.9.1 和 17.0 列为待发布。以下按用户可以完成的任务盘点，区分官方说明、本地静态证据和对 PhoneUse 的工程判断。[官方版本记录](https://www.rocketsim.app/changelog/) · [官方功能目录](https://www.rocketsim.app/features/)

## 结论

- **RocketSim 提供按应用的弱网模拟。** 它能在 Mac 保持联网时，让指定模拟器应用断网、丢包或使用较慢的网络。按应用限定影响范围，是迁移时最需要验证的部分。[弱网文档](https://www.rocketsim.app/docs/features/networking/network-speed-control/)
- **与 PhoneUse 重叠最多的是设备预览、输入、截图、录屏和部分设置。** 当前工作树还实现了模拟器 9:41 状态栏、打开 URL、发送模拟推送。RocketSim 在这些动作之上提供了可复用的测试数据、画面标注、条件等待和素材后期。[PhoneUse 模拟器入口](../README.md#ios-模拟器) · [PhoneUse MCP 约定](MCP.md) · [RocketSim 功能目录](https://www.rocketsim.app/features/)
- **迁移可分两条线。** PhoneUse 已验证调试会话的限速、应用隔离和停止恢复，免接入弱网仍需评估系统扩展。标注截图、等待某个元素、按应用保存测试动作，可以复用已有设备会话，更适合先交付给 CLI 和 MCP 用户。以下迁移判断以当前仓库为基准。

## 一、网络调试

| 用户要验证什么 | RocketSim 16.9 能做什么 | 前提与边界 |
| --- | --- | --- |
| 应用断网时是否及时进入离线状态 | 选择 `airplane` 阻断目标应用的连接。GUI 在侧栏 Networking 中切换，CLI 可设置、查询和关闭 | 针对 iOS 模拟器应用。Mac 保持联网。此处的飞行模式指网络测试效果。[操作说明](https://www.rocketsim.app/docs/features/networking/network-speed-control/) |
| 应用有连接却一直收不到数据时，是否超时、允许取消或重试 | 选择 `100-loss`。官方把它与飞行模式分开，专门模拟连接看似存在、数据无法送达的情形 | 对应两种独立测试。此次未测各网络 API 的错误码或超时秒数。[离线与丢包区别](https://www.rocketsim.app/docs/features/networking/network-speed-control/) |
| 弱网下加载、上传和重试体验如何 | 另外六种预设为 `3g`、`edge`、`lte`、`wifi`、`dsl`、`very-bad`。界面可查看当前预设的配置 | 官网未在正文列出各档完整数值。本次未做带宽、时延或实际丢包率测量，也未确认用户可自定义这些数值。[预设与 FAQ](https://www.rocketsim.app/docs/features/networking/network-speed-control/) |
| 哪个原生请求失败、服务端返回了什么 | Network Monitor 展示受调试应用的 URLSession 请求、响应、头、状态码、耗时及日志，可复制 cURL | 需要 RocketSim Connect 和受支持的模拟器调试构建。官方将高级 Mock、响应改写等需求指向其他工具。PhoneUse 已有的 WebKit Network 面向网页会话。[Network Monitor](https://www.rocketsim.app/docs/features/networking/network-traffic-monitoring/) · [Connect 配置](https://www.rocketsim.app/docs/getting-started/setting-up-rocketsim-connect/) · [PhoneUse WebKit 协议](MCP.md#webkit-协议) |
| 哪些请求长期拖慢应用 | Networking Insights 可按应用、时间筛选已有记录，查看重复调用、失败峰值、慢端点、请求频率及缓存机会；可导出脱敏摘要，选带 JSON 结构或生成分析提示词 | 依赖之前采集到的请求。查看单条原始响应、复制 cURL 和导出脱敏摘要是不同的操作。[历史分析](https://www.rocketsim.app/docs/features/networking/networking-insights/) · [导出说明](https://www.rocketsim.app/docs/features/networking/network-request-prompts/) |

**范围与实现证据。** CLI 可指定一个或多个 Bundle ID。省略目标时，随包文档说明会选取 Recent Builds 中的应用及模拟器 URLSession 所需的辅助进程。使用需要 Pro 和用户批准 RocketSim 网络扩展。本机安装包确实包含 macOS System Extension，其配置声明了内容过滤提供者。请求监控走应用侧 Connect，限速走系统扩展。这解释了为什么 PhoneUse 加一个 Web Inspector 开关无法同时交付两项能力。[弱网文档](https://www.rocketsim.app/docs/features/networking/network-speed-control/) · [Connect 原理](https://www.rocketsim.app/docs/getting-started/setting-up-rocketsim-connect/)

**复核示例。** 以下是 RocketSim 的 CLI 命令，示例 Bundle ID 应替换为待测应用。分别观察发起请求后的错误状态、超时和重试，再关闭预设并重新请求。[CLI 操作](https://www.rocketsim.app/docs/features/networking/network-speed-control/)

```sh
rocketsim network set airplane --bundle-id com.example.shop
rocketsim network status
rocketsim network set 100-loss --bundle-id com.example.shop
rocketsim network off
```

**PhoneUse 已实现的部分。** 「网络请求」支持为单个模拟器、单个 Bundle ID 中主动接入的前台 URLSession 限速，并显示 HTTP/HTTPS 请求元数据。上下行分别限速，结束后重新启动应用恢复。RocketSim 的断网、丢包以及免接入的应用级流量整形仍是后续候选。[使用步骤](../README.md#模拟器网络请求与限速)

**RocketSim 仍待实测的部分。** 官方说明其实现针对 URLSession 做过优化，公开资料不足以保证任意网络库、后台代理流量或每个协议都有相同表现。CLI 的 Bundle ID 过滤也不能直接证明两台模拟器内同名应用可以独立限速。本次未启用扩展，未测异常退出后的恢复；16.9.0 的随包说明要求测试结束后执行关闭操作。[官方 FAQ](https://www.rocketsim.app/docs/features/networking/network-speed-control/) · [版本记录](https://www.rocketsim.app/changelog/)

## 二、开发者日常工作流

表中“已有”指 PhoneUse 当前工作树有相应入口。“部分”表示交付了基础操作，后面的文字指出实际差距。

| 工作流 | RocketSim 的具体能力 | PhoneUse 现状与迁移判断 |
| --- | --- | --- |
| 应用动作与测试数据 | 按 Bundle ID 关联最近构建，保存推送载荷、深链和位置；深链可带运行时参数。重测同一订单或页面时可直接调用已保存的动作。[App Actions](https://www.rocketsim.app/features/app-actions/) | **部分。** 模拟器 URL 和 APNs JSON 已接入 GUI、CLI、MCP。可补按应用保存、命名、传参和重复执行。 |
| 生命周期、本地化与权限 | 启动、终止、重启、卸载，主机与模拟器之间传递剪贴板内容；按 locale 重新启动，测试时区变化；模拟器上可授予、撤销、重置权限，以及重置整台模拟器的 Keychain。该按钮位于最近构建页，但影响范围是设备。[快捷动作](https://www.rocketsim.app/docs/features/app-actions/quick-actions/) · [应用动作](https://www.rocketsim.app/features/app-actions/) | **部分。** 已有应用安装和启动。可将指定语言重启、权限恢复至未决定状态做成明确的设备操作；重置 Keychain 时应显式显示受影响的模拟器及其设备级范围。 |
| GPS 与路线 | 地图选点、保存坐标、步行和驾车路线、沿路或直线路径，以及内置运动场景。部分真机可结合位置测试时区。[定位文档](https://www.rocketsim.app/docs/features/app-actions/location-simulation/) | **部分。** 已有坐标、预设和后端支持的场景；可补地图选点、路径点、速度和重复播放。 |
| 模拟器事件、相机与文件导入 | 摇一摇、模拟内存警告、外观切换、关闭模拟器。Device Hub 侧栏可把照片、视频、应用、推送文件、证书或链接交给当前模拟器。相机功能需要 Connect 与摄像头授权，可选 Mac 摄像头、连续互通相机或无摄像头，覆盖扫码、拍摄与缺设备回退。[模拟器动作](https://www.rocketsim.app/docs/features/app-actions/simulator-actions/) · [拖放导入](https://www.rocketsim.app/docs/features/app-actions/device-hub-file-imports/) · [相机](https://www.rocketsim.app/docs/features/capturing/simulator-camera-support/) | **部分。** 已有设备生命周期、应用安装、链接和推送。照片导入和系统测试事件可分别补齐。模拟器内应用读取 Mac 摄像头需要独立输入通道。 |
| 容器目录与偏好数据 | 快速打开当前模拟器应用的 Documents、Caches、App Group、File Provider 等目录；User Defaults 编辑器可搜索、过滤、观察和修改标准及 App Group 偏好。[目录访问](https://www.rocketsim.app/docs/features/app-actions/app-directory-access/) · [偏好编辑器](https://www.rocketsim.app/docs/features/user-defaults-editor/) | **部分。** 仓库已有真机应用容器和 Android 可访问文件的只读能力。可先增加模拟器应用目录定位，再单独验证偏好写入、类型保持及运行时刷新。[现有文件服务](DevicePlatforms.md#app-sandbox-files) |
| 屏幕素材与状态栏 | 截图及录像可加设备外框、背景、触点、应用信息；后期可裁剪视频、输出 GIF 或商店预览。支持音轨，在 Apple silicon 上支持模拟器 120 fps HEVC。状态栏除 9:41 外还可定制运营商、时间和电量。[录像](https://www.rocketsim.app/docs/features/capturing/recordings/) · [高帧率](https://www.rocketsim.app/docs/features/capturing/120-fps-recordings/) · [状态栏](https://www.rocketsim.app/docs/features/capturing/statusbar-appearance/) | **部分。** 有截图、Apple 设备录屏和模拟器状态栏预设。最小增量是可调状态栏和触点导出。录屏音轨、GIF 与素材编辑器各有独立的数据和性能要求。 |
| 设计还原 | 导入设计图，半透明叠加或用滑杆对比，可调缩放和偏移；另有网格、按 point 测量的标尺、慢动画、放大镜和取色复制。部分工具可用于真机预览。[设计比对](https://www.rocketsim.app/features/design-comparison/) | **可复用预览。** 先支持参考图叠加和滑杆；取色应返回原始画面颜色，标尺需处理屏幕缩放与旋转。没有证据表明必须接入在线 Figma 服务。 |
| 无障碍环境、导航与审计 | 切换文字大小、外观和辅助显示；VoiceOver Navigator 可按阅读顺序编号，按 Rotor 类别浏览和激活元素；Audit 检查标签、点击区域、重叠、对比度等，并给出证据和修复提示。启发式结果与未覆盖项单列。[无障碍功能](https://www.rocketsim.app/features/accessibility/) · [阅读顺序](https://www.rocketsim.app/docs/features/accessibility/voiceover-navigator/) · [审计](https://www.rocketsim.app/docs/features/accessibility/accessibility-audit/) | **部分。** 有部分设备设置、UI 树和元素激活。审计可先做标签及可测几何规则；阅读顺序须另行核实，直接给树节点按遍历顺序编号会误导。 |
| 构建效率与团队 | Recent Builds 让操作跟随最近的应用。Build Insights 从 DerivedData 识别构建，按 scheme、增量／全量、Xcode 和机器比较耗时趋势；另有团队视图、仅本地保存选项、按项目清理 Derived Data 和清理 SwiftUI 预览缓存。[构建洞察](https://www.rocketsim.app/docs/features/build-insights/build-insights/) · [团队与实用工具](https://www.rocketsim.app/pricing/) | **可独立评估。** 最近构建选取与设备测试关系最紧。团队构建统计面向另一类用户，本地工具可先提供按构建启动、安装及测试。 |
| 运行时性能分析 | Performance Trace 页能对符合条件的模拟器或真机优化构建启动和停止录制，检查构建与 dSYM，停止后交由独立产品 RocketTrace 处理。[16.4.5 发布说明](https://www.rocketsim.app/changelog/) | **外部产品集成。** 与上行的编译耗时统计分开。评估时应比较运行期采样、符号化和分析交付物。 |

## 三、AI 代理能多完成哪些事

| 任务 | RocketSim 16.9 行为 | 对 PhoneUse 的价值 |
| --- | --- | --- |
| 避免根据旧界面点击 | 元素树有导航、交互、调试三种详略。快照携带屏幕哈希，可只读变化；临时元素 ID 与观察时的画面关联。也可用稳定的 accessibilityIdentifier 定位，避开语言变化。[代理功能](https://www.rocketsim.app/features/agentic-development/) · [16.9 发布说明](https://www.rocketsim.app/changelog/) | 已有语义选择器和紧凑文本。值得补的是动作前校验观察版本，界面已变化时重新取树。 |
| 让人和模型指向同一个按钮 | `snapshot` 可把元素编号画在截图上，按标签、ID 或矩形裁剪。网页预览可联动元素树、框选画面、保留跨屏反馈并导出提示词；本地交互预览为 Beta，Pro 可选择局域网分享。[浏览器预览](https://www.rocketsim.app/docs/features/agentic-development/browser-preview/) | 已有原生元素面板和本地交互网页预览。优先打通同一观察的截图、控件框和反馈。模拟器横屏的 AX 点坐标要转换；当前真机树不返回元素框。[坐标约定](MCP.md#坐标和-ui-树) |
| 稳定跑完一段操作 | 可等特定元素出现、键盘显示或消失、屏幕变化；`do` 可顺序批处理，中间刷新并校验。模拟器还可触发生物识别成功／失败。折叠设备可控制姿态、读取铰链状态。[代理功能](https://www.rocketsim.app/features/agentic-development/) · [版本记录](https://www.rocketsim.app/changelog/) | 已有手势、按键、折叠姿态及 MCP 工具发现。条件等待可先独立提供，按条件和超时返回最新观察，减少脚本写死延迟。 |
| 生成可分享的演示与回归材料 | 16.9 随包 CLI 能从命令行录制有机框、触点和背景的视频；Duo 可按铰链姿态合成画面。保存命名流程、跨次回放、给流程做多环境对比及按流程录制演示，列在 17.0 预告。[录像说明](https://www.rocketsim.app/docs/features/capturing/recordings/) · [版本记录](https://www.rocketsim.app/changelog/) | 当前可对比即时录屏及批处理。持久化流程是另一阶段的产品决策，涉及脚本格式、目标重定位和失败回放。 |

## 四、设备和版本边界

| RocketSim 工作流 | iOS 模拟器 | 物理 iPhone / iPad |
| --- | --- | --- |
| 镜像、截图、录屏、设计比对 | 支持 | 支持；官方真机流要求 USB、开发配对、Xcode 可见 |
| 应用生命周期、按语言重启、深链、模拟位置 | 支持 | 官方矩阵列为 RocketSim 16.4 配合 Xcode 27；按目标能力显示 |
| 模拟推送、隐私权限、Keychain、User Defaults | 支持相应测试动作 | 官方矩阵未列支持 |
| Network Monitor、弱网和离线模拟 | 支持，前提见网络章节 | 官方明确未提供这两项 |
| 无障碍环境开关 | 支持，具体选项随 Xcode 和模拟器改变 | 官方真机矩阵标为待支持；本次未核验单台真机 |

历史发布记录也有 Apple Watch 模拟器支持、Apple TV 的截图与录屏、Vision Pro 的截图修复。它们能证明相应设备或捕获工作流，未据此推定这些平台支持上述弱网、代理操作或应用数据功能。[历史版本记录](https://www.rocketsim.app/changelog/)

PhoneUse 另有 Android、iOS 真机无线连接和网页调试后端，三者的可用能力需按设备分别判断。16.9 已有系统颜色滤镜；16.9.1 预告的实时色盲预览覆盖层，以及 17.0 的可保存 Flows，均未计入本报告的已发布功能。[官方真机矩阵](https://www.rocketsim.app/docs/features/physical-devices/) · [版本记录](https://www.rocketsim.app/changelog/) · [PhoneUse 平台说明](DevicePlatforms.md)

## 五、迁移顺序与验收

| 顺序 | 建议交付 | 能决定是否继续的验收结果 |
| --- | --- | --- |
| 扩展弱网覆盖 | 调试会话已可限速。后续候选为离线、全丢包和免接入限速。开发动作入口归 PhoneUse；任何公共设备能力放到 PhoneUseKit | 同一测试端点同时由目标应用、旁路应用和 Mac 访问，只有目标行为改变；分别观察新建连接、既有连接和后台 URLSession。在两台模拟器安装同 Bundle ID，验证隔离粒度。正常关闭、异常退出及设备切换后都能查明和恢复状态。 |
| 优先交付给代理 | 同一画面的编号截图、按元素裁剪、按条件等待 | 横竖屏和不同缩放下编号框仍对准控件；界面切换后旧标识被拒绝；等待超时带回最后一次观察。 |
| 复用现有动作 | 为深链、推送及位置添加按应用保存的测试预设；补模拟器权限重置和入口清晰的媒体导入 | 同一个预设能在同一应用的两次安装间重复执行；切换模拟器时不会发给上一台；推送自定义字段和 URL 参数完整保留。 |
| 单独立项 | 原生网络监控的更多协议与会话类型、模拟器相机、带音轨的素材后期、构建统计 | 先确定目标应用是否接受调试接入，或能提供哪些采样数据。每项分别评估设备覆盖、授权和运行开销。 |

## 六、本地证据与核查范围

- **主程序身份。** 安装包为 `/Applications/RocketSim.app`。主程序 SHA-256 为 `1770680c1c8e791a1e8be7321b1ed3f114f4292ca95c5619a444f3b22af8a5c0`。Mach-O 检查记录为 `ev_7f6eb1da1b92b10dbb29456aa2a2da11105e84bb2993e284aa7a5ebd55bd8e7a`。
- **网络扩展。** 包内 `Contents/Library/SystemExtensions/com.swiftLee.RocketSim.RocketSimNetworkExtension.systemextension` 的 Info.plist 将 `com.apple.networkextension.filter-data` 映射到 `FilterDataProvider`，签名权限包含 `content-filter-provider`。plist 检查记录为 `ev_2550ad005e18645332d1d2587c7b8305c011820ec68cf55ef1a78216d03b8e07`。这是扩展类型的证据，启用状态与真实流量效果仍须运行测试。
- **应用动作与构建。** 在资源包 `RocketSimAppActions_RocketSimAppActions.bundle` 的 `Model-v5.mom` 中可核对 Deeplink、PushNotification、Bundle ID、载荷及路线点字段。plist 检查记录为 `ev_711f514a57e107e1f3ff84435579afed87f897392166bdf15a3eca741642ff4f`。构建洞察资源包 `RocketSimInsights_RocketSimInsights.bundle` 的 `Model-v4.mom` 包含构建日志、scheme、构建类型、耗时和 Xcode 版本。
- **代理协议。** 安装包内 `Contents/Resources/Agent-Skill/rocketsim/references/commands.md` 可直接复查 Network Conditions、Blocking and Batching、Annotated Snapshots、Accessibility audit 和 Screenshots and Video 等章节。`preview.md` 另述预览的选择与反馈流程。
- **验证范围。** RocketSim 的结论来自公开文档与安装包静态检查。PhoneUse 新增网络功能经过模拟器实测。对同一 HTTPS 端点上传和下载各 64 KiB 时，32 KiB/s 档用了 4.15 秒，另一应用用了 0.032 秒，结束调试后原应用用了 0.033 秒。面板在会话运行期间收到状态码、脱敏 URL 和传输统计。上轮在 iOS 18.3.1 模拟器上实际验证的是 **PhoneUse** 的状态栏、深链和推送。没有运行 RocketSim 性能基准、网络实测或真机兼容测试。未找到足以将通用 API Mock、第三方应用 StoreKit 内购测试台或通用数据库编辑器列为 RocketSim 16.9 自带功能的证据。
