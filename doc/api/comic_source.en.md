# Comic Source Development Guide

[中文版本](comic_source.zh.md) · [JavaScript API](js.en.md) · [Documentation Index](../README.en.md#developer-api)

This document describes how to create JavaScript comic source extensions for VeneraNext. Function names and invocations follow the runtime in [assets/init.js](../../assets/init.js), source parser in [parser.dart](../../lib/features/comic_source/parser.dart), and models in [models.dart](../../lib/features/comic_source/models.dart). Examples use RFC 2606 reserved fictional domains (`example.invalid`) and do not represent active services.

## Important Disclaimer

VeneraNext only maintains the comic reader application and its extension runtime.

This repository does not provide, host, recommend, endorse, maintain, or verify any third-party comic source, repository list, site content, or copyright status. Do not report issues regarding third-party sources, site availability, missing chapters, or copyright to this repository.

## Development Preparation and Roadmap

1. Implement minimal functionality first: search → details → chapter images.
2. Verify IDs, return data shapes, chapter reading order, and image request network configurations.
3. Add optional features as needed: explore, categories, accounts, network favorites, comments, unidirectional remote progress sync, and settings.
4. Extensions run inside the QuickJS engine. Do not use `import`, `export`, `require`, or globals that rely on Node.js or browser DOM environments.

## 1. Scripts and Minimal Template

An extension is a UTF-8 `.js` file declaring an entry class that extends `ComicSource`. Use class fields and arrow functions to define callbacks, where `this` references the source instance:

| Field | Rule |
|---|---|
| `name` | Non-empty display name |
| `key` | Stable and unique; matches `^[a-zA-Z_][a-zA-Z0-9_]*$`. Do not change after release to avoid breaking history and cache |
| `version` | Extension version string, recommended three-part numbers like `1.0.0` |
| `minAppVersion` | Explicit minimum validated app version, e.g. `2.2.1` |
| `url` | Raw HTTP(S) download URL for script updates; optional |
| `init()` | Optional async initialization; keep concise and avoid loading full site catalogs |

A complete minimal template is available at [minimal_source.js](../examples/minimal_source.js). Core skeleton:

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

The app registers the source automatically upon loading. Do not manipulate `ComicSource.sources` inside the script.

## 2. Data Models and Chapter Order Contracts

### Comic Lists and Details

You can return instances of `new Comic({...})`, `new ComicDetails({...})`, or plain JavaScript objects with matching keys. Use standard primitives (strings, numbers, booleans, arrays, plain objects). Do not return ES `Map` or `Set` across the bridge.

| Data | Key Fields |
|---|---|
| `Comic` item | `id: string`, `title: string`, `cover: string`; optional `subtitle` (accepts `subTitle`), `tags: string[]`, `description`, `language`, `stars` (0–5), `maxPage`, `favoriteId` |
| `ComicDetails` details | Required `title: string`, `cover: string`, `tags: {namespace: string[]}` (use `{}` if empty); `chapters` (object map or `null`); optional `subtitle`, `description`, `updateTime`, `uploadTime`, `url` |
| Details optional fields | `thumbnails: string[]`, `recommend: Comic[]`, `comments: Comment[]`, `isFavorite`, `isLiked`, `likesCount`, `commentCount`, `subId`, `uploader`, `stars` (0–5) |
| Chapter images | `comic.loadEp(comicId, epId)` returns `{images: string[]}`. Do not return a bare array |

In details, `tags` must be a map grouped by namespace (e.g. `{ author: ["Author Name"], genre: ["Action"] }`), whereas in list items `tags` is a flat array of strings.

### Chapter Reading Order and Stable ID Contract

The reader determines previous/next chapter navigation, automatic reading transitions, and waterfall continuity based on the chapter order returned by the source; it does not guess sequence from chapter titles. **The ascending/descending toggle in the details page is purely a display preference and never reverses continuous reading flow**. The source must sort chapters into the expected reading order (usually oldest first) in `comic.loadInfo` before returning.

#### When an API Returns Chapters in Reverse Order

When a site's API returns chapters from newest to oldest, reverse the array in the source before building the chapter map:

```javascript
// Suppose API returns: [{ id: "2", title: "Chapter 2" }, { id: "1", title: "Chapter 1" }]
const chapters = {};
for (const chapter of [...apiChapters].reverse()) {
    chapters[`ep_${chapter.id}`] = chapter.title;
}
// Returns chapters: { ep_1: "Chapter 1", ep_2: "Chapter 2" }
// In loadEp(comicId, epId), retrieve the site ID via epId.slice(3)
```

- **Object Key Numeric Ordering**: JavaScript engines enumerate integer-like keys in ascending numerical order. To preserve custom chapter ordering, use non-integer keys (such as the `ep_` prefix in the template).
- **Existing Source Compatibility**: The `ep_` prefix is for newly authored sources. Existing sources fixing chapter order **must preserve their original chapter ID format**. Never renumber existing chapters with reversed array indices or bulk-rename ID prefixes, as doing so breaks user reading history, downloads, and bookmarks.
- **Grouped Chapters**: For grouped comics, `chapters` uses `{ "Group Name": { "ep_id": "Title" } }`. Verify both group order and chapter order within each group. Only reverse groups that require ordering adjustments.

### Timestamps and Author Namespaces

The `updateTime` and `uploadTime` fields accept:

- Standard date strings: `YYYY-MM-DD` (e.g. `2026-09-01`) or `YYYY-MM-DD HH:mm:ss`.
- Unix timestamps: 10-digit second or 13-digit millisecond timestamps (e.g. `1788220800`).
- ISO 8601 datetime strings: strings with date, time, and timezone indicators (e.g. `2026-09-01T12:00:00Z`).

The app normalizes these formats to a local date string (`YYYY-MM-DD`). If `updateTime` is omitted, the app extracts the first tag from namespaces such as `update`, `last update`, `更新`, or `最后更新`.

Author namespaces include `author`, `authors`, `artist`, `artists`, `作者`, or `画师`.

## 3. Search, Explore, and Categories

### Pagination Contracts

| Callback | Return Value | Notes |
|---|---|---|
| `search.load(keyword, options, page)` | `{comics: Comic[], maxPage: number}` | Page-based search, `page` starts at 1 |
| `search.loadNext(keyword, options, next)` | `{comics: Comic[], next: string|null}` | Cursor-based search, returns `next: null` on last page |
| `explore[i].load(page)` | `{comics: Comic[], maxPage: number}` | Page-based explore list (`multiPageComicList`) |
| `explore[i].loadNext(next)` | `{comics: Comic[], next: string|null}` | Cursor-based explore list |
| `categoryComics.load(category, param, options, page)` | `{comics: Comic[], maxPage: number}` | Category list |
| `categoryComics.ranking.load(option, page)` | `{comics: Comic[], maxPage: number}` | Ranking list |

### Explore and Category Configurations

`explore` is an array supporting three main formats: `multiPageComicList`, `multiPartPage` (returning `[{title, comics: Comic[], viewMore}]`), and `mixed`.

`category` supports structured taxonomy:

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

Tag clicks and link handling:
- `comic.onClickTag(namespace, tag)`: synchronously returns a target object (e.g. `({ page: "search", attributes: { text: tag } })`) or `null`.
- `comic.link = { domains: ["example.invalid"], linkToId: url => ... }`: parses external URLs into comic IDs.

## 4. Image Loading and Header Fallbacks (onImageLoad & onThumbnailLoad)

Sources configure custom network requests (headers, referers, alternative CDNs) via `comic.onImageLoad` and `comic.onThumbnailLoad`.

### Differences and Scope

1. **Chapter Images (`comic.onImageLoad`)**:
   ```javascript
   onImageLoad: (url, comicId, epId, target) => ({
       url: url,
       headers: {
           "User-Agent": "CustomUA/1.0",
           "Referer": "https://example.invalid/"
       },
       onLoadFailed: () => ({ url: retryUrl, headers: { "User-Agent": "CustomUA/1.0" } })
   })
   ```
   - Configures chapter body images; supports async functions.
   - Supports full `ImageLoadingConfig` fields (`url`, `headers`, `method`, `data`, `onResponse`, `modifyImage`, `onLoadFailed`).
   - **4th parameter `target`** (`ComicImageLoadTarget | null`): provides reader layout constraints.
   - `onLoadFailed`: retry hook for chapter images only.

2. **Thumbnails and Covers (`comic.onThumbnailLoad`)**:
   ```javascript
   onThumbnailLoad: (url) => ({
       url: url,
       headers: {
           "User-Agent": "CustomUA/1.0",
           "Referer": "https://example.invalid/"
       }
   })
   ```
   - Used for search results, explore lists, and details covers.
   - **Must be synchronous**.
   - Supports basic network fields (`url`, `headers`, `method`, `data`, `onResponse`); does not support `modifyImage` or `onLoadFailed`.

### Header Parsing and User-Agent Fallback Rules

Across `onImageLoad`, `onThumbnailLoad`, and retry `onLoadFailed`, VeneraNext applies a unified Header contract:

- **Source UA Priority**: Custom User-Agent headers declared by the source take highest priority.
- **Case-Insensitive Headers**: Header lookup is case-insensitive (e.g. `User-Agent`, `user-agent`, `USER-AGENT`). If any variant is present, it is strictly preserved without being overwritten by the default UA.
- **Default UA Fallback**: If the source omits `headers` or provides no User-Agent, the runtime supplies the default browser identifier (`user-agent: webUA`).
- **Type Safety**: Headers are parsed into independent mutable maps; invalid types throw explicit exceptions.

### The `target` Parameter (onImageLoad Only)

- **`target` Fields**:
  - `logicalWidth` (`number | null`): logical pixel width of the display container. When side margins are active, reflects width after margin deduction.
  - `logicalHeight` (`number | null`): logical pixel height of the display container.
  - `devicePixelRatio` (`number`): device pixel ratio (DPR).
  - `fit` (`"contain" | "fitWidth" | "fitHeight"`): layout fit mode.
  - `splitWideImage` (`boolean`): whether dual-page split mode is enabled.
- **`target: null` Semantics**:
  - `target: null` indicates **no specific reader viewport layout constraint**.
  - Reader actions like "Save Original", "Copy Original", "Share Original", export, or general preloading pass `target: null`.
  - The app expresses an intent for original image data; the source's `onImageLoad` decides whether to return higher-resolution URLs or preserve default CDN behavior.
- **Legacy Compatibility**: Older sources with three parameters `(url, comicId, epId)` continue to work without modification.

## 5. Accounts, Favorites, and Interactions

### Accounts

`account` can provide:

| Member | Contract |
|---|---|
| `login(account, password)` | Async login; throws on failure |
| `logout()` | Clears source session data and cookies |
| `loginWithWebview` | `{url, checkStatus(url, title), onLoginSuccess?}` |
| `loginWithCookies` | `{fields: string[], validate(values)}` |
| `registerWebsite` | Optional registration URL |

Persist data using `this.loadData(key)` and `this.saveData(key, value)`.

### Network Favorites

| Member | Contract |
|---|---|
| `multiFolder` | Required boolean, whether multi-folder is supported |
| `addOrDelFavorite(comicId, folderId, isAdding)` | Add or remove favorites; accepts three arguments |
| `loadComics(page, folder)` | Returns `{comics: Comic[], maxPage: number}` |
| `loadNext(next, folder)` | Cursor-based favorites |
| `loadFolders(comicId)` | Returns `{folders: {id: name}, favorited: string[]}` |

Errors containing `Login expired` trigger an automatic re-login attempt.

### Comments, Remote Progress, and Archives

| Callback | Contract |
|---|---|
| `loadComments(comicId, subId, page, replyTo)` | Returns `{comments: Comment[], maxPage?}` |
| `sendComment(comicId, subId, content, replyTo)` | Posts a top-level or reply comment |
| `loadChapterComments(comicId, epId, page, replyTo)` | Chapter comments in reader |
| `sendChapterComment(comicId, epId, content, replyTo)` | Posts a chapter comment or reply |
| `replyComment(comicId, subId, content, parentId, replyId)` | Nested reply interface |
| `updateReadProgress(comicId, epId, page)` | **Unidirectional remote reading progress hook**; debounced on stable reader page turns |
| `likeComic(id, isLike)`, `likeComment(comicId, subId, commentId, isLike)` | Like / unlike |
| `voteComment(id, subId, commentId, isUp, isCancel)` | Returns updated score |
| `starRating(id, rating)` | Submits rating from 0 to 10 |
| `archive.getArchives(comicId)` | Lists archives `[{id, title, description}]` |
| `archive.getDownloadUrl(comicId, archiveId)` | Returns non-empty archive download URL |

`Comment` includes `userName`, `content`, optional `avatar`, `time`, `id`, `replyToId`, `replyToUserName`, `replyCount`, `score`, `isLiked`, `voteStatus`.

## 6. Settings and Localization

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
    }
};

translation = {
    zh_CN: { "Image quality": "图片质量", "Original": "原图", "Small": "流畅" },
    zh_TW: { "Image quality": "圖片品質", "Original": "原圖", "Small": "流暢" },
    en: {}
};
```

Read values via `this.loadSetting("quality")`. `comic.enableTagsTranslate: true` enables the app's built-in tag translations.

## 7. Repositories and Catalogs

Single extensions can be installed via file or URL. Repositories provide a UTF-8 JSON **array**:

```json
[
  {
    "name": "Example Source",
    "key": "example_source",
    "version": "1.0.0",
    "fileName": "scripts/example.js",
    "description": "An example source catalog entry"
  }
]
```

- `name`, `key`, and `version` are required.
- Use `url` or `fileName` for download locations.
- This repository does not provide or recommend third-party source repository URLs.
