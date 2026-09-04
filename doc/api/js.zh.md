# JavaScript API

本文档是 JavaScript 扩展 API 的中文入口，用于快速理解接口分区和维护约定。完整英文签名参考见 [js.en.md](js.en.md)。

## API 分区

JavaScript API 主要分为以下几类：

| 分区 | 用途 |
|---|---|
| `Convert` | 字符串、二进制、Base64、Hash、HMAC、AES、RSA 等数据转换和加解密工具 |
| `Network` | 网络请求、资源加载、请求配置和响应处理 |
| `Html` | HTML 解析、节点查询和内容提取 |
| `UI` | 扩展设置、交互控件和用户界面辅助能力 |
| `Utils` | 常用工具函数 |
| `Types` | 漫画、章节、图片、分类、设置项等运行时类型约定 |

## WebSocket

`Network.WebSocket.connect(url, headers = {}, options = {})` 建立通用 WebSocket
连接。`options` 支持 `protocols` 和 `connectTimeoutMs`（默认 30000）。
返回对象包含 `id`、`protocol`、`closed`、`send(data)`、`receive()` 和
`close(code = 1000, reason = "")`。

`receive()` 返回 `{type: "message", data}` 或
`{type: "close", code, reason}`。同一连接同一时刻只允许一个等待中的
`receive()`；连接、发送和接收错误通过 Promise rejection 暴露。该 API
仅提供文本与二进制 WebSocket transport，不包含 SignalR、重连策略或
站点认证语义。

## 使用建议

- 新扩展应优先使用稳定 API，避免依赖内部实现细节。
- 网络请求参数、headers、referer 和 Cookie 处理应尽量集中封装，方便站点规则变化时维护。
- 返回给应用的漫画、章节和图片数据应保持字段类型稳定，避免同一字段在不同请求中返回不同类型。
- 图片加载逻辑应尽量返回可取消、可重试的请求信息，不要在脚本中做不必要的大量预下载。
- 扩展配置应通过设置项暴露给用户，不要把账号、Cookie 或站点特定参数写死。

## 维护约定

`js.en.md` 目前保留更完整的英文 API 签名和示例。后续修改 API 时应同步检查本文件：

- 如果新增 API 分区，在本文件的分区表中补充说明。
- 如果修改外部可见函数签名，在英文文档中更新签名，并在中文文档中补充迁移注意事项。
- 如果 API 变更会影响漫画源兼容性，应同时更新 [comic_source.zh.md](comic_source.zh.md) 和 [comic_source.en.md](comic_source.en.md)。

## 相关文档

- [漫画源开发说明（中文）](comic_source.zh.md)
- [Comic Source Guide (English)](comic_source.en.md)
- [JavaScript API (English)](js.en.md)
