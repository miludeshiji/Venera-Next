# Bangumi Progress Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Access Token based Bangumi binding, title-derived episode/volume progress upload, manual progress and rating editing, and non-blocking retry to VeneraNext.

**Architecture:** Keep all Bangumi API, models, persistence, sync decisions, and UI inside `features/bangumi`, exposed through one barrel file. The reader emits a service-neutral chapter-completed event; `app_runtime` injects the Bangumi handler so the reader never depends on Bangumi. Token and bindings use synchronized app settings, while pending retry state remains in device-local implicit data.

**Tech Stack:** Flutter 3.41.4, Dart 3.8+, Material widgets, Dio through the existing `AppDio`, `appdata.settings`, `appdata.implicitData`, Flutter widget/unit tests.

---

## File map

Create:

- `lib/features/bangumi/bangumi.dart` — public feature entrypoint.
- `lib/features/bangumi/bangumi_models.dart` — DTOs, bindings, progress modes, and title parser.
- `lib/features/bangumi/bangumi_api.dart` — authenticated Bangumi v0 client and error classification.
- `lib/features/bangumi/bangumi_service.dart` — connection, binding, merge, manual update, automatic upload, and retry queue.
- `lib/features/bangumi/bangumi_settings.dart` — Access Token settings panel.
- `lib/features/bangumi/bangumi_progress.dart` — search/binding/progress panel.
- `lib/features/reader/chapter_completion.dart` — service-neutral reader completion event and injectable handler.
- `test/features/bangumi/bangumi_models_test.dart`
- `test/features/bangumi/bangumi_api_test.dart`
- `test/features/bangumi/bangumi_service_test.dart`
- `test/features/bangumi/bangumi_settings_test.dart`
- `test/features/bangumi/bangumi_progress_test.dart`
- `test/features/reader/chapter_completion_test.dart`

Modify:

- `lib/foundation/appdata.dart` — Bangumi setting defaults.
- `test/foundation/appdata_test.dart` — synchronized/private storage assertions.
- `lib/features/settings/app.dart` — Bangumi entry immediately above Data Sync.
- `lib/features/comic_details/actions.dart` — progress panel action.
- `lib/features/comic_details/comic_page.dart` — Progress button after Favorite.
- `test/features/comic_details/comic_details_page_test.dart` — action ordering assertion.
- `lib/features/reader/reader.dart` — export completion contract.
- `lib/features/reader/reader_page.dart` — emit one event at the last page.
- `lib/app_runtime/init.dart` — connect and initialize Bangumi service.
- `assets/translation.json` — Simplified/Traditional Chinese strings.
- `.github/scripts/check_structure_imports.py` — enforce Bangumi and reader entrypoints.
- `doc/architecture/project_structure.zh.md`
- `doc/architecture/project_structure.en.md`
- `CHANGELOG.md`

## Task 1: Settings defaults, binding model, and title parser

**Files:**

- Create: `lib/features/bangumi/bangumi.dart`
- Create: `lib/features/bangumi/bangumi_models.dart`
- Create: `test/features/bangumi/bangumi_models_test.dart`
- Modify: `lib/foundation/appdata.dart:335-410`

- [ ] **Step 1: Write failing parser and binding tests**

Create `test/features/bangumi/bangumi_models_test.dart` with table-driven coverage:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/bangumi/bangumi.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  group('BangumiTitleProgressParser', () {
    final cases = <({String title, BangumiProgressMode mode, BangumiProgress? expected})>[
      (title: '第 12 话', mode: BangumiProgressMode.auto, expected: const BangumiProgress(BangumiProgressField.episode, 12)),
      (title: '第３卷', mode: BangumiProgressMode.auto, expected: const BangumiProgress(BangumiProgressField.volume, 3)),
      (title: 'Vol. 8', mode: BangumiProgressMode.volume, expected: const BangumiProgress(BangumiProgressField.volume, 8)),
      (title: '第 12 卷 第 63 话', mode: BangumiProgressMode.episode, expected: const BangumiProgress(BangumiProgressField.episode, 63)),
      (title: '第 12 卷 第 63 话', mode: BangumiProgressMode.volume, expected: const BangumiProgress(BangumiProgressField.volume, 12)),
      (title: '第 12 卷 第 63 话', mode: BangumiProgressMode.auto, expected: null),
      (title: '第 12.5 话', mode: BangumiProgressMode.episode, expected: null),
      (title: '-3 话', mode: BangumiProgressMode.episode, expected: null),
      (title: '番外', mode: BangumiProgressMode.episode, expected: null),
      (title: '第十二话', mode: BangumiProgressMode.episode, expected: null),
    ];

    for (final item in cases) {
      test('${item.mode.name}: ${item.title}', () {
        expect(
          BangumiTitleProgressParser.parse(item.title, item.mode).progress,
          item.expected,
        );
      });
    }
  });

  test('binding JSON round-trips stable cross-device fields', () {
    const binding = BangumiBinding(
      sourceKey: 'source',
      comicId: 'comic/1',
      subjectId: 42,
      subjectTitle: '标题',
      subjectOriginalTitle: 'Title',
      coverUrl: 'https://example.com/cover.jpg',
      progressMode: BangumiProgressMode.volume,
      totalEpisodes: 100,
      totalVolumes: 12,
      lastRemoteEpisode: 30,
      lastRemoteVolume: 4,
      rating: 8,
    );

    expect(BangumiBinding.fromJson(binding.toJson()), binding);
    expect(bangumiBindingKey('source', 'comic/1'), 'source@comic%2F1');
  });

  test('Bangumi settings have safe defaults', () {
    expect(appdata.settings['bangumiAccessToken'], '');
    expect(appdata.settings['bangumiUsername'], '');
    expect(appdata.settings['bangumiAutoSyncEnabled'], isTrue);
    expect(appdata.settings['bangumiBindings'], isA<Map>());
  });
}
```

- [ ] **Step 2: Run the focused test and confirm the red state**

```powershell
flutter test --no-pub test/features/bangumi/bangumi_models_test.dart
```

Expected: compilation fails because the Bangumi feature types do not exist.

- [ ] **Step 3: Add defaults and the complete model/parser surface**

Add to `Settings._data` in `lib/foundation/appdata.dart`:

```dart
'bangumiAccessToken': '',
'bangumiUsername': '',
'bangumiAutoSyncEnabled': true,
'bangumiBindings': <String, Map<String, dynamic>>{},
```

Implement these public types in `bangumi_models.dart`:

```dart
enum BangumiProgressMode { auto, episode, volume }

enum BangumiProgressField { episode, volume }

enum BangumiTitleParseFailure {
  unknownUnit,
  ambiguous,
  decimal,
  negative,
  noNumber,
}

class BangumiProgress {
  const BangumiProgress(this.field, this.value);
  final BangumiProgressField field;
  final int value;

  String get apiField => switch (field) {
    BangumiProgressField.episode => 'ep_status',
    BangumiProgressField.volume => 'vol_status',
  };

  @override
  bool operator ==(Object other) =>
      other is BangumiProgress && other.field == field && other.value == value;

  @override
  int get hashCode => Object.hash(field, value);
}

class BangumiTitleParseResult {
  const BangumiTitleParseResult.success(this.progress) : failure = null;
  const BangumiTitleParseResult.failure(this.failure) : progress = null;
  final BangumiProgress? progress;
  final BangumiTitleParseFailure? failure;
}
```

Implement `BangumiTitleProgressParser.parse` with this exact decision order:

```dart
static BangumiTitleParseResult parse(String source, BangumiProgressMode mode) {
  final title = _normalizeDigits(source);
  if (RegExp(r'\d+\.\d+').hasMatch(title)) {
    return const BangumiTitleParseResult.failure(BangumiTitleParseFailure.decimal);
  }
  if (RegExp(r'-\s*\d+').hasMatch(title)) {
    return const BangumiTitleParseResult.failure(BangumiTitleParseFailure.negative);
  }

  final hasEpisode = RegExp(r'[话話]').hasMatch(title);
  final hasVolume = title.contains('卷');
  final field = switch (mode) {
    BangumiProgressMode.episode => BangumiProgressField.episode,
    BangumiProgressMode.volume => BangumiProgressField.volume,
    BangumiProgressMode.auto when hasEpisode && !hasVolume => BangumiProgressField.episode,
    BangumiProgressMode.auto when hasVolume && !hasEpisode => BangumiProgressField.volume,
    BangumiProgressMode.auto => null,
  };
  if (field == null) {
    return BangumiTitleParseResult.failure(
      hasEpisode || hasVolume
          ? BangumiTitleParseFailure.ambiguous
          : BangumiTitleParseFailure.unknownUnit,
    );
  }

  final unit = field == BangumiProgressField.episode ? r'[话話]' : '卷';
  final associated = <int>{};
  for (final expression in [RegExp('(\\d+)\\s*$unit'), RegExp('$unit\\s*(\\d+)')]) {
    for (final match in expression.allMatches(title)) {
      associated.add(int.parse(match.group(1)!));
    }
  }
  if (associated.length == 1) {
    return BangumiTitleParseResult.success(BangumiProgress(field, associated.single));
  }
  if (associated.length > 1) {
    return const BangumiTitleParseResult.failure(BangumiTitleParseFailure.ambiguous);
  }

  final allNumbers = RegExp(r'\d+').allMatches(title).map((m) => int.parse(m.group(0)!)).toSet();
  if (allNumbers.length == 1) {
    return BangumiTitleParseResult.success(BangumiProgress(field, allNumbers.single));
  }
  return BangumiTitleParseResult.failure(
    allNumbers.isEmpty ? BangumiTitleParseFailure.noNumber : BangumiTitleParseFailure.ambiguous,
  );
}
```

Normalize `０`–`９` by subtracting the full-width zero code unit. Add immutable `BangumiUser`, `BangumiSubject`, `BangumiCollection`, and `BangumiBinding` classes with explicit `fromJson`/`toJson`; use defaults for absent `rate`, `ep_status`, `vol_status`, `eps`, and `volumes`, and ignore unknown fields.

Use these stable public fields and constructors so later tasks do not invent alternate model shapes:

```dart
const BangumiUser(this.username, this.nickname);

const BangumiSubject({
  required this.id,
  required this.title,
  required this.originalTitle,
  required this.coverUrl,
  required this.totalEpisodes,
  required this.totalVolumes,
  this.platform,
});

const BangumiCollection({
  required this.type,
  required this.rate,
  required this.epStatus,
  required this.volStatus,
});

const BangumiBinding({
  required this.sourceKey,
  required this.comicId,
  required this.subjectId,
  required this.subjectTitle,
  required this.subjectOriginalTitle,
  required this.coverUrl,
  required this.progressMode,
  required this.totalEpisodes,
  required this.totalVolumes,
  required this.lastRemoteEpisode,
  required this.lastRemoteVolume,
  required this.rating,
});
```

Map non-empty `name_cn` to `title` and otherwise use `name`; always retain `name` as `originalTitle`. Map `images.common` to `coverUrl` and default it to an empty string. Add a `copyWith` to `BangumiBinding` for the service updates in Tasks 3–4. Encode binding keys with:

```dart
String bangumiBindingKey(String sourceKey, String comicId) =>
    '${Uri.encodeComponent(sourceKey)}@${Uri.encodeComponent(comicId)}';
```

Export `bangumi_models.dart` from `bangumi.dart`.

- [ ] **Step 4: Run the focused test and confirm green**

```powershell
flutter test --no-pub test/features/bangumi/bangumi_models_test.dart
```

Expected: all parser, serialization, key, and default tests pass.

- [ ] **Step 5: Commit the model slice**

```powershell
git add lib/features/bangumi/bangumi.dart lib/features/bangumi/bangumi_models.dart lib/foundation/appdata.dart test/features/bangumi/bangumi_models_test.dart
git commit -m "feat(bangumi): 增加进度模型与标题解析"
```

## Task 2: Bangumi API client

**Files:**

- Create: `lib/features/bangumi/bangumi_api.dart`
- Create: `test/features/bangumi/bangumi_api_test.dart`
- Modify: `lib/features/bangumi/bangumi.dart`

- [ ] **Step 1: Write failing API contract tests**

Create a queue-backed `HttpClientAdapter` in `bangumi_api_test.dart` that records `RequestOptions` and returns supplied status/body pairs. Its `fetch` method follows the existing `_TrackingAdapter` signature in `test/network/app_dio_test.dart`, removes the first queued `(statusCode, body)` record, and returns `ResponseBody.fromString(jsonEncode(body), statusCode, headers: {Headers.contentTypeHeader: ['application/json']})`. Add `QueueAdapter.json(statusCode, body)` as a one-response constructor and this helper:

```dart
Dio dioWith(HttpClientAdapter adapter) {
  final dio = Dio();
  dio.httpClientAdapter = adapter;
  return dio;
}
```

Then assert:

```dart
test('search sends book and explicit NSFW filters with bearer auth', () async {
  final adapter = QueueAdapter.json(200, {
    'data': [
      {
        'id': 42,
        'name': 'Book',
        'name_cn': '漫画',
        'platform': '漫画',
        'eps': 10,
        'volumes': 2,
        'images': {'common': 'https://example.com/42.jpg'},
      },
    ],
  });
  final api = BangumiApi(token: 'secret', dio: dioWith(adapter));

  final result = await api.searchSubjects('漫画');

  expect(result.single.id, 42);
  expect(adapter.requests.single.data, {
    'keyword': '漫画',
    'sort': 'match',
    'filter': {
      'type': [1],
      'nsfw': true,
    },
  });
  expect(adapter.requests.single.headers['Authorization'], 'Bearer secret');
  expect(adapter.requests.single.extra['maskHeadersInLog'], contains('Authorization'));
});
```

Also add tests for `/v0/me`, exact Subject ID lookup, collection 404 returning `null`, PATCH sending only the supplied map, and a 204 empty response succeeding.

- [ ] **Step 2: Run the API test and confirm it fails**

```powershell
flutter test --no-pub test/features/bangumi/bangumi_api_test.dart
```

Expected: compilation fails because `BangumiApi` and `BangumiGateway` do not exist.

- [ ] **Step 3: Implement the gateway and HTTP client**

Define this testable interface and error in `bangumi_api.dart`:

```dart
abstract interface class BangumiGateway {
  Future<BangumiUser> currentUser();
  Future<List<BangumiSubject>> searchSubjects(String keyword);
  Future<BangumiSubject> getSubject(int subjectId);
  Future<BangumiCollection?> getCollection(String username, int subjectId);
  Future<void> createCollection(int subjectId, Map<String, dynamic> fields);
  Future<void> patchCollection(int subjectId, Map<String, dynamic> fields);
}

class BangumiApiException implements Exception {
  const BangumiApiException(this.statusCode, this.message);
  final int? statusCode;
  final String message;

  bool get isRetryable =>
      statusCode == null || statusCode == 408 || statusCode == 429 ||
      (statusCode != null && statusCode! >= 500);

  @override
  String toString() => message;
}
```

Construct `BangumiApi` with an injectable `Dio`, defaulting to `AppDio(BaseOptions(baseUrl: 'https://api.bgm.tv'))`. Every request uses Bearer auth, `Accept: application/json`, `validateStatus: (_) => true`, and:

```dart
extra: const {
  'maskHeadersInLog': ['Authorization'],
},
```

Decode only non-empty successful bodies. Treat every 2xx status as success, return `null` only for collection GET 404, and throw `BangumiApiException` for all other failures. Extract `title`, `description`, or `details` from JSON error bodies before falling back to `HTTP <status>`.

Filter decoded search results with:

```dart
subjects.where((subject) =>
  subject.platform == null || subject.platform == '漫画'
).toList();
```

Export `bangumi_api.dart` from `bangumi.dart`.

- [ ] **Step 4: Run API tests**

```powershell
flutter test --no-pub test/features/bangumi/bangumi_api_test.dart
```

Expected: endpoint, NSFW filter, empty response, 404, and masking assertions pass.

- [ ] **Step 5: Commit the API slice**

```powershell
git add lib/features/bangumi/bangumi.dart lib/features/bangumi/bangumi_api.dart test/features/bangumi/bangumi_api_test.dart
git commit -m "feat(bangumi): 封装认证与收藏接口"
```

## Task 3: Connection, bindings, monotonic merge, and manual edits

**Files:**

- Create: `lib/features/bangumi/bangumi_service.dart`
- Create: `test/features/bangumi/bangumi_service_test.dart`
- Modify: `lib/features/bangumi/bangumi.dart`

- [ ] **Step 1: Write failing service tests with a fake gateway**

Create `FakeBangumiGateway implements BangumiGateway` with recorded create/patch maps. Reset the Bangumi settings after each test. Cover:

```dart
test('connect validates before saving token and username', () async {
  final gateway = FakeBangumiGateway(
    user: const BangumiUser('alice', 'Alice'),
  );
  final service = BangumiService.forTesting(
    gatewayFactory: (_) => gateway,
  );
  await service.connect('token');
  expect(appdata.settings['bangumiAccessToken'], 'token');
  expect(appdata.settings['bangumiUsername'], 'alice');
});

test('binding uploads only a higher reliable local episode', () async {
  final gateway = FakeBangumiGateway(
    collection: const BangumiCollection(type: 3, rate: 7, epStatus: 10, volStatus: 2),
  );
  final service = BangumiService.forTesting(
    gatewayFactory: (_) => gateway,
  );
  await service.bind(
    sourceKey: 'source',
    comicId: 'comic',
    subject: const BangumiSubject(
      id: 42,
      title: '漫画',
      originalTitle: 'Book',
      coverUrl: '',
      totalEpisodes: 100,
      totalVolumes: 12,
      platform: '漫画',
    ),
    mode: BangumiProgressMode.episode,
    reliableLocalProgress: const BangumiProgress(BangumiProgressField.episode, 12),
  );
  expect(gateway.patches.single, {'ep_status': 12});
  expect(service.bindingFor('source', 'comic')!.lastRemoteEpisode, 12);
});

test('manual decrease requires explicit approval', () async {
  final gateway = FakeBangumiGateway(
    collection: const BangumiCollection(type: 3, rate: 7, epStatus: 20, volStatus: 0),
  );
  appdata.settings['bangumiAccessToken'] = 'token';
  appdata.settings['bangumiUsername'] = 'alice';
  const binding = BangumiBinding(
    sourceKey: 'source',
    comicId: 'comic',
    subjectId: 42,
    subjectTitle: '漫画',
    subjectOriginalTitle: 'Book',
    coverUrl: '',
    progressMode: BangumiProgressMode.episode,
    totalEpisodes: 100,
    totalVolumes: 12,
    lastRemoteEpisode: 20,
    lastRemoteVolume: 0,
    rating: 7,
  );
  appdata.settings['bangumiBindings'] = {
    bangumiBindingKey('source', 'comic'): binding.toJson(),
  };
  final service = BangumiService.forTesting(
    gatewayFactory: (_) => gateway,
  );
  await expectLater(
    service.updateManual(
      sourceKey: 'source',
      comicId: 'comic',
      field: BangumiProgressField.episode,
      progress: 10,
      rating: 8,
      allowDecrease: false,
    ),
    throwsA(isA<BangumiProgressDecreaseRequired>()),
  );
  await service.updateManual(
    sourceKey: 'source',
    comicId: 'comic',
    field: BangumiProgressField.episode,
    progress: 10,
    rating: 8,
    allowDecrease: true,
  );
  expect(gateway.patches.single, {'ep_status': 10, 'rate': 8});
});
```

Add cases proving a higher remote value is never lowered, an uncollected subject with local progress creates `{'type': 3, '<field>': value}`, no reliable progress creates `{'type': 1}`, and rating-only changes send only `{'rate': value}`.

- [ ] **Step 2: Run service tests and confirm red**

```powershell
flutter test --no-pub test/features/bangumi/bangumi_service_test.dart
```

Expected: compilation fails because `BangumiService` is missing.

- [ ] **Step 3: Implement the service core**

Use a production singleton plus an injectable testing constructor:

```dart
typedef BangumiGatewayFactory = BangumiGateway Function(String token);
typedef BangumiSettingsSaver = Future<void> Function();

class BangumiService {
  BangumiService._({required BangumiGatewayFactory gatewayFactory, required BangumiSettingsSaver saveSettings})
    : _gatewayFactory = gatewayFactory,
      _saveSettings = saveSettings;

  static BangumiService? _instance;
  factory BangumiService() => _instance ??= BangumiService._(
    gatewayFactory: (token) => BangumiApi(token: token),
    saveSettings: appdata.saveData,
  );

  @visibleForTesting
  factory BangumiService.forTesting({
    required BangumiGatewayFactory gatewayFactory,
    BangumiSettingsSaver? saveSettings,
  }) => BangumiService._(
    gatewayFactory: gatewayFactory,
    saveSettings: saveSettings ?? () async {},
  );
}
```

Implement this public surface:

```dart
bool get isConnected;
Future<BangumiUser> connect(String token);
Future<void> disconnect();
Future<List<BangumiSubject>> searchSubjects(String keyword);
Future<BangumiSubject> getSubject(int subjectId);
BangumiBinding? bindingFor(String sourceKey, String comicId);
Future<BangumiBinding> bind({
  required String sourceKey,
  required String comicId,
  required BangumiSubject subject,
  required BangumiProgressMode mode,
  BangumiProgress? reliableLocalProgress,
});
Future<BangumiCollection?> refresh(String sourceKey, String comicId);
Future<void> updateMode(String sourceKey, String comicId, BangumiProgressMode mode);
Future<void> updateManual({
  required String sourceKey,
  required String comicId,
  required BangumiProgressField field,
  required int progress,
  required int rating,
  required bool allowDecrease,
});
Future<void> unbind(String sourceKey, String comicId);
```

Copy the `bangumiBindings` outer map before assignment so setting listeners fire. Refresh before every progress write. Build PATCH maps field-by-field and omit unchanged keys. Reject negative progress and ratings outside 0–10. Throw `BangumiProgressDecreaseRequired` before PATCH when `progress < remoteProgress && !allowDecrease`.

When creating a missing collection, send only `type` and a reliable positive progress field. Preserve remote rating on bind. Persist a binding only after its remote operation succeeds. Export `bangumi_service.dart` from `bangumi.dart`.

- [ ] **Step 4: Run service tests**

```powershell
flutter test --no-pub test/features/bangumi/bangumi_service_test.dart
```

Expected: connection, binding, non-regression, create, field-diff, and decrease-confirmation tests pass.

- [ ] **Step 5: Commit the service core**

```powershell
git add lib/features/bangumi/bangumi.dart lib/features/bangumi/bangumi_service.dart test/features/bangumi/bangumi_service_test.dart
git commit -m "feat(bangumi): 实现绑定与单向进度合并"
```

## Task 4: Automatic upload and device-local retry queue

**Files:**

- Modify: `lib/features/bangumi/bangumi_service.dart`
- Modify: `test/features/bangumi/bangumi_service_test.dart`

- [ ] **Step 1: Add failing automatic sync and retry tests**

Call:

```dart
await service.onChapterCompleted(
  sourceKey: 'source',
  comicId: 'comic',
  chapterTitle: '第 12 话',
);
```

Assert no call when auto sync is disabled/unbound; correct episode/volume field; ambiguous auto title skipped; lower/equal candidates skipped; known total reached sets `type: 2`; wish/on-hold/dropped advances set `type: 3`; unchanged type omitted; retryable failures store only the maximum per binding/field; successful replay clears pending state; mode change/unbind clears incompatible pending state.

- [ ] **Step 2: Run tests and confirm the new assertions fail**

```powershell
flutter test --no-pub test/features/bangumi/bangumi_service_test.dart
```

Expected: missing automatic sync, retry, and initialization methods.

- [ ] **Step 3: Implement automatic sync and retry**

Add:

```dart
Future<void> initialize();
Future<void> onChapterCompleted({
  required String sourceKey,
  required String comicId,
  required String chapterTitle,
});
Future<void> retryPending({String? bindingKey});
void dispose();
```

Build status changes only when needed:

```dart
final patch = <String, dynamic>{progress.apiField: progress.value};
final total = progress.field == BangumiProgressField.episode
    ? binding.totalEpisodes
    : binding.totalVolumes;
if (collection.type != 2 && total > 0 && progress.value >= total) {
  patch['type'] = 2;
} else if ({1, 4, 5}.contains(collection.type)) {
  patch['type'] = 3;
}
```

Queue only retryable `BangumiApiException`. Store `field`, maximum `value`, `attempts`, and `nextAttemptAt` under `appdata.implicitData['bangumiPendingProgress']`, then call `writeImplicitData()`. `initialize` replays ready items and starts one owned Timer. Use 5, 10, 20, and 40 minute delays; after four failed attempts retain the item for the next explicit sync/startup but stop foreground rescheduling. Cancel the Timer in `dispose`.

- [ ] **Step 4: Run service tests**

```powershell
flutter test --no-pub test/features/bangumi/bangumi_service_test.dart
```

Expected: automatic fields/status, queue compression, replay, and cleanup tests pass.

- [ ] **Step 5: Commit automatic sync and retry**

```powershell
git add lib/features/bangumi/bangumi_service.dart test/features/bangumi/bangumi_service_test.dart
git commit -m "feat(bangumi): 增加自动上传与失败重试"
```

## Task 5: Bangumi settings UI and synchronized data proof

**Files:**

- Create: `lib/features/bangumi/bangumi_settings.dart`
- Create: `test/features/bangumi/bangumi_settings_test.dart`
- Modify: `lib/features/bangumi/bangumi.dart`
- Modify: `lib/features/settings/app.dart:30-190`
- Modify: `test/foundation/appdata_test.dart`
- Modify: `assets/translation.json`

- [ ] **Step 1: Write failing settings and persistence tests**

Use an injectable launcher:

```dart
testWidgets('settings masks token and opens the application page', (tester) async {
  appdata.settings['bangumiAccessToken'] = 'token';
  appdata.settings['bangumiUsername'] = 'alice';
  final service = BangumiService.forTesting(
    gatewayFactory: (_) => _SettingsGateway(),
  );
  Uri? launched;
  await tester.pumpWidget(MaterialApp(
    home: BangumiSettingsPage(
      service: service,
      launchTokenPage: (uri) async {
        launched = uri;
        return true;
      },
    ),
  ));
  final tokenField = tester.widget<TextField>(find.byKey(const Key('bangumi-token-field')));
  expect(tokenField.obscureText, isTrue);
  await tester.tap(find.byKey(const Key('bangumi-apply-token')));
  expect(launched, Uri.parse('https://next.bgm.tv/demo/access-token'));
});
```

Define `_SettingsGateway implements BangumiGateway` in the same test file: `currentUser` returns `const BangumiUser('alice', 'Alice')`; its other five methods throw `UnsupportedError` because the settings panel never calls them. Reset all four Bangumi setting keys in `tearDown` so this test cannot leak connection state.

Add a connect test verifying username display. Add an ordering test reading `lib/features/settings/app.dart` and asserting `Key('bangumi-settings-entry')` occurs before `Key('data-sync-entry')`. Extend `appdata_test.dart` to save/decode `syncdata.json`, asserting token, username, auto switch, and bindings are present, while pending progress appears only in `implicitData.json`.

- [ ] **Step 2: Run settings and appdata tests and confirm red**

```powershell
flutter test --no-pub test/features/bangumi/bangumi_settings_test.dart test/foundation/appdata_test.dart
```

Expected: missing widget/keys and persistence assertions fail.

- [ ] **Step 3: Implement the settings panel and entry**

`BangumiSettingsPage` uses `PopUpWidgetScaffold`, a masked token field, application/connect/disconnect buttons, and auto-sync switch. Constructor:

```dart
const BangumiSettingsPage({
  super.key,
  this.service,
  this.launchTokenPage = _launchTokenPage,
});

final BangumiService? service;
final Future<bool> Function(Uri uri) launchTokenPage;
```

The default launcher uses `LaunchMode.externalApplication`. Connect trims and validates before saving; errors preserve input and show a message. Disconnect clears token/username only. The switch updates `bangumiAutoSyncEnabled` and saves without API access.

Insert before Data Sync:

```dart
CallbackSetting(
  key: const Key('bangumi-settings-entry'),
  title: 'Bangumi',
  subtitle: (appdata.settings['bangumiUsername'] as String).isEmpty
      ? 'Not connected'.tl
      : appdata.settings['bangumiUsername'] as String,
  callback: () async {
    await showPopUpWidget(context, const BangumiSettingsPage());
    if (mounted) setState(() {});
  },
  actionTitle: 'Set'.tl,
).toSliver(),
```

Give Data Sync `key: const Key('data-sync-entry')`. Export settings UI. Add Simplified/Traditional translations for connection states/actions, auto sync, validation errors, and the warning that Token participates in WebDAV sync.

- [ ] **Step 4: Run focused settings tests**

```powershell
flutter test --no-pub test/features/bangumi/bangumi_settings_test.dart test/foundation/appdata_test.dart
```

Expected: widget, ordering, and persistence tests pass.

- [ ] **Step 5: Commit settings UI**

```powershell
git add lib/features/bangumi/bangumi.dart lib/features/bangumi/bangumi_settings.dart lib/features/settings/app.dart test/features/bangumi/bangumi_settings_test.dart test/foundation/appdata_test.dart assets/translation.json
git commit -m "feat(bangumi): 增加令牌连接设置"
```

## Task 6: Search, bind, progress, and rating panel

**Files:**

- Create: `lib/features/bangumi/bangumi_progress.dart`
- Create: `test/features/bangumi/bangumi_progress_test.dart`
- Modify: `lib/features/bangumi/bangumi.dart`
- Modify: `assets/translation.json`

- [ ] **Step 1: Write failing panel tests**

Cover disconnected, unbound, and bound states. Required first test:

```dart
testWidgets('unconnected panel explains that Bangumi must be connected', (tester) async {
  appdata.settings['bangumiAccessToken'] = '';
  appdata.settings['bangumiUsername'] = '';
  final service = BangumiService.forTesting(
    gatewayFactory: (_) => throw StateError('disconnected'),
  );
  await tester.pumpWidget(MaterialApp(
    home: BangumiProgressPanel(
      service: service,
      sourceKey: 'source',
      comicId: 'comic',
      comicTitle: 'Title',
      chapters: const ComicChapters({'1': '第 1 话'}),
      history: null,
    ),
  ));
  expect(find.text('Connect Bangumi in Settings first'), findsOneWidget);
});
```

Also assert default title query; numeric input uses exact subject lookup; keyword uses search; selected mode reaches `bind`; bound form shows progress/rating; ambiguous auto mode blocks save; manual decrease opens confirmation and retries with `allowDecrease: true`; unbind does not mutate fake remote data.

- [ ] **Step 2: Run panel tests and confirm red**

```powershell
flutter test --no-pub test/features/bangumi/bangumi_progress_test.dart
```

Expected: missing `BangumiProgressPanel`.

- [ ] **Step 3: Implement the three-state panel**

Constructor:

```dart
const BangumiProgressPanel({
  super.key,
  this.service,
  required this.sourceKey,
  required this.comicId,
  required this.comicTitle,
  required this.chapters,
  required this.history,
});
```

Use `PopUpWidgetScaffold` and choose disconnected/search/bound body from `service.isConnected` and `service.bindingFor`. Numeric-only query calls `getSubject`; other query calls `searchSubjects`. Render title, original name, cover, and total counts. Default mode is auto.

Reliable local progress requires `history.page >= history.maxPage!`. Flat titles use `history.ep - 1`; grouped titles use `history.group! - 1` plus the group-local `history.ep - 1`. Parse with selected mode before `bind`.

Use integer-only formatters. When auto cannot resolve a field, show both remote fields and require episode/volume selection before saving. Catch `BangumiProgressDecreaseRequired` and confirm with:

```dart
showConfirmDialog(
  context: context,
  title: 'Lower Bangumi progress?'.tl,
  content: 'The new progress is lower than Bangumi. Continue?'.tl,
  onConfirm: () => _save(allowDecrease: true),
);
```

Immediate sync calls `retryPending(bindingKey: binding.key)` then refresh. Rebind returns to search state. Unbind only calls local service removal. Export the panel and add all Simplified/Traditional labels, modes, parser failures, confirmation, pending, refresh/rebind/unbind translations.

- [ ] **Step 4: Run panel tests**

```powershell
flutter test --no-pub test/features/bangumi/bangumi_progress_test.dart
```

Expected: connection/search/bind/ambiguous/manual decrease/rating/unbind tests pass.

- [ ] **Step 5: Commit the progress panel**

```powershell
git add lib/features/bangumi/bangumi.dart lib/features/bangumi/bangumi_progress.dart test/features/bangumi/bangumi_progress_test.dart assets/translation.json
git commit -m "feat(bangumi): 增加条目绑定与进度面板"
```

## Task 7: Detail-page Progress action

**Files:**

- Modify: `lib/features/comic_details/actions.dart:1-115`
- Modify: `lib/features/comic_details/comic_page.dart:390-440`
- Modify: `test/features/comic_details/comic_details_page_test.dart`

- [ ] **Step 1: Add a failing action-order test**

```dart
test('Bangumi progress action follows favorite action', () {
  final source = File('lib/features/comic_details/comic_page.dart').readAsStringSync();
  final favorite = source.indexOf("Key('comic-detail-favorite')");
  final progress = source.indexOf("Key('comic-detail-progress')");
  expect(favorite, greaterThanOrEqualTo(0));
  expect(progress, greaterThan(favorite));
});
```

Import `dart:io` in the test.

- [ ] **Step 2: Run the detail test and confirm red**

```powershell
flutter test --no-pub test/features/comic_details/comic_details_page_test.dart
```

Expected: key indices are `-1`.

- [ ] **Step 3: Add the action and panel opener**

Import `features/bangumi/bangumi.dart` in `actions.dart` and add:

```dart
void openBangumiProgress() {
  showSideBar(
    App.rootContext,
    BangumiProgressPanel(
      sourceKey: comic.sourceKey,
      comicId: comic.id,
      comicTitle: comic.title,
      chapters: comic.chapters,
      history: history,
    ),
  );
}
```

Give Favorite `key: const Key('comic-detail-favorite')`, then insert:

```dart
ComicDetailActionButton(
  key: const Key('comic-detail-progress'),
  icon: const Icon(Icons.update),
  text: 'Progress'.tl,
  onPressed: openBangumiProgress,
  iconColor: context.useTextColor(Colors.orange),
),
```

- [ ] **Step 4: Run detail tests**

```powershell
flutter test --no-pub test/features/comic_details/comic_details_page_test.dart
```

Expected: existing tests and ordering test pass.

- [ ] **Step 5: Commit detail integration**

```powershell
git add lib/features/comic_details/actions.dart lib/features/comic_details/comic_page.dart test/features/comic_details/comic_details_page_test.dart
git commit -m "feat(bangumi): 在详情页增加进度入口"
```

## Task 8: Reader completion event and runtime wiring

**Files:**

- Create: `lib/features/reader/chapter_completion.dart`
- Create: `test/features/reader/chapter_completion_test.dart`
- Modify: `lib/features/reader/reader.dart`
- Modify: `lib/features/reader/reader_page.dart:145-390`
- Modify: `lib/app_runtime/init.dart:25-90`

- [ ] **Step 1: Write failing completion-notifier tests**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/reader.dart';

void main() {
  test('notifier emits only once per completed chapter', () async {
    final events = <ReaderChapterCompletedEvent>[];
    final notifier = ReaderChapterCompletionNotifier(events.add);
    const event = ReaderChapterCompletedEvent(
      sourceKey: 'source',
      comicId: 'comic',
      chapterKey: 'chapter-1',
      chapterTitle: '第 1 话',
    );
    await notifier.notify(isAtEnd: false, event: event);
    await notifier.notify(isAtEnd: true, event: event);
    await notifier.notify(isAtEnd: true, event: event);
    expect(events, [event]);
  });
}
```

Add another chapter key and assert independent emission.

- [ ] **Step 2: Run notifier test and confirm red**

```powershell
flutter test --no-pub test/features/reader/chapter_completion_test.dart
```

Expected: completion types are missing.

- [ ] **Step 3: Implement service-neutral completion notification**

Define event, configurable handler, and notifier:

```dart
@immutable
class ReaderChapterCompletedEvent {
  const ReaderChapterCompletedEvent({
    required this.sourceKey,
    required this.comicId,
    required this.chapterKey,
    required this.chapterTitle,
  });

  final String sourceKey;
  final String comicId;
  final String chapterKey;
  final String chapterTitle;

  @override
  bool operator ==(Object other) =>
      other is ReaderChapterCompletedEvent &&
      other.sourceKey == sourceKey &&
      other.comicId == comicId &&
      other.chapterKey == chapterKey &&
      other.chapterTitle == chapterTitle;

  @override
  int get hashCode => Object.hash(sourceKey, comicId, chapterKey, chapterTitle);
}

typedef ReaderChapterCompletedHandler = FutureOr<void> Function(ReaderChapterCompletedEvent event);
ReaderChapterCompletedHandler? _chapterCompletedHandler;

void configureReaderChapterCompletedHandler(ReaderChapterCompletedHandler? handler) {
  _chapterCompletedHandler = handler;
}

class ReaderChapterCompletionNotifier {
  ReaderChapterCompletionNotifier([ReaderChapterCompletedHandler? handler])
    : _handler = handler ?? _chapterCompletedHandler;
  final ReaderChapterCompletedHandler? _handler;
  final Set<String> _notified = <String>{};

  Future<void> notify({required bool isAtEnd, required ReaderChapterCompletedEvent event}) async {
    if (!isAtEnd || _handler == null || !_notified.add(event.chapterKey)) return;
    await Future.sync(() => _handler(event));
  }
}
```

Export it from `reader.dart`. Create one notifier in `_ReaderState`. After `updateHistory()` in `onPageChanged`, resolve current `eid` and title, then invoke it with `isAtEnd: page >= maxPage`; catch/log the unawaited future so sync cannot affect navigation.

In `app_runtime/init.dart`, register:

```dart
configureReaderChapterCompletedHandler((event) => BangumiService().onChapterCompleted(
  sourceKey: event.sourceKey,
  comicId: event.comicId,
  chapterTitle: event.chapterTitle,
));
await BangumiService().initialize();
```

Register after comic type source resolution; initialize after app data/network runtime initialization.

- [ ] **Step 4: Run reader and service tests**

```powershell
flutter test --no-pub test/features/reader/chapter_completion_test.dart test/features/bangumi/bangumi_service_test.dart test/features/reader
```

Expected: one-shot completion and existing reader tests pass.

- [ ] **Step 5: Commit runtime wiring**

```powershell
git add lib/features/reader/chapter_completion.dart lib/features/reader/reader.dart lib/features/reader/reader_page.dart lib/app_runtime/init.dart test/features/reader/chapter_completion_test.dart
git commit -m "feat(bangumi): 连接阅读完成事件"
```

## Task 9: Structure contracts, documentation, changelog, and full verification

**Files:**

- Modify: `.github/scripts/check_structure_imports.py`
- Modify: `doc/architecture/project_structure.zh.md`
- Modify: `doc/architecture/project_structure.en.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Extend the structure-entrypoint contract**

Add each Bangumi implementation file to `FEATURE_ENTRYPOINT_TARGETS`, targeting `features/bangumi/bangumi.dart`. Add `features/reader/chapter_completion.dart` targeting `features/reader/reader.dart`.

```powershell
python .github/scripts/check_structure_imports.py
```

Expected: `Structure import check passed.`

- [ ] **Step 2: Update architecture docs and changelog**

In both architecture documents, list Bangumi as responsible for Access Token connection, subject binding, episode/volume progress upload, rating editing, and local retry state; add `bangumi.dart` to stable entrypoint examples.

Under `CHANGELOG.md` → `v1.14.4` → `新增`, add:

```markdown
- 增加 Bangumi 阅读进度同步：支持 Access Token 跨设备同步、漫画条目绑定、按章节标题同步话/卷进度、手动评分以及失败重试。
```

- [ ] **Step 3: Run targeted tests together**

```powershell
flutter test --no-pub test/features/bangumi test/features/comic_details/comic_details_page_test.dart test/features/reader/chapter_completion_test.dart test/foundation/appdata_test.dart
```

Expected: all targeted tests pass.

- [ ] **Step 4: Run required repository verification**

```powershell
python .github/scripts/check_structure_imports.py
flutter analyze --no-pub
flutter test --no-pub
git diff --check
```

Expected: structure check passes, analyzer reports no issues, full tests pass, and diff check prints no errors.

- [ ] **Step 5: Inspect scope before the final commit**

```powershell
git status --short
git diff --stat HEAD
git diff --check
```

Expected: only planned Bangumi, reader hook, integration, test, translation, architecture, and changelog files changed. `AGENTS.md` and the two reference documents remain untracked and unstaged.

- [ ] **Step 6: Commit integration metadata**

```powershell
git add .github/scripts/check_structure_imports.py doc/architecture/project_structure.zh.md doc/architecture/project_structure.en.md CHANGELOG.md
git commit -m "docs: 记录 Bangumi 同步架构"
```

- [ ] **Step 7: Verify the committed tree one final time**

```powershell
git status --short
git log -9 --oneline
```

Expected: only pre-existing untracked `AGENTS.md`, `docs/Bangumi_API_开发手册_2026-08-30.md`, and `docs/Mihon_Bangumi_进度同步实现参考_2026-08-30.md` remain; latest commits correspond to Tasks 1–9.
