# 自动更新与发布

phone-use 使用 Sparkle 2。应用菜单中的「检查更新…」会下载并验证更新，用户确认后替换整个应用并重启。后台自动检查遵循 Sparkle 保存的用户偏好；不启用静默安装。应用内自动任务正在运行时，安装重启延后到任务结束。

应用标识仍为 `dev.devicehub.app`。设备记录、设置、已安装插件和任务保留在应用包外，更新不会将它们作为应用资源替换。外部插件不随发布包附带。

## 地址与密钥

- 源码仓库：`andy-sheng/phone-use`，保持私有。
- 公开发布仓库：`andy-sheng/phone-use-releases`，只存放发布附件和静态网站。
- Pages：`https://andy-sheng.github.io/phone-use-releases/`。
- 更新清单：同一地址下的 `appcast.xml`；`SUFeedURL`、`SUPublicEDKey` 由 `project.yml` 配置。
- Sparkle 版本与官方工具哈希固定在 `Package.swift`、`project.yml` 和 `scripts/sparkle-assets.json`。

私钥不属于应用资源，也不能提交到 Git。Developer ID 私钥用于 Apple 代码签名；Sparkle 的 Ed25519 私钥用于更新包与清单签名，二者分别管理。本机 Sparkle 密钥使用登录钥匙串中的 `phone-use` account。

## GitHub 一次性配置

公开发布仓库应包含一个只存静态文件的 `gh-pages` 分支。Settings → Pages 选择 **Deploy from a branch / gh-pages / root**。不要更改源码仓库的可见性。

在私有源码仓库设置 Actions variable：

| 名称 | 值 |
| --- | --- |
| `RELEASE_REPOSITORY` | `andy-sheng/phone-use-releases` |

在私有源码仓库设置以下 Actions secrets：

| 名称 | 内容 |
| --- | --- |
| `DEVELOPER_ID_P12` | 只包含本项目 Developer ID Application 身份的加密 P12，整体再编码为 Base64 |
| `DEVELOPER_ID_P12_PASSWORD` | P12 导出密码 |
| `APPLE_ID` | Apple 开发者账号邮箱 |
| `APPLE_TEAM_ID` | 与 Developer ID 证书一致的团队 ID |
| `APPLE_APP_SPECIFIC_PASSWORD` | Apple 公证用 App 专用密码 |
| `SPARKLE_PRIVATE_KEY` | `generate_keys --account phone-use -x` 导出的私钥内容 |
| `RELEASES_TOKEN` | Fine-grained PAT：仅选择公开发布仓库，授予 Contents read/write，保留默认 Metadata read |

`RELEASES_TOKEN` 不需要源码仓库访问权，也不需要 Workflow、Actions 或 Administration 权限。构建运行在私有源码仓库，其日志、诊断和 CI artifact 也保持私有。发布脚本只向公开仓库上传已验证的安装包、校验和、发布元数据和静态更新清单。

发布令牌到期前需更新同名 Secret。令牌只供 CI 发布使用；已经发布的安装包和客户端读取公开清单不依赖这个令牌。

CI 将证书导入临时钥匙串，验证公证凭据，并在 `always()` 清理步骤删除临时私钥文件和钥匙串。缓存只包含公开依赖和模型，不包含签名文件。发布只在版本标签或手动 dispatch 上运行，不在 PR 上使用签名密钥。

## 发布新版本

版本标签采用 `vMAJOR.MINOR.PATCH`。`CFBundleShortVersionString` 来自标签，`CFBundleVersion` 为 `1000 + GitHub Actions run number`，为本地验证构建预留较低编号；不要重命名发布 workflow 或重置其版本计数。

先提交经过验证的代码，再创建并推送标签，例如：

```sh
git tag v0.3.1
git push origin v0.3.1
```

也可以在 **Actions → Release macOS → Run workflow** 输入 `0.3.1`，从选定的可信分支发布。输入只接受三段数字版本号。每次发布必须使用新的版本号。

流水线依次执行：

1. 准备已校验的 ADB、scrcpy、Python（automation 另需 Maa）和 Sparkle 工具；运行 Swift、Python 和界面选择检查。
2. 构建 Release App，逐层签名 Python、动态库、Sparkle helper/XPC/framework 和主应用。
3. 公证 App 并附加票据，生成用于自动更新的 ZIP 和首次安装的 DMG；DMG 另行签名、公证和附加票据。
4. 验证签名、Gatekeeper、公证日志和校验和；用 Sparkle 工具生成并签名更新清单。
5. 上传公开 Release 并校验远端附件摘要，确认下载公开可用后更新 `gh-pages`。

已发布的版本附件不会覆盖。发布中断留下的 draft 可以在复核后重试；如果 Release 已公开，发布脚本只在附件摘要与本次产物一致时继续更新 Pages。Pages 发布有传播延迟。

当前工作流发布完整 ZIP，关闭差分生成。未来启用差分时需要保留旧版本完整 ZIP；不影响已有完整包更新路径。

## 本机验证/发布

首次准备 Sparkle 工具：

```sh
python3 scripts/prepare-sparkle.py
```

本机凭据使用登录钥匙串中的 `phone-use-notary` profile。将 `SIGN_IDENTITY` 设置为 Developer ID Application 证书名称后，明确指定保存凭据的钥匙串。本机构建编号同样必须高于线上清单中的最大编号，下面的 `1004` 只是示例，发布前需核对并递增：

```sh
NOTARY_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db" \
python3 scripts/release.py --version 0.3.1 --build-number 1004 \
  --repository andy-sheng/phone-use-releases
```

该命令只生成和验证 `dist/` 产物，不向 GitHub 发布。确认产物后可运行 `python3 scripts/publish-release.py`；它使用 `gh` 当前身份或 `GH_TOKEN`，先上传 Release，再更新静态分支。

## 验证边界

首次带 Sparkle 的版本需要用户手动安装一次。原来的 0.2.0 没有更新器，不能凭空自动获取这一能力。后续版本可通过应用内更新。

正式升级回归应使用两个已签名、公证且 build number 递增的版本，确认更新提示、签名验证、安装替换和重新启动；还要确认运行中的自动任务会延后重启。仅编译通过或运行清单解析测试不代表升级链路已验证。

## 首次发布验证

2026-11-08 已发布 [0.3.0（build 1003）](https://github.com/andy-sheng/phone-use-releases/releases/tag/v0.3.0)，[GitHub Actions 完整运行成功](https://github.com/andy-sheng/phone-use/actions/runs/42446336646)。

- macOS 26 ARM64 云端构建、Swift/Python/发布脚本回归、151 个原生文件签名、公证、票据和 Gatekeeper 检查均通过。
- DMG 和更新 ZIP 可匿名下载，远端摘要与发布清单一致；Pages 已部署，线上清单通过 Sparkle 签名验证。
- 本机独立测试副本从 build 1 经正式在线更新替换为 1003，观察到旧进程退出及安装器自行启动新进程；安装后的签名、公证票据和 Gatekeeper 检查通过，应用版本面板显示 0.3.0 (1003)。

真实升级回归在空闲状态下执行；应用内任务运行时延后重启的判断由单元测试覆盖。

参考：[Sparkle 接入](https://sparkle-project.org/documentation/)、[Sparkle 发布](https://sparkle-project.org/documentation/publishing/)、[Apple 公证](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。
