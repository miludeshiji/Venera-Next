# 漫画源开发说明

本文档说明如何为 VeneraNext 编写兼容 JavaScript 扩展 API 的漫画源扩展。英文版本见 [comic_source.en.md](comic_source.en.md)，JavaScript API 参考见 [js.zh.md](js.zh.md) 和 [js.en.md](js.en.md)。

## 重要声明

VeneraNext 只维护漫画阅读器本体和扩展运行环境。

本仓库不提供、内置、托管、推荐、维护或验证任何第三方漫画源、源列表、源站内容或版权状态。请不要在本仓库反馈与具体源仓库、源站、作品、章节缺失、图片可用性或版权相关的问题。

## 漫画源列表

应用可以显示用户自行配置的漫画源列表。源列表应指向一个 JSON 文件，格式如下：

```json
[
  {
    "name": "Source Name",
    "url": "https://example.com/source.js",
    "filename": "Relative path to the source file",
    "version": "1.0.0",
    "description": "A brief description of the source"
  }
]
```

`url` 和 `filename` 只应提供其中一个。`description` 可选。

## 开发准备

- 安装 VeneraNext，调试阶段建议直接用 Flutter 运行项目。
- 准备支持 JavaScript 的编辑器。
- 阅读 JavaScript API 文档，并创建本地 `.js` 文件进行测试。
- 确认扩展只处理接口逻辑，不把源站内容或第三方源列表提交到本仓库。

## 基础模板

漫画源通常继承 `ComicSource`，并提供基本信息、探索页、搜索、详情页、章节图片等能力。

```javascript
class NewComicSource extends ComicSource {
    name = ""
    key = ""
    version = "1.0.0"
    minAppVersion = "1.0.0"
    url = ""

    async init() {
        // Optional initialization.
    }
}
```

常见必填项：

- `name`：展示名称。
- `key`：唯一标识。发布后不要随意修改，否则会影响收藏、历史和缓存关联。
- `version`：扩展版本。
- `minAppVersion`：最低兼容应用版本。
- `url`：扩展更新地址，可按实际情况留空。

## 常见能力

漫画源可以按需实现以下能力：

- 探索页：提供首页、推荐、排行等入口。
- 分类页：提供分类、筛选和分页加载。
- 搜索：根据关键词返回漫画列表。
- 漫画详情：返回标题、封面、简介、标签、章节列表等信息。
- 章节图片：返回章节内图片地址或图片加载信息。
- 收藏：对支持网络收藏的站点提供收藏、取消收藏、收藏夹等能力。
- 评论：对支持评论的站点提供评论读取、发送、点赞或投票能力。
- 设置：为扩展提供独立配置项。
- 翻译：为扩展内文本提供本地化。

具体函数签名和运行时对象请参考 [js.zh.md](js.zh.md) 与 [js.en.md](js.en.md)。

## 图片加载与网络配置（onImageLoad 与 onThumbnailLoad）

漫画源可以通过 `comic.onImageLoad` 与 `comic.onThumbnailLoad` 为图片请求提供自定义网络配置（如 Headers、Referer 或分流地址）。两者返回的配置对象遵循通用的 Header 处理与回退契约。

### 适用范围与功能差异

1. **章节正文图片（`comic.onImageLoad`）**：
   ```javascript
   onImageLoad: (url, comicId, epId, target) => {
       return {
           url: url,
           headers: {
               "User-Agent": "CustomUA/1.0"
           },
           onLoadFailed: () => {
               // 加载失败时可返回新的 ImageLoadingConfig 进行重试
               return { url: retryUrl, headers: { "User-Agent": "CustomUA/1.0" } };
           }
       }
   }
   ```
   - 适用于章节正文图片的请求配置。
   - 支持完整 `ImageLoadingConfig` 字段（`url`、`headers`、`method`、`data`、`onResponse`、`modifyImage`、`onLoadFailed`）。
   - 可选接收第四个参数 `target`（类型为 `ComicImageLoadTarget | null`），用于获取当前阅读器的排版约束。
   - 当章节图片加载失败触发 `onLoadFailed` 时，返回的新配置同样受到统一的 Header 回退规则约束。

2. **缩略图与封面图片（`comic.onThumbnailLoad`）**：
   ```javascript
   onThumbnailLoad: (url) => {
       return {
           url: url,
           headers: {
               "User-Agent": "CustomUA/1.0"
           }
       }
   }
   ```
   - 适用于首页推荐、探索/分类列表、搜索结果等列表中的缩略图，以及漫画详情页封面图片。
   - 仅使用基础网络请求配置（如 `url`、`headers`、`method`、`data` 等）。
   - `modifyImage` 与 `onLoadFailed` 在缩略图场景下不生效（运行时会自动忽略）。

### Header 解析与 User-Agent 回退规则

无论在 `onImageLoad`、`onThumbnailLoad` 还是章节重试 `onLoadFailed` 中，VeneraNext 均遵循统一的 Header 处理契约：

- **Source UA 优先**：漫画源通过 `headers` 显式声明的请求头优先级最高。
- **Header 名大小写不敏感**：根据 HTTP 标准，Header 名称判定大小写不敏感（如 `User-Agent`、`user-agent`、`USER-AGENT`）。只要源返回的 headers 中存在任意大小写形态的 User-Agent，运行时均视为源已指定客户端标识，会严格保留源指定的值，绝不会被默认 UA 覆盖，也不会重复追加小写 `user-agent`。
- **缺省 UA fallback**：当漫画源未提供 `headers`、`headers` 为空对象，或者其中不包含任何形式的 `User-Agent` 时，运行时会自动回退补入默认的浏览器标识（`user-agent: webUA`）。
- **独立映射与类型安全**：解析后的 headers 均为独立的新可修改 Map；若传入了非 Map/Object 等非法 headers 类型，运行时会抛出明确异常。

### `target` 排版约束参数说明（仅用于 onImageLoad）

- **`target` 参数与字段**：
  - `target`（类型为 `ComicImageLoadTarget | null`）反映的是阅读器当前的**显示与排版布局约束**（容器视口与排版模式），**而非漫画源原图的固有尺寸、分辨率或期望大小**。
  - `logicalWidth` (`number | null`)：目标显示容器的逻辑像素宽度（dp）。当宽度无约束时为 `null`。
  - `logicalHeight` (`number | null`)：目标显示容器的逻辑像素高度（dp）。当高度无约束时为 `null`。
  - `devicePixelRatio` (`number`)：当前屏幕设备像素比（DPR，如 1.0、2.0、3.0）。物理像素可通过 `Math.round(logicalWidth * devicePixelRatio)` 计算。
  - `fit` (`"contain" | "fitWidth" | "fitHeight"`)：排版适应模式。
    - `"contain"`：翻页或单图模式，宽度与高度均受限。
    - `"fitWidth"`：纵向连续滚动（条漫/瀑布流），宽度对齐视口宽度，高度自由延伸（`logicalHeight` 为 `null`）。
    - `"fitHeight"`：横向连续滚动，高度对齐视口高度，宽度自由延伸（`logicalWidth` 为 `null`）。
  - `splitWideImage` (`boolean`)：当前阅读器是否启用了跨页/双页大图拆分模式。开启时跨页大图会被拆分为两个独立视图分别展示。
- **字段单位与 `null` 语义**：
  - 尺寸单位均为设备无关逻辑像素（Flutter dp）。
  - 连续滚动模式中，无边界滚动的维度其对应字段始终为 `null`。
  - **`target: null` 语义**：`target` 为 `null` 表示当前请求**无特定 Reader 排版布局约束**。
  - **原图操作**：阅读器内的“保存原图”、“复制原图”、“分享原图”、导出或无特定排版的通用预加载均会传入 `target: null`。
  - **最终策略由源决定**：应用通过 `target: null` 表达无视口约束或请求原图的意图，但最终的网络请求配置、图床选择与返回 URL 完全由漫画源的 `onImageLoad` 逻辑自行决定（漫画源可选择返回高画质原图链接，也可保留默认 CDN 策略）。
- **旧源兼容**：
  - 仅声明三个参数 `(url, comicId, epId)` 的旧漫画源无需修改，JavaScript 运行时会正常忽略多余实参。
  - 缓存系统对携带 `target` 与未携带 `target` 的请求进行隔离缓存，保障旧缓存与新自适应图片互不污染。
- **应用不规定图床算法**：
  - VeneraNext 仅向漫画源透传客观的视口与排版信息，不规定、不建议、也不绑定任何图床质量梯队、缩放公式或 CDN 查询参数。
  - 漫画源可根据目标站点的 CDN 能力自行决定如何使用该参数（例如请求不同分辨率或格式），或完全忽略该参数。

## 兼容性

VeneraNext 会尽量在实际可行的范围内保持 JavaScript 漫画源扩展接口兼容。这里的兼容只指扩展接口和运行时契约，不代表本仓库提供、推荐或验证任何第三方源。

## 调试建议

- 先用最小功能跑通 `search`、`loadComic` 和章节图片加载。
- 对网络请求、HTML 解析和分页逻辑分别做日志输出。
- 保持 `key` 稳定，避免测试阶段频繁更换导致历史、收藏或缓存混乱。
- 如果扩展依赖用户登录、Cookie 或站点特定配置，应放入扩展设置，不要写死在脚本中。
- 如果图片加载失败，先确认扩展生成的请求参数、headers、referer 和站点访问状态。
