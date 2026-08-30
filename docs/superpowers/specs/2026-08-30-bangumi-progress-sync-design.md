# Bangumi 进度同步设计

日期：2026-08-30
状态：已批准

## 目标

为 VeneraNext 增加 Bangumi 漫画进度同步：用户通过个人 Access Token 连接 Bangumi，在漫画详情页绑定对应 Bangumi 条目，并在读完章节后把由章节标题解析出的“话”或“卷”进度单向上传到 Bangumi。进度面板同时支持手动修改进度和 0–10 评分。

验收结果应满足：

- “设置 → 应用”中的 Bangumi 设置入口位于“数据同步”上方。
- 漫画详情页的“进度”按钮紧跟在“收藏”按钮之后。
- Access Token 与条目绑定关系参与现有 WebDAV 应用数据同步。
- 自动同步只向 Bangumi 上传，不根据远端进度修改 VeneraNext 的本地已读章节。
- 自动同步与首次绑定合并绝不降低远端进度；只有用户明确确认的手动操作可以降低进度。
- Bangumi 搜索明确请求 `nsfw: true`。

## 非目标

- 不实现 OAuth 登录或 Token 自动刷新。
- 不实现 Bangumi 到 VeneraNext 的本地章节反向同步。
- 不实现页码级阅读进度同步。
- 不建立面向 AniList、MAL 等服务的通用 Tracker 框架。
- 不编辑 Bangumi 评论、标签或私密收藏状态。
- 不引入 Android 专用的后台任务依赖。

## 功能域与依赖边界

新增 `lib/features/bangumi/` 功能域：

```text
lib/features/bangumi/
  bangumi.dart
  bangumi_api.dart
  bangumi_models.dart
  bangumi_service.dart
  bangumi_settings.dart
  bangumi_progress.dart
```

各文件职责如下：

- `bangumi.dart`：功能域唯一对外入口，只导出外部需要的类型和组件。
- `bangumi_api.dart`：封装 Token 校验、用户查询、条目搜索、条目读取、收藏读取、收藏创建和字段级更新。
- `bangumi_models.dart`：定义最小请求/响应模型、绑定模型、进度模式和标题解析结果。
- `bangumi_service.dart`：管理设置、绑定、首次合并、自动同步、手动更新、失败队列和重试。
- `bangumi_settings.dart`：Access Token 与自动同步设置面板。
- `bangumi_progress.dart`：条目搜索、绑定和已绑定进度面板。

阅读器不得直接依赖 Bangumi。阅读器对外提供“章节完成”事件注册点，`app_runtime` 负责把事件处理器连接到 `BangumiService`。事件只携带同步所需的稳定信息，例如 `sourceKey`、`comicId`、章节标题和可用的漫画标题。

设置页和漫画详情页只能通过 `features/bangumi/bangumi.dart` 使用 Bangumi 能力，不绕过功能域入口引用内部文件。

## 持久化模型

### 可同步设置

在 `appdata.settings` 增加：

```text
bangumiAccessToken: String
bangumiUsername: String
bangumiAutoSyncEnabled: bool
bangumiBindings: Map<String, Map<String, dynamic>>
```

`bangumiAccessToken` 和 `bangumiUsername` 默认为空，`bangumiAutoSyncEnabled` 默认为 `true`。`bangumiUsername` 是最近一次 `/v0/me` 验证成功后返回的用户名，用于读取收藏和显示离线连接状态。绑定键由 `sourceKey` 和 `comicId` 共同构成，避免不同漫画源的相同 ID 冲突。

每条绑定只保存跨设备仍有意义的数据：

```text
subjectId
subjectTitle
subjectOriginalTitle
coverUrl
progressMode       auto | episode | volume
totalEpisodes
totalVolumes
lastRemoteEpisode
lastRemoteVolume
rating
```

Access Token、已验证用户名和绑定关系不加入 `Appdata._disableSync`，因此会随 `syncdata.json` 上传和下载。此设计明确接受 Token 与现有应用数据采用相同的明文持久化和 WebDAV 传输方式。

### 设备本地状态

自动上传失败后的待处理项保存在 `appdata.implicitData`：

```text
bangumiPendingProgress: {
  bindingKey: {
    ep_status?: {
      field: ep_status,
      value: int,
      attempts: int,
      nextAttemptAt: int
    },
    vol_status?: {
      field: vol_status,
      value: int,
      attempts: int,
      nextAttemptAt: int
    }
  }
}
```

该状态不进入 WebDAV。同一绑定可同时保留按话和按卷两条记录，相同字段只保留最大的待同步值。旧版单条记录会在读取时迁移为上述按字段结构；无效字段会被清理。更改进度模式或解除绑定时清理不再适用的待处理项。

## 章节标题解析

Bangumi 的 `ep_status` 和 `vol_status` 只接受非负整数。自动同步不使用章节在列表中的序号，而从章节标题提取进度。

解析前将全角阿拉伯数字转换为半角；不解析中文数字。解析规则如下：

1. `episode` 模式优先提取与“话”或“話”关联的整数，写入 `ep_status`。
2. `volume` 模式优先提取与“卷”关联的整数，写入 `vol_status`。
3. `auto` 模式下，标题只包含“话/話”关键词时选择 `episode`，只包含“卷”关键词时选择 `volume`。
4. 用户选择的 `episode` 或 `volume` 始终覆盖自动判断。
5. 若目标关键词附近没有数字，但整个标题只有一个独立整数，则使用该整数。
6. 标题同时出现“卷”和“话/話”、目标单位对应多个数字、包含多个无法确定归属的数字、数字属于小数，或完全没有数字时，解析结果为不可同步。
7. 不可同步时不发出网络写请求；进度面板和日志显示原因，用户仍可手动输入整数进度。

例如：

| 标题 | 模式 | 结果 |
|---|---|---|
| `第 12 话` | auto | `ep_status = 12` |
| `第３卷` | auto | `vol_status = 3` |
| `Vol. 8` | volume | `vol_status = 8` |
| `第 12 卷 第 63 话` | episode | `ep_status = 63` |
| `第 12 卷 第 63 话` | volume | `vol_status = 12` |
| `第 12 卷 第 63 话` | auto | 不可同步，需用户选择 |
| `第 12.5 话` | 任意 | 不可自动同步 |
| `番外` | 任意 | 不可自动同步 |

## Bangumi API

API Base URL 为 `https://api.bgm.tv`。所有请求使用可识别的 VeneraNext User-Agent；认证请求通过 `Authorization: Bearer <token>` 发送 Token，并在网络日志中遮罩 Authorization 请求头。

主要端点：

- `GET /v0/me`：验证 Token 并获取用户名。
- `POST /v0/search/subjects?limit=20`：搜索条目。
- `GET /v0/subjects/{subjectId}`：按 Subject ID 精确获取条目。
- `GET /v0/users/{username}/collections/{subjectId}`：读取当前用户收藏。
- `POST /v0/users/-/collections/{subjectId}`：尚未收藏时创建收藏。
- `PATCH /v0/users/-/collections/{subjectId}`：字段级更新进度、评分或必要的收藏状态。

搜索请求必须携带 Token，并明确发送：

```json
{
  "keyword": "搜索词",
  "sort": "match",
  "filter": {
    "type": [1],
    "nsfw": true
  }
}
```

客户端继续过滤明显的非漫画结果，但不把 Bangumi 的默认 NSFW 行为当作内容过滤依据。

响应模型只声明业务需要的字段，允许未知字段和缺失的可选字段。所有 2xx 空响应（包括 204）均按成功处理，不强制 JSON 解码。

`PATCH` 只发送实际变化的字段：

- 自动按话同步只发送 `ep_status`，以及确实需要变化时的 `type`。
- 自动按卷同步只发送 `vol_status`，以及确实需要变化时的 `type`。
- 评分修改只发送 `rate`。
- 手动同时修改进度和评分时只发送这两个实际变化字段。

评分范围为 0–10，其中 0 表示移除评分。

## 设置界面

在 `AppSettings` 的“数据”分区中，于“数据同步”之前增加 Bangumi 入口。入口副标题显示“未连接”或已验证用户名。

Bangumi 设置面板包含：

- 遮罩显示的 Access Token 输入框。
- “申请 Access Token”按钮，通过系统浏览器打开 `https://next.bgm.tv/demo/access-token`。
- “连接/验证”按钮，调用 `/v0/me`；成功后保存 Token 和用户名。
- “断开连接”按钮；清除 Token 和已验证用户状态，但不主动修改 Bangumi 数据。
- “阅读完成后自动同步”开关，默认开启。

`401` 或 `403` 只把连接状态标记为失效并提示检查 Token，不自动删除用户输入。

## 详情页进度面板

漫画详情页的横向操作列表在“收藏”按钮后插入“进度”按钮。

未配置或未验证 Token 时，点击按钮提示用户先进入 Bangumi 设置。已连接但未绑定时显示搜索和绑定流程：

1. 默认填入当前漫画标题，允许修改关键词。
2. 支持输入 Subject ID 精确查找。
3. 展示条目标题、原名、封面、总话数和总卷数。
4. 用户选择条目和 `auto`、`episode` 或 `volume` 模式，默认 `auto`。
5. 读取用户当前收藏；404 仅表示尚未收藏。
6. 完成绑定并执行首次进度合并。

已绑定面板显示：

- Bangumi 条目和 Subject ID。
- 当前进度模式，可随时修改。
- 对应的远端话数或卷数进度。
- 0–10 评分。
- 标题自动解析结果或不可同步原因。
- 待重试状态（如果存在）。
- “保存”“刷新/立即同步”“重新绑定”和“解除绑定”操作。

`auto` 模式暂时无法从当前章节标题确定单位时，面板同时显示远端话数与卷数，不默认选择其中之一。用户手动保存进度前必须明确改选 `episode` 或 `volume`；仅查看、刷新或解除绑定不受影响。

解除绑定只删除 VeneraNext 的本地绑定与待处理项，不修改 Bangumi 收藏。

## 首次绑定与冲突处理

首次绑定前读取远端收藏。如果远端尚未收藏：

- 有可靠的本地完成进度时，以“在读”创建收藏并提交对应进度字段。
- 没有可靠本地完成进度时，以“想读”创建收藏，不猜测进度。

现有 VeneraNext 历史会记录打开过的章节，但不能可靠证明每个历史章节均已读完。因此首次绑定只在当前历史页位于该章节最后一页时，才将当前章节标题的解析结果视为可靠本地完成进度；否则本地候选进度为空。

远端已收藏时，对所选字段执行单调合并：

```text
mergedProgress = max(reliableLocalProgress, remoteProgress)
```

远端更高时保留远端值，但不把对应本地章节标记为已读。本地可靠进度更高时立即上传。评分默认采用远端值，不在绑定时用本地值覆盖。

## 自动同步流程

1. 阅读器确认用户到达章节最后一页。
2. 同一阅读会话、同一章节只发出一次章节完成事件。
3. `BangumiService` 检查 Token、自动同步开关和当前漫画绑定。
4. 服务按绑定模式解析章节标题；不可解析时记录原因并停止。
5. 服务读取远端最新收藏，避免使用缓存状态覆盖网站端修改。
6. 候选进度不大于远端值时跳过写入。
7. 候选进度更高时 PATCH 对应的 `ep_status` 或 `vol_status`。
8. 当前状态不是“读完”时，进度达到已知总话数或总卷数则把 `type` 改为“读完”；否则从“想读”“搁置”或“抛弃”继续阅读时改为“在读”。状态未变化时不发送 `type`。
9. 远端成功后更新绑定缓存并清理待处理项。
10. 失败时不影响阅读器，将最高待同步进度写入设备本地队列。

## 手动更新

用户可在进度面板输入非负整数进度和 0–10 评分。`auto` 模式无法明确解析单位时，必须先选择按话或按卷，不能把手动值写入不确定的字段。手动值高于或等于远端值时正常保存；手动进度低于远端值时必须显示明确的二次确认。只有用户确认后才允许回退。

手动更新失败时保留表单输入并显示错误，不把评分失败加入自动进度队列。

## 重试

自动同步失败不阻塞阅读器。待处理项在以下时机重放：

- 应用启动完成后。
- 同一漫画下一次发生章节完成事件时。
- 用户点击“刷新/立即同步”时。
- 应用保持前台期间的定时重试。

前台定时重试以 5 分钟为初始延迟，采用指数退避，最多执行 4 次。应用退出后不要求系统后台唤醒；下次启动继续处理仍有效的待处理项。

遇到 `401/403` 时保留当前及尚未处理的待处理项，停止本批次并暂停自动章节上传和前台定时重试，避免使用失效 Token 连续请求；暂停期间的新章节进度只合并到本地队列。用户成功重新连接后恢复队列；显式“立即同步”仍会尝试一次并把认证错误反馈给界面，如果该次远端请求成功，也解除认证暂停并继续本批次中已到重试时间的其余项。达到四次自动重试上限的记录不再安排或参与前台定时重试，但应用下次启动或用户显式同步时仍会再尝试一次。同一绑定的按话和按卷记录在每个重试批次中各最多尝试一次。

## 错误处理与日志

- `401/403`：连接失效，提示检查 Token，不自动清除。
- 收藏查询 `404`：按“尚未收藏”处理。
- 其它 4xx：显示 Bangumi 返回的可用错误描述，不自动重试确定性的参数错误。
- 网络错误、408、429 和可恢复的 5xx：进入自动进度重试流程。
- 搜索 schema 变化：忽略未知字段；单条无效结果不影响其它结果。
- 标题解析失败：不发请求，在进度面板和日志中给出原因。
- Authorization 请求头和 Token 不得写入日志、异常消息或测试快照。

## 测试设计

### 标题解析

- 话、話、卷关键词。
- 用户模式覆盖自动模式。
- 全角数字。
- 目标单位附近数字与唯一数字回退。
- 同时出现卷和话。
- 多个歧义数字、小数、负数、无数字和中文数字。

### API

- 搜索请求明确包含 `type: [1]` 和 `nsfw: true`。
- 精确 Subject ID 查询。
- 正确解析最小搜索、条目和收藏响应。
- `ep_status`、`vol_status`、`rate` 和必要的 `type` 字段级 PATCH。
- 2xx 空响应处理。
- 401、403、404、429 和 5xx 分类。
- Authorization 日志遮罩。

### 同步服务

- 首次绑定取可靠本地与远端最大值。
- 自动同步不降低远端进度。
- 用户确认后允许手动降低。
- 评分独立更新。
- 按话和按卷分别比较正确字段和总数。
- 自动状态转换不重复提交未变化的 `type`。
- 同一绑定、同一字段的失败队列只保留最大值。
- 模式切换和解除绑定清理失效队列。

### 持久化与 WebDAV

- Token、已验证用户名、自动同步开关和绑定关系进入 `syncdata.json`。
- `bangumiPendingProgress` 只存在于 `implicitData.json`。
- WebDAV 合并后的绑定可以在另一设备直接使用。

### 界面与阅读器

- Bangumi 设置入口位于“数据同步”之前。
- “进度”按钮位于“收藏”之后。
- 未连接、未绑定和已绑定状态正确。
- Access Token 申请按钮打开指定 URL。
- 手动降低进度显示确认。
- 阅读器只在最后一页为同一章节触发一次完成事件。
- 同步异常不影响阅读器继续翻页或退出。

## 验证命令

实施完成后至少运行：

```powershell
python .github/scripts/check_structure_imports.py
flutter test --no-pub
flutter analyze --no-pub
git diff --check
```

同时先运行 Bangumi 功能域、设置页、详情页和阅读器的针对性测试，以便快速定位失败。
