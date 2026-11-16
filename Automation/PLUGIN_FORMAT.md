# automation 插件文件格式 v1

automation 的标准插件分发文件是 `.dhplugin`。插件包包含任务代码与所需资源；用户导入的作业、任务参数和运行记录不打入插件包。

| 项目 | 约定 |
| --- | --- |
| 扩展名 | `.dhplugin` |
| 建议文件名 | `<id>-<version>.dhplugin`，例如 `plugin-1.0.0.dhplugin` |
| 容器 | ZIP，根目录直接包含 `plugin.json` |
| 描述版本 | `schema: "devicehub.plugin.v1"`、`api_version: 1` |
| macOS 类型标识 | `dev.devicehub.plugin` |
| 建议 HTTP Content-Type | `application/vnd.devicehub.plugin+zip` |

文件名便于分发；插件身份与版本以包内 `plugin.json` 为准。服务器也可以返回通用 ZIP 或二进制 Content-Type，安装器会校验实际压缩包内容。旧 `.zip` 包继续兼容；开发用插件目录仅保留 CLI 安装支持。

## 包结构

```text
my-plugin-1.0.0.dhplugin
  plugin.json
  python/
    my_plugin/
      __init__.py
      plugin.py
  resources/                 # 按插件需要提供
    pipeline/
    image/
  LICENSE                   # 随插件提供代码与资源许可
```

ZIP 内不能再套一层 `my-plugin/` 文件夹。描述中的路径必须相对插件根目录，不能指向包外。归档不得包含符号链接、重复路径或 `..` 路径段。压缩包与解压后内容均受 256 MiB 大小限制，归档最多 10,000 项；`plugin.json` 最大 256 KiB。

`plugin.json` 示例：

```json
{
  "schema": "devicehub.plugin.v1",
  "api_version": 1,
  "id": "my-plugin",
  "name": "示例插件",
  "version": "1.0.0",
  "description": "提供任务与文档导入。",
  "entrypoint": "my_plugin.plugin:create_plugin",
  "python_path": "python",
  "requires": {
    "runtime": ">=1.0.0,<2.0.0",
    "capabilities": ["screenshot", "touch", "portrait"]
  },
  "resources": ["resources"],
  "tasks": [],
  "task_types": [],
  "imports": []
}
```

`id` 使用小写字母开头的小写字母、数字和连字符，最长 64 字符。`version` 为一至三段数字，建议始终使用 `x.y.z`；当前不支持预发布或构建后缀。`entrypoint` 指向 Python 工厂函数，安装时只检查入口文件存在，不调用工厂。

`tasks`、`task_types`、`imports`、参数与 Python 接口沿用 [插件协议 v1](README.md#插件协议-v1)。资源必须在发布前准备完毕；含 `assets.json` 的插件还会按其中固定的内容哈希校验资源。SDK v1 使用宿主内嵌的 Python、MaaFramework 和依赖，不自动执行安装脚本或安装 pip 依赖。

## 打包和安装

在仓库根目录运行：

```sh
# 打包已经准备好资源的插件目录
PYTHONPATH=Automation .venv-maa/bin/python -m devicehub_runtime pack \
  --plugin /path/to/prepared-plugin \
  --output /path/to/plugin-1.0.0.dhplugin

# 从插件文件安装
PYTHONPATH=Automation .venv-maa/bin/python -m devicehub_runtime install \
  --package /path/to/plugin-1.0.0.dhplugin

# 从 URL 安装
PYTHONPATH=Automation .venv-maa/bin/python -m devicehub_runtime install \
  --url 'https://example.com/releases/plugin-1.0.0.dhplugin'
```

App 的「安装插件」菜单提供相同的文件与 URL 安装方式。安装后插件出现在选择列表，需要点击「加载所选插件」才会成为当前插件；不会自动运行任务。安装与当前插件同 ID 的包后，当前插件会关闭，任务与配置保留，等待手动重新加载。

URL 必须使用 HTTP 或 HTTPS，并直接返回插件压缩包。发布平台的附件链接、带查询参数的下载链接和不带扩展名的下载接口均可使用；普通网页不能作为插件包。下载允许有限重定向，但每一跳仍须为 HTTP(S)，HTTPS 不可降级为 HTTP，URL 不接受内嵌用户名或密码。下载过程有大小和时间限制，失败会清理临时内容，不改变已安装版本。

安装器先将内容放入临时目录，检查描述、运行时兼容性、路径和资源，再移动到：

```text
~/Library/Application Support/DeviceHub/Plugins/<id>/<version>/
```

同 ID、同版本、同内容可重复安装；同版本内容不同会拒绝覆盖，作者应递增版本号。安装新版本保留旧版本文件，当前选择同 ID 的最高兼容版本。用户任务与参数单独保存，不因安装而删除。

打包命令输出整个归档的 SHA-256，供作者记录或分发时核对文件；这不是发布者签名，当前格式不包含签名或发布者身份验证机制。插件安装校验不会执行插件代码，加载后的任务检查与运行才按需进入对应 Python worker。
