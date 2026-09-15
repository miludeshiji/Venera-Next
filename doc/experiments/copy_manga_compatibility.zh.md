# CopyManga 图片请求兼容性技术预研与审查

本文档记录针对漫画源图片请求 Header 配置机制的技术预研、代码审查结论及任务跟踪。本文档属于实验与技术跟踪记录，不作为正式路线图承诺。

## 声明

Venera-Next 仅维护漫画阅读器本体与扩展运行时。本仓库不提供、内置、托管、推荐、维护或验证任何第三方漫画源、源列表、源站内容、专有协议或版权状态。扩展文档与运行时规范仅描述通用的接口与网络契约。

---

## 1. 目标与定位

本项预研聚焦于 Venera-Next 核心运行时的通用网络契约：

- 为漫画源提供通用的、source-specific 的图片请求 Header 配置与回退能力；
- 确保漫画源能够按需分别控制：
  - 缩略图与封面图片（探索/推荐页、列表、搜索结果、漫画详情页封面）；
  - 章节正文图片（包括加载失败重试分支）。
- 保持职责边界清晰：
  ```text
  Venera-Next = 提供通用的网络配置传递、Header 回退与请求执行机制
  漫画源扩展 = 在外部源仓库中提供具体站点的请求策略与协议参数
  ```
- Venera-Next 核心代码坚决不硬编码任何第三方源的专有字段、具体版本号、专有请求头、签名算法、设备指纹、内部错误码或风控策略。

---

## 2. 现状代码审查结论

此前旧计划中包含“待确认当前 Source API 是否已支持图片 Header”、“若不支持则需扩展 loadEp 或新增通用图片配置”等假设前提。经审查核心代码，确认现有机制已经完备，无需变更扩展接口：

### 2.1 章节图片 Header 支持现状

现有扩展接口中，`comic.onImageLoad(url, comicId, epId, target)` 已经完整支持返回 `ImageLoadingConfig`：

```javascript
onImageLoad: (url, comicId, epId, target) => {
    return {
        url: url,
        headers: {
            // 漫画源自定义请求头
        },
        onLoadFailed: () => {
            // 失败重试时亦可返回包含新 headers 的 ImageLoadingConfig
        }
    }
}
```

在章节图片加载流程中，运行时已支持透传 Source 自定义 headers，并支持在加载失败时通过 `onLoadFailed` 回调返回新的请求配置进行重试。

### 2.2 缩略图与封面 Header 支持现状

现有扩展接口中，`comic.onThumbnailLoad(url)` 已经支持返回 `ImageLoadingConfig`：

```javascript
onThumbnailLoad: (url) => {
    return {
        url: url,
        headers: {
            // 漫画源自定义请求头
        }
    }
}
```

在缩略图加载链路中，封面、列表、探索页与搜索结果中的缩略图均已接入该解析器，漫画源能够通过该钩子独立指定缩略图/封面的请求 Header。

### 2.3 审查结论

1. **无需扩展 `loadEp`**；
2. **无需新增任何 Source API 或运行时配置接口**；
3. 旧计划中关于“缺少配置接口需重新设计”的推论不成立，现有 API 契约完全满足配置需求。

---

## 3. 核心问题定位与修复范围

虽然扩展接口已具备配置能力，但审查发现内部网络层存在 Header 解析与回退（fallback）行为不一致的隐患：

1. **Header 大小写敏感性缺失**：HTTP Header 名在规范中大小写不敏感（如 `user-agent` 与 `User-Agent`）。此前部分解析路径仅以固定小写或固定大写进行判空，当扩展提供了不同大小写形式的 `User-Agent` 时，可能被误判为未提供并重复注入默认浏览器 UA。
2. **Fallback 规则分散**：缩略图（`loadThumbnail`）、章节正文（`loadComicImage`）以及章节重试（`onLoadFailed`）几处分支中的 Header 补全与类型检查逻辑未统一。
3. **不可变映射与类型安全**：若外部传入的 headers 为不可变 Map 或非法类型，缺乏统一的防御性复制与清晰的类型校验报错。

### 修复原则

本轮核心修复仅聚焦于统一 `images.dart` 内部的 Header fallback 逻辑：

- **Source UA 优先**：漫画源返回的 headers 优先级最高；
- **大小写不敏感匹配**：检查 headers 中是否存在任意大小写形式的 `User-Agent`，只要存在即保留源定义，严禁覆盖或追加默认值；
- **缺省 UA 回退**：仅在 headers 缺失、为空或未提供任何形式的 User-Agent 时，才回退补入默认的 `user-agent: webUA`；
- **新可修改 Map**：解析结果确保为独立的新可变 `Map<String, dynamic>`，避免修改原对象或因只读 Map 抛出异常；
- **非法类型防御**：若 headers 传入非 Map 非法类型，抛出明确的 `ArgumentError` 或 `StateError`；
- **全链路一致**：统一规则覆盖缩略图、正文图片以及 `onLoadFailed` 返回的新配置；
- **不得修改全局 `webUA`**：全局 `webUA` 为依赖浏览器标识的通用源所必需，严禁为了特定源修改全局默认值。

---

## 4. 职责边界与外部源仓库职责

### 4.1 外部源仓库职责

任何具体第三方漫画源（如 CopyManga 等）的接入、请求头构造、协议字段组装、URL 变换及防盗链参数均属于外部源仓库（如 `venera-configs` 或第三方源实现）的职责，不属于 Venera-Next 核心仓库。

### 4.2 210 状态码与第三方源验证说明

外部源站返回的 HTTP 210、签名验证错误或反爬策略由源站服务端及第三方源脚本决定。客户端请求 Header 中的 `User-Agent` 一致性是标准的 HTTP 契约修复，但：

- `210` 错误码的消除或触发不是 Venera-Next 核心代码的确定性验收指标；
- Venera-Next 核心仓库不维护、不测试也不保证任何第三方源在任何网络环境下的可用性；
- 严禁在 Venera-Next 中加入针对特定第三方源的硬编码特判或专有逻辑。

---

## 5. 验收标准

- [x] 代码审查确认：现有 `comic.onImageLoad` 与 `comic.onThumbnailLoad` 已支持章节与缩略图 Header，无需新增或修改 Source API 签名；
- [x] 已统一缩略图、章节正文及 `onLoadFailed` 分支的 Header 解析与 fallback 逻辑；
- [x] 漫画源指定的任何大小写形式 `User-Agent` 均完整保留，不被默认 `webUA` 污染；
- [x] 缺失 headers 或未提供 User-Agent 时，正确回退至 `user-agent: webUA`；
- [x] 非法 headers 类型抛出明确清晰的异常；
- [x] 核心代码无任何第三方源特判，不修改全局 `webUA`；
- [ ] 现有其他漫画源行为不受破坏。
