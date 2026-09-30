# 漫画源开发说明

[English](comic_source.en.md) · [JavaScript API](js.zh.md) · [返回文档索引](../README.md#开发-api)

本文档说明如何为 VeneraNext 编写兼容 JavaScript 扩展 API 的漫画源扩展。函数名与调用以运行时 [assets/init.js](../../assets/init.js)、源解析器 [parser.dart](../../lib/features/comic_source/parser.dart) 和数据模型 [models.dart](../../lib/features/comic_source/models.dart) 为准。示例地址均使用 RFC 2606 保留的虚构域名（`example.invalid`），不代表实际存在的服务。

## 重要声明

VeneraNext 只维护漫画阅读器本体和扩展运行环境。

本仓库不提供、内置、托管、推荐、维护或验证任何第三方漫画源、源列表、源站内容或版权状态。请不要在本仓库反馈与具体源仓库、源站、作品、章节缺失、图片可用性或版权相关的问题。

## 开发准备与路线

1. 先运行最小结构，打通搜索 → 详情 → 章节图片。
2. 核对 ID、返回类型、章节阅读顺序和图片请求网络配置。
3. 按需加入探索、分类、账号登录、网络收藏、评论互动、单向远端进度同步与设置。
4. 扩展只在 QuickJS 引擎内运行，不要使用 `import`、`export`、`require` 或依赖 Node.js / 完整浏览器 DOM 的全局对象。

## 1. 脚本与最小示例

扩展是一个 UTF-8 `.js` 文件，声明一个继承 `ComicSource` 的入口类。使用类字段与箭头函数定义回调，可在回调中通过 `this` 访问源实例：

| 字段 | 规则 |
|---|---|
| `name` | 非空展示名称 |
| `key` | 稳定且唯一；匹配 `^[a-zA-Z_][a-zA-Z0-9_]*$`，发布后不要随意更改，否则会破坏历史与缓存关联 |
| `version` | 源版本字符串，推荐使用三段数字，如 `1.0.0` |
| `minAppVersion` | 显式填写实际验证过的最低应用版本，如 `2.2.1` |
| `url` | 源脚本的原始 HTTP(S) 下载地址；没有分发地址时可留空，不能填写 GitHub 文件展示网页或源列表地址 |
| `init()` | 可选异步初始化；保持简短，不在这里加载整站内容 |

完整最小示例模板见 [minimal_source.js](../examples/minimal_source.js)。核心骨架如下：

```javascript
class MinimalSource extends ComicSource {
    name = "Minimal Example";
    key = "minimal_example";
    version = "1.0.0";
    minAppVersion = "2.2.1";
    url = "";

    search = {
        optionList: [],
        load: async (keyword, options, page) => ({
            comics: page === 1 ? [
                new Comic({
                    id: "demo",
                    title: "Demo",
                    cover: "https://example.invalid/cover.jpg"
                })
            ] : [],
            maxPage: 1
        })
    };

    comic = {
        loadInfo: async id => new ComicDetails({
            title: "Demo",
            cover: "https://example.invalid/cover.jpg",
            tags: { author: ["Example Author"] },
            chapters: { ep_1: "Chapter 1", ep_2: "Chapter 2" },
            updateTime: "2026-09-01"
        }),
        loadEp: async (comicId, epId) => ({
            images: ["https://example.invalid/" + epId + "/1.jpg"]
        })
    };
}
```

应用在加载脚本时会自动完成注册，无需在扩展内部手动操作 `ComicSource.sources`。

## 2. 数据模型与章节规则

### 漫画列表与详情

可以使用 `new Comic({...})`、`new ComicDetails({...})`，或直接返回同形状的普通 JavaScript 对象。跨语言桥接使用基本数据类型（字符串、数字、布尔值、数组和普通对象映射），不要返回 ES 原生 `Map` 或 `Set`。

| 数据 | 主要字段 |
|---|---|
| `Comic` 列表项 | `id: string`、`title: string`、`cover: string`；可选 `subtitle`（兼容 `subTitle`）、`tags: string[]`、`description`、`language`、`stars`（0～5）、`maxPage`、`favoriteId` |
| `ComicDetails` 详情 | 必填 `title: string`、`cover: string`、`tags: {命名空间: string[]}`（无标签时传 `{}`）；`chapters`（章节映射或 `null`）；可选 `subtitle`、`description`、`updateTime`、`uploadTime`、`url` |
| 详情中的可选能力数据 | `thumbnails: string[]`、`recommend: Comic[]`、`comments: Comment[]`、`isFavorite`、`isLiked`、`likesCount`、`commentCount`、`subId`、`uploader`、`stars`（0～5） |
| 章节图片 | `comic.loadEp(comicId, epId)` 返回 `{images: string[]}`，不能直接返回裸数组 |

详情中的 `tags` 必须为按命名空间分组的对象映射（例如 `{ author: ["作者名"], tag: ["热血"] }`），而列表中的 `tags` 为普通一维数组。

### 章节阅读顺序与稳定 ID 契约

阅读器以源返回的章节顺序决定上一章、下一章、自动阅读跨章和瀑布流衔接，不根据章节标题猜测顺序。**详情页目录的正序/倒序开关仅为界面展示偏好，绝不改变底层连续阅读的章节方向**。源在 `comic.loadInfo` 中必须将章节整理为预期阅读顺序（通常为从旧到新第一章至最新章）后再返回。

#### 站点接口返回倒序目录时

确认目标站点接口返回最新章节在前的数组后，源应在前端先复制并反转数组，再构造章节对象：

```javascript
// 假设站点返回倒序数组：[{ id: "2", title: "第 2 章" }, { id: "1", title: "第 1 章" }]
const chapters = {};
for (const chapter of [...apiChapters].reverse()) {
    chapters[`ep_${chapter.id}`] = chapter.title;
}
// 返回 chapters: { ep_1: "第 1 章", ep_2: "第 2 章" }
// 在 loadEp(comicId, epId) 中通过 epId.slice(3) 还原站点真实 ID
```

- **键名排序注意**：JavaScript 引擎在枚举对象属性时，会优先对整数形式的键按数值大小正向排序。为了保持预期的自定义阅读次序，新源建议采用非纯整数键名（如模板中的 `ep_` 前缀）。
- **已有源兼容保护**：上述 `ep_` 前缀仅供新编写的源参考。已有线上源修复阅读次序时，**必须严格保留原有章节 ID 格式**，不得直接为所有已有章节批量更换前缀或使用数组下标重新编号，否则会导致用户的历史阅读位置、下载目录与收藏章节映射断裂失效。
- **分组目录**：对于支持分组的漫画，`chapters` 格式为 `{ "分组名": { "ep_id": "标题" } }`。需分别核对分组顺序和组内章节顺序，仅反转需要修正的组内章节，不要无条件反转分组。

### 追更时间与作者标签

`updateTime` 和 `uploadTime` 字段支持以下格式（应用会自动解析并归一化为本地时区的 `YYYY-MM-DD`）：

- 标准日期字符串：`YYYY-MM-DD`（如 `2026-09-01`）或 `YYYY-MM-DD HH:mm:ss`。
- Unix 时间戳：10 位秒级时间戳或 13 位毫秒级时间戳整数字符串（如 `1788220800`）。
- ISO 8601 时间格式字符串：包含时间或时区指示符的 ISO 字符串（如 `2026-09-01T12:00:00Z`）。

若详情中未提供 `updateTime`，应用会尝试从 `更新`、`最後更新`、`最后更新`、`update`、`last update` 标签命名空间中提取首个标签作为更新日期。

作者标签命名空间可使用 `author`、`authors`、`artist`、`artists`、`作者` 或 `画师`。

## 3. 搜索、探索与分类

### 分页契约

| 回调 | 返回值 | 说明 |
|---|---|---|
| `search.load(keyword, options, page)` | `{comics: Comic[], maxPage: number}` | 基于页码的分页搜索，`page` 从 1 开始 |
| `search.loadNext(keyword, options, next)` | `{comics: Comic[], next: string或null}` | 基于游标的搜索，无下页时返回 `next: null` |
| `explore[i].load(page)` | `{comics: Comic[], maxPage: number}` | 分页探索列表（`multiPageComicList`） |
| `explore[i].loadNext(next)` | `{comics: Comic[], next: string或null}` | 游标探索列表 |
| `categoryComics.load(category, param, options, page)` | `{comics: Comic[], maxPage: number}` | 分类漫画列表 |
| `categoryComics.ranking.load(option, page)` | `{comics: Comic[], maxPage: number}` | 排行榜列表 |

### 探索页与分类

`explore` 是数组，支持三种常见形态：

- `multiPageComicList`：普通分页列表，使用上述 `load` 或 `loadNext`。
- `multiPartPage`：`load()` 返回多个分块 `[{title, comics: Comic[], viewMore}]`。
- `mixed`：混合信息流。

`category` 支持静态列表与动态加载：

```javascript
category = {
    title: "Example Categories",
    parts: [{
        name: "Genres",
        type: "fixed",
        categories: [{
            label: "Action",
            target: {
                page: "category",
                attributes: { category: "Action", param: "action" }
            }
        }]
    }],
    enableRankingPage: false
};
```

标签点击与外部链接解析：

- `comic.onClickTag(namespace, tag)`：同步返回跳转目标对象（如 `({ page: "search", attributes: { text: tag } })`）或 `null`。
- `comic.link = { domains: ["example.invalid"], linkToId: url => ... }`：用于剪贴板或外链直接匹配漫画 ID。

## 4. 图片加载与网络配置（onImageLoad 与 onThumbnailLoad）

漫画源可以通过 `comic.onImageLoad` 与 `comic.onThumbnailLoad` 为图片请求提供自定义网络配置（如 Headers、Referer 或分流地址）。

### 适用范围与功能差异

1. **章节正文图片（`comic.onImageLoad`）**：
   ```javascript
   onImageLoad: (url, comicId, epId, target) => {
       return {
           url: url,
           headers: {
               "User-Agent": "CustomUA/1.0",
               "Referer": "https://example.invalid/"
           },
           onLoadFailed: () => {
               // 失败时可返回重试配置
               return { url: retryUrl, headers: { "User-Agent": "CustomUA/1.0" } };
           }
       };
   }
   ```
   - 适用于章节正文图片的请求配置，支持异步返回。
   - 支持完整 `ImageLoadingConfig` 字段（`url`、`headers`、`method`、`data`、`onResponse`、`modifyImage`、`onLoadFailed`）。
   - **第四参数 `target`**（类型为 `ComicImageLoadTarget | null`）：提供当前阅读器的排版约束。
   - `onLoadFailed`：仅用于正文图片有限失败重试，返回新配置。

2. **缩略图与封面图片（`comic.onThumbnailLoad`）**：
   ```javascript
   onThumbnailLoad: (url) => {
       return {
           url: url,
           headers: {
               "User-Agent": "CustomUA/1.0",
               "Referer": "https://example.invalid/"
           }
       };
   }
   ```
   - 适用于首页推荐、分类列表、搜索结果等列表缩略图，以及漫画封面。
   - **当前必须同步返回配置**，不能声明为 `async`。
   - 仅支持基础网络请求字段（`url`、`headers`、`method`、`data`、`onResponse`）；不支持 `modifyImage` 与 `onLoadFailed`。

### Header 解析与 User-Agent 回退规则

无论在 `onImageLoad`、`onThumbnailLoad` 还是章节重试 `onLoadFailed` 中，VeneraNext 均遵循统一的 Header 处理契约：

- **Source UA 优先**：漫画源通过 `headers` 显式声明的请求头优先级最高。
- **Header 名大小写不敏感**：根据 HTTP 标准，Header 名称判定大小写不敏感（如 `User-Agent`、`user-agent`、`USER-AGENT`）。只要源返回的 headers 中存在任意大小写形态的 User-Agent，运行时均严格保留源指定的值，绝不会被默认 UA 覆盖，也不会重复追加小写 `user-agent`。
- **缺省 UA fallback**：当漫画源未提供 `headers`、`headers` 为空对象，或者其中不包含任何形式的 `User-Agent` 时，运行时会自动回退补入默认的浏览器标识（`user-agent: webUA`）。
- **类型安全**：解析后的 headers 均为独立的新可修改 Map；若传入了非法类型，运行时会抛出明确异常。

### `target` 排版约束参数说明（仅用于 onImageLoad）

- **`target` 字段**：
  - `logicalWidth` (`number | null`)：目标显示容器的逻辑像素宽度（dp）。当宽度无约束时为 `null`；在开启条漫左右边距时，反映扣除边距后的实际排版宽度。
  - `logicalHeight` (`number | null`)：目标显示容器的逻辑像素高度（dp）。当高度无约束时为 `null`。
  - `devicePixelRatio` (`number`)：当前屏幕设备像素比（DPR）。
  - `fit` (`"contain" | "fitWidth" | "fitHeight"`)：排版适应模式。
  - `splitWideImage` (`boolean`)：当前阅读器是否启用了双页大图拆分模式。
- **`target: null` 语义**：
  - `target` 为 `null` 表示当前请求**无特定 Reader 排版布局约束**。
  - 阅读器内的“保存原图”、“复制原图”、“分享原图”、导出或无特定排版的通用预加载均会传入 `target: null`。
  - 应用通过 `target: null` 表达请求原图的意图，最终的网络请求配置、图床选择与返回 URL 完全由漫画源的 `onImageLoad` 逻辑自行决定（漫画源可选择返回高画质原图链接，也可保留默认 CDN 策略）。
- **旧源兼容**：仅声明三个参数 `(url, comicId, epId)` 的旧漫画源无需修改，JavaScript 运行时会自动忽略多余实参。

## 5. 账号、网络收藏与互动

### 账号

`account` 可包含：

| 成员 | 契约 |
|---|---|
| `login(account, password)` | 异步登录；失败必须抛出错误 |
| `logout()` | 清理源登录数据和 Cookie |
| `loginWithWebview` | `{url, checkStatus(url, title), onLoginSuccess?}` |
| `loginWithCookies` | `{fields: string[], validate(values)}` |
| `registerWebsite` | 可选注册页 URL |

数据通过 `this.loadData(key)`、`this.saveData(key, value)` 持久化。不要将真实账号或 Cookie 硬编码在脚本中。

### 网络收藏

本地收藏和追更由应用维护。仅当站点提供远端账号收藏时才实现 `favorites`：

| 成员 | 契约 |
|---|---|
| `multiFolder` | 必填布尔值，是否支持多个网络收藏夹 |
| `addOrDelFavorite(comicId, folderId, isAdding)` | 添加或删除网络收藏；当前桥接传入这三个参数 |
| `loadComics(page, folder)` | 返回 `{comics: Comic[], maxPage: number}` |
| `loadNext(next, folder)` | 基于游标的收藏加载 |
| `loadFolders(comicId)` | 多收藏夹时返回 `{folders: {id: name}, favorited: string[]}` |

抛出包含 `Login expired` 的错误时，应用会尝试重新调用登录并重试一次操作。

### 评论、单向远端进度与归档

| 回调 | 契约 |
|---|---|
| `loadComments(comicId, subId, page, replyTo)` | 返回 `{comments: Comment[], maxPage?}` |
| `sendComment(comicId, subId, content, replyTo)` | 提交评论或回复 |
| `loadChapterComments(comicId, epId, page, replyTo)` | 阅读器内章节评论加载 |
| `sendChapterComment(comicId, epId, content, replyTo)` | 提交章节评论或回复 |
| `replyComment(comicId, subId, content, parentId, replyId)` | 嵌套评论回复接口 |
| `updateReadProgress(comicId, epId, page)` | **单向远端阅读进度同步 hook**；阅读器在页码稳定变动后防抖调用此函数，返回 `Res<bool>` |
| `likeComic(id, isLike)`、`likeComment(comicId, subId, commentId, isLike)` | 点赞 / 取消点赞 |
| `voteComment(id, subId, commentId, isUp, isCancel)` | 评论投票，返回最新分值数值 |
| `starRating(id, rating)` | 漫画评分，接收 0～10 分值 |
| `archive.getArchives(comicId)` | 获取归档包列表 `[{id, title, description}]` |
| `archive.getDownloadUrl(comicId, archiveId)` | 返回非空归档下载 URL 字符串 |

`Comment` 模型包含 `userName`、`content`，可选 `avatar`、`time`、`id`、`replyToId`、`replyToUserName`、`replyCount`、`score`、`isLiked`、`voteStatus`。

## 6. 设置与翻译

```javascript
settings = {
    quality: {
        title: "Image quality",
        type: "select",
        options: [
            { value: "original", text: "Original" },
            { value: "small", text: "Small" }
        ],
        default: "original"
    },
    compact: { title: "Compact list", type: "switch", default: false }
};

translation = {
    zh_CN: { "Image quality": "图片质量", "Original": "原图", "Small": "流畅" },
    zh_TW: { "Image quality": "圖片品質", "Original": "原圖", "Small": "流暢" },
    en: {}
};
```

读取设置使用 `this.loadSetting("quality")`。`comic.enableTagsTranslate: true` 可启用应用内置的中文标签翻译字典。

## 7. 分发与源仓库格式

单个源可以通过原始 JS 文件或直链安装。仓库列表是一个包含源元数据的 UTF-8 JSON **数组**：

```json
[
  {
    "name": "Example Source",
    "key": "example_source",
    "version": "1.0.0",
    "fileName": "scripts/example.js",
    "description": "An example comic source repository entry"
  }
]
```

- `name`、`key`、`version` 必填，`key` 与脚本内的类字段严格一致。
- 使用 `url` 或 `fileName` 指定下载地址。相对路径以最终成功加载的列表 URL 为基准解析。
- 本仓库不内置、不推荐任何第三方源仓库地址。
