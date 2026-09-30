# JavaScript API

[English](js.en.md) · [漫画源开发说明](comic_source.zh.md) · [返回文档索引](../README.md#开发-api)

本文档是 VeneraNext 扩展运行时 API 参考。函数名与调用以 [assets/init.js](../../assets/init.js) 与宿主实现 [js_engine.dart](../../lib/foundation/js_engine.dart) 为准。

## 运行环境

源脚本在 QuickJS 引擎中执行，支持 ES2020 标准 JavaScript 语法，以及本文列出的应用专用 API。环境不包含 Node.js 原生模块或浏览器 DOM 全局对象。跨语言桥接时请使用字符串、数字、布尔值、普通对象和数组；操作二进制数据时使用 `ArrayBuffer`。

## Network 网络

所有网络请求函数均返回 Promise。网络传输错误会抛出异常；HTTP 4xx/5xx 状态码通常仍返回响应对象，扩展需自行检查 `status`。

| 方法 | 返回值 | 说明 |
|---|---|---|
| `Network.get(url, headers?, extra?)` | `Promise<{status, headers, body}>` | 发起 GET 请求，`body` 为字符串 |
| `Network.post(url, headers?, data?, extra?)` | `Promise<{status, headers, body}>` | 发起 POST 请求 |
| `Network.put(url, headers?, data?, extra?)` | `Promise<{status, headers, body}>` | 发起 PUT 请求 |
| `Network.delete(url, headers?, extra?)` | `Promise<{status, headers, body}>` | 发起 DELETE 请求 |
| `Network.patch(url, headers?, data?, extra?)` | `Promise<{status, headers, body}>` | 发起 PATCH 请求 |
| `Network.sendRequest(method, url, headers?, data?, extra?)` | `Promise<{status, headers, body}>` | 自定义 HTTP 动词请求 |
| `Network.fetchBytes(method, url, headers?, data?, extra?)` | `Promise<{status, headers, body: ArrayBuffer}>` | 发起请求并以 ArrayBuffer 形式接收二进制响应体 |

- `headers`：普通键值对象，值均为字符串。
- `data`：请求体数据，可为字符串、二进制 ArrayBuffer 或对象。提交 JSON 时需自行 `JSON.stringify` 并设置 `Content-Type: application/json`。
- 请求头包含 `headers["cache-time"] = "no"` 可要求跳过底层短期网络缓存。

### Cookie 管理

| API | 说明 |
|---|---|
| `new Cookie({name, value, domain?})` | 构造 Cookie 对象 |
| `Network.setCookies(url, cookies)` | 为指定 URL 设置 Cookie 数组 |
| `Network.getCookies(url)` | 同步获取指定 URL 匹配的 Cookie 数组 |
| `Network.deleteCookies(url)` | 删除指定 URL 的 Cookie |

### fetch

`fetch(url, {method?, headers?, body?})` 返回 Promise，包装了基础的 fetch 操作。返回对象提供 `ok`、`status`、`statusText`、普通对象 `headers`，以及异步方法 `text()`、`json()`、`arrayBuffer()`。

### WebSocket 连接

`Network.WebSocket.connect(url, headers = {}, options = {})` 建立通用 WebSocket 连接。

- `options` 支持：
  - `protocols?: string[]`：子协议列表。
  - `connectTimeoutMs?: number`：连接超时毫秒数，默认 30000。
- 返回 `WebSocketConnection` 对象：
  - `id` (`string`)：连接唯一标识。
  - `protocol` (`string`)：协议。
  - `closed` (`boolean`)：连接是否已关闭。
  - `send(data: string | ArrayBuffer | ArrayBufferView): Promise<void>`：发送文本或二进制帧。
  - `receive(): Promise<string | ArrayBuffer>`：等待并接收下一条消息（文本返回 string，二进制返回 ArrayBuffer）。同一时刻仅允许一个等待中的 receive。
  - `close(code = 1000, reason = ""): Promise<void>`：关闭连接。
- 连接断开、传输错误均通过 Promise rejection 抛出。该 API 提供基础双向传输，不内置自动重连或心跳逻辑。

## HTML 解析

`new HtmlDocument(htmlString)` 解析 HTML 文本为文档树结构，解析后不执行任何内嵌脚本。

| 对象与方法 | 说明 |
|---|---|
| `document.querySelector(selector)` | 查询首个匹配的 `HtmlElement`，无匹配返回 `null` |
| `document.querySelectorAll(selector)` | 查询所有匹配节点，返回 `HtmlElement[]` |
| `document.getElementById(id)` | 按 ID 查找元素 |
| `document.dispose()` | **释放文档占用的原生内存**。提取所需数据后应显式调用 |
| `element.text` | 元素及子节点的纯文本内容 |
| `element.innerHTML` | 元素的内部 HTML 字符串 |
| `element.attributes` | 属性映射字典（如 `element.attributes["href"]`） |
| `element.children` | 子元素列表 `HtmlElement[]` |
| `element.parent` / `previousElementSibling` / `nextElementSibling` | 节点导航 |

```javascript
const doc = new HtmlDocument('<div class="list"><a href="/1">Item 1</a></div>');
try {
    const link = doc.querySelector("a");
    const href = link?.attributes["href"];
} finally {
    doc.dispose();
}
```

## Convert 数据转换与加解密

所有 Convert 方法均为同步调用，处理二进制数据时入参与返回值采用 `ArrayBuffer`：

| API | 功能 |
|---|---|
| `Convert.encodeUtf8(text)` / `decodeUtf8(bytes)` | UTF-8 字符串与 ArrayBuffer 互转 |
| `Convert.encodeGbk(text)` / `decodeGbk(bytes)` | GBK 字符串与 ArrayBuffer 互转 |
| `Convert.encodeBase64(bytes)` / `decodeBase64(text)` | 二进制与 Base64 字符串互转 |
| `Convert.hexEncode(bytes)` | 二进制转十六进制字符串 |
| `Convert.md5(bytes)`、`sha1(bytes)`、`sha256(bytes)`、`sha512(bytes)` | 哈希摘要计算，返回摘要字节 ArrayBuffer |
| `Convert.hmac(key, bytes, hash)` | HMAC 签名计算，返回 ArrayBuffer |
| `Convert.hmacString(key, bytes, hash)` | HMAC 签名计算，返回十六进制字符串 |
| `Convert.encryptAesEcb(bytes, key)` / `decryptAesEcb(bytes, key)` | AES-ECB 加解密 |
| `Convert.encryptAesCbc(bytes, key, iv)` / `decryptAesCbc(bytes, key, iv)` | AES-CBC 加解密 |
| `Convert.encryptAesCfb(bytes, key, iv, blockSize)` / `decryptAesCfb(...)` | AES-CFB 加解密 |
| `Convert.encryptAesOfb(bytes, key, blockSize)` / `decryptAesOfb(...)` | AES-OFB 加解密 |
| `Convert.decryptRsa(bytes, key)` | RSA PKCS#1 解密；`key` 为 Base64 编码的 PKCS#8 DER 私钥 |
| `Convert.encodeGzip(bytes)` | **Gzip 压缩**：将输入 ArrayBuffer 压缩为 Gzip 格式字节流 |
| `Convert.decodeGzip(bytes)` | **Gzip 解压**：将 Gzip 格式的 ArrayBuffer 解压为原始数据流 |

## 图片处理与排版约束

### ImageLoadingConfig

`comic.onImageLoad` 与 `comic.onThumbnailLoad` 返回普通对象配置图片请求：

| 字段 | 类型 | 说明 |
|---|---|---|
| `url` | `string?` | 实际请求图片 URL，缺省使用 image key |
| `headers` | `object?` | 自定义 HTTP 请求头映射 |
| `method` | `string?` | HTTP 动词，默认 GET |
| `data` | `any?` | 请求体 |
| `onResponse(bytes)` | `Function?` | 接收下载的原始 ArrayBuffer，返回修改后的图片 ArrayBuffer；正文与缩略图均支持 |
| `modifyImage` | `string?` | 定义 `function modifyImage(image)` 的脚本字符串，在独立引擎内重排位图；仅章节正文有效 |
| `onLoadFailed()` | `Function?` | 章节图片失败重试钩子，返回新的 `ImageLoadingConfig`；仅章节正文有效 |

### Header 解析与 User-Agent 回退契约

1. **Source UA 优先**：源显式指定的 Header 优先级最高。
2. **大小写不敏感**：根据 HTTP 规范，匹配 `User-Agent`、`user-agent` 等任意形态。只要存在，绝不被默认 UA 覆盖。
3. **缺省 fallback**：未指定 UA 时，自动补入应用默认浏览器标识（`user-agent: webUA`）。
4. **独立映射**：解析后输出独立的新可变 Map，类型非法时抛出明确异常。

### ComicImageLoadTarget 排版约束（仅 onImageLoad）

`comic.onImageLoad(url, comicId, epId, target)` 接收第四个参数：

- `logicalWidth` (`number | null`)：容器逻辑宽度（dp）；条漫左右边距生效时为扣除边距后的实际宽度。
- `logicalHeight` (`number | null`)：容器逻辑高度（dp）。
- `devicePixelRatio` (`number`)：屏幕 DPR。
- `fit` (`"contain" | "fitWidth" | "fitHeight"`)：排版适应模式。
- `splitWideImage` (`boolean`)：是否开启大图双页拆分。
- **`target: null`**：表示无特定 Reader 视口约束（原图保存、复制、分享、通用预加载）。源根据意图决定是否提供原图。

### 图片处理沙箱与 Image API

`modifyImage` 脚本字符串中可使用 `Image` 对象：

| 方法与属性 | 说明 |
|---|---|
| `image.width`、`image.height` | 图像宽高尺寸 |
| `image.copyRange(x, y, width, height)` | 裁剪矩形区域并返回新 Image |
| `image.copyAndRotate90()` | 旋转 90 度 |
| `image.fillImageAt(x, y, other)` | 将另一张图粘贴到当前图指定坐标 |
| `image.fillImageRangeAt(x, y, other, sx, sy, w, h)` | 区域复制粘贴 |
| `Image.empty(width, height)` | 创建空白位图 |

## 源数据与应用环境

### 源实例方法

- `this.loadData(key)`：读取当前源的持久化数据字符串。
- `this.saveData(key, value)`：持久化保存当前源数据。
- `this.deleteData(key)`：删除指定数据项。
- `this.loadSetting(key)`：读取当前源设置项的值。
- `this.isLogged`：布尔值，当前源登录状态。
- `this.translate(text)`：查当前源词典翻译文案。

### APP 全局信息与剪贴板

- `APP.version`：应用当前版本号字符串（如 `"2.2.1"`）。
- `APP.locale`：当前系统语言（如 `"zh_CN"`、`"en_US"`）。
- `APP.platform`：当前运行平台（`"android"`、`"ios"`、`"windows"`、`"macos"`、`"linux"`）。
- `setClipboard(text)`：异步写入系统剪贴板。
- `getClipboard()`：异步读取系统剪贴板文本。

## UI 交互

| API | 说明 |
|---|---|
| `UI.showMessage(message)` | 底部展示短暂提示文本 |
| `UI.showDialog(title, content, actions)` | 弹出对话框，`actions` 包含 `[{text, callback, style}]` |
| `UI.launchUrl(url)` | 调用系统默认应用打开外部 URL |
| `UI.showLoading(onCancel?)` | 显示全局加载指示器，返回加载框 ID |
| `UI.cancelLoading(id)` | 关闭对应 ID 的加载指示器 |
| `UI.showInputDialog(title, validator?, image?)` | 弹出输入框，返回 `Promise<string|null>` |
| `UI.showSelectDialog(title, options, initialIndex?)` | 弹出单选对话框，返回 `Promise<number|null>` |

## 日志、计时器与后台计算

- `log(level, title, content)`：输出应用日志，级别包含 `info`、`warning`、`error`。
- `console.log(value)`、`console.warn`、`console.error`：控制台输出。
- `createUuid()`：生成基于时间的 UUID 字符串。
- `randomInt(min, max)`、`randomDouble(min, max)`：生成伪随机数。
- `setTimeout(callback, delayMs)`：一次性延时回调。
- `setInterval(callback, delayMs)`：周期定时器，返回对象包含 `timer.cancel()`。
- `compute(functionCode, ...args)`：在后台工作线程中执行计算密集型 JS 代码并返回结果 Promise。
