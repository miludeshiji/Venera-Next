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

## 图片加载配置与 Header 处理契约（ImageLoadingConfig）

漫画源通过 `comic.onImageLoad` 与 `comic.onThumbnailLoad` 返回 `ImageLoadingConfig` 对象，为图片网络请求提供自定义配置。

### 适用范围与字段支持

| 钩子函数 | 适用场景 | 支持字段 | 特殊说明 |
|---|---|---|---|
| `comic.onImageLoad` | 章节正文图片加载 | `url`, `headers`, `method`, `data`, `onResponse`, `modifyImage`, `onLoadFailed` | 支持失败重试；`onLoadFailed` 返回的新配置同样遵循统一 Header fallback 规则；可选接收 `target` 排版约束参数 |
| `comic.onThumbnailLoad` | 缩略图与封面图片（首页推荐、分类浏览、搜索结果、详情页封面） | `url`, `headers`, `method`, `data` | 仅使用基础网络请求配置；`modifyImage` 与 `onLoadFailed` 在缩略图场景下不生效（被运行时忽略） |

### Header 解析与 User-Agent 回退规则

在所有图片请求（缩略图、封面、章节正文及章节重试）中，VeneraNext 统一遵循以下 Header 解析与 fallback 契约：

1. **Source UA 优先**：漫画源通过 `headers` 显式指定的 Header 拥有最高优先级。
2. **Header 名大小写不敏感**：根据 HTTP 规范，Header 名称判定大小写不敏感（例如 `User-Agent`、`user-agent`、`USER-AGENT`）。只要源返回的 `headers` 中包含任意大小写形式的 `User-Agent`，运行时均严格保留源指定的 UA，绝不会被默认浏览器 UA 覆盖，也不会重复追加默认 UA。
3. **缺省 UA fallback**：当漫画源未提供 `headers`、`headers` 为空对象，或者其中未包含任何形式的 `User-Agent` 时，运行时会自动回退补入默认客户端标识（`user-agent: webUA`）。
4. **独立可变映射与防御校验**：解析后的 headers 统一输出为独立的新可变 Map，避免直接污染原对象；若传入了非 Map/Object 等非法 headers 类型，运行时会抛出清晰明确的异常。


## 章节图片排版目标（ComicImageLoadTarget）

漫画源实现 `comic.onImageLoad(url, comicId, epId, target)` 时，可接收可选的第四个参数 `target`（类型为 `ComicImageLoadTarget | null`）：

- **排版约束定位**：
  - `target` 严格代表当前阅读器显示视口与排版容器的**布局约束**，**而非漫画源原图的原始尺寸或固有分辨率**。
- **字段与单位**：
  - `logicalWidth` (`number | null`)：目标显示容器的 Flutter 逻辑像素宽度（dp）。当宽度无约束时为 `null`。
  - `logicalHeight` (`number | null`)：目标显示容器的 Flutter 逻辑像素高度（dp）。当高度无约束时为 `null`。
  - `devicePixelRatio` (`number`)：设备像素比（DPR，如 1.0、2.0、3.0）。物理像素计算方式为 `Math.round(logicalWidth * devicePixelRatio)`。
  - `fit` (`"contain" | "fitWidth" | "fitHeight"`)：排版适应模式。
    - `"contain"`：双向受限（翻页或单图模式），宽高均非 `null`。
    - `"fitWidth"`：纵向连续滚动（条漫/瀑布流），宽度对齐视口，高度为 `null`。
    - `"fitHeight"`：横向连续滚动，高度对齐视口，宽度为 `null`。
  - `splitWideImage` (`boolean`)：当前阅读器是否开启了大图/跨页双页拆分模式。
- **`null` 语义与原图操作**：
  - 在无特定 Reader 排版约束的上下文（如通用预加载、未传递 target 的调用），`target` 为 `null`。
  - **原图操作**：保存原图、复制原图、分享原图或导出等操作均显式传入 `target: null`。
  - **最终策略由源决定**：应用通过 `target: null` 表达请求无视口限制原图的意图，但最终的实际加载策略、分流 CDN 和返回 URL 完全由漫画源的 `onImageLoad` 自行决定。
- **兼容性与缓存隔离**：
  - 仅接收 `(url, comicId, epId)` 的旧源完全兼容，无需修改。
  - 缓存机制会依据 `target` 规格（包括 `splitWideImage`）进行隔离，避免不同分辨率缓存交叉污染。
- **应用不规定图床算法**：
  - VeneraNext 仅向扩展提供客观的排版约束信息，不规定、不建议也不干预图床 CDN 的分辨率档位、参数转换或图片格式算法，漫画源可自由按需使用或忽略。
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
