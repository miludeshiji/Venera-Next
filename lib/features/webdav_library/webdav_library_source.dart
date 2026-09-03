import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'package:flutter/foundation.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/comic_storage/comic_storage.dart';
import 'package:venera_next/features/webdav_library/webdav_library_cache.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/extensions.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/throttled_task_runner.dart';
import 'package:venera_next/network/webdav.dart';
import 'package:webdav_client/webdav_client.dart' hide File;

typedef WebDavLibraryMetadataScraper =
    Future<ComicMetaData?> Function(String directoryTitle);

typedef WebDavLibraryMetadataWriteGuard =
    FutureOr<bool> Function(String libraryId, String comicId, int? subjectId);

enum WebDavLibraryFailureKind {
  preconditionFailed,
  authentication,
  transient,
  unsupported,
  other,
}

class WebDavLibraryException implements Exception {
  const WebDavLibraryException(
    this.message, {
    required this.kind,
    this.statusCode,
    this.path,
    this.cause,
  });

  final String message;
  final WebDavLibraryFailureKind kind;
  final int? statusCode;
  final String? path;
  final Object? cause;

  bool get isRetryable =>
      kind == WebDavLibraryFailureKind.preconditionFailed ||
      kind == WebDavLibraryFailureKind.transient;

  @override
  String toString() => message;
}

class WebDavPreconditionFailedException extends WebDavLibraryException {
  const WebDavPreconditionFailedException(String path)
    : super(
        'WebDAV resource changed before it could be written: $path',
        kind: WebDavLibraryFailureKind.preconditionFailed,
        statusCode: 412,
        path: path,
      );
}

class WebDavAuthenticationException extends WebDavLibraryException {
  const WebDavAuthenticationException(
    String path, {
    required super.statusCode,
    super.cause,
  }) : super(
         'WebDAV authentication or permission failed for $path',
         kind: WebDavLibraryFailureKind.authentication,
         path: path,
       );
}

class WebDavTransientException extends WebDavLibraryException {
  const WebDavTransientException(String path, {super.statusCode, super.cause})
    : super(
        'Temporary WebDAV failure for $path',
        kind: WebDavLibraryFailureKind.transient,
        path: path,
      );
}

class WebDavUnsupportedException extends WebDavLibraryException {
  const WebDavUnsupportedException(
    String path, {
    super.statusCode,
    String? message,
    super.cause,
  }) : super(
         message ?? 'The WebDAV server does not support safe writes for $path',
         kind: WebDavLibraryFailureKind.unsupported,
         path: path,
       );
}

class WebDavTextFile {
  const WebDavTextFile({required this.content, this.eTag, this.modifiedAt});

  final String content;
  final String? eTag;
  final int? modifiedAt;
}

class WebDavWriteResult {
  const WebDavWriteResult({this.eTag, this.modifiedAt});

  final String? eTag;
  final int? modifiedAt;
}

class WebDavLibraryConfig {
  WebDavLibraryConfig({
    required String url,
    required String user,
    required String pass,
    required String remotePath,
  }) : endpoint = WebDavEndpoint(url: url, user: user, password: pass),
       remotePath = normalizeWebDavDirectoryPath(
         remotePath,
         fallback: '/venera_comics/',
       );

  final WebDavEndpoint endpoint;
  final String remotePath;

  String get url => endpoint.url;

  String get user => endpoint.user;

  String get pass => endpoint.password;

  bool get isValid => endpoint.isValid;

  Map<String, String> get authHeaders => endpoint.authHeaders;

  String get cacheKey => jsonEncode([url, user, remotePath]);

  String get libraryId {
    final identity = jsonEncode([url, user.trim(), remotePath]);
    return 'webdav:${sha256.convert(utf8.encode(identity))}';
  }

  String get connectionKey => jsonEncode([url, user, pass, remotePath]);

  static WebDavLibraryConfig fromSettings() {
    final config = appdata.settings['webdavComicLibrary'];
    final path = appdata.settings['webdavComicLibraryPath'];
    try {
      if (config is List &&
          config.length == 3 &&
          config.every((value) => value is String)) {
        final values = config.cast<String>();
        return WebDavLibraryConfig(
          url: values[0],
          user: values[1],
          pass: values[2],
          remotePath: path is String ? path : '/venera_comics/',
        );
      }
      return WebDavLibraryConfig(
        url: '',
        user: '',
        pass: '',
        remotePath: path is String ? path : '/venera_comics/',
      );
    } on FormatException {
      return WebDavLibraryConfig(
        url: '',
        user: '',
        pass: '',
        remotePath: '/venera_comics/',
      );
    }
  }

  static Future<void> saveToSettings(WebDavLibraryConfig config) async {
    final previous = fromSettings();
    if (!config.isValid && config.user.isEmpty && config.pass.isEmpty) {
      appdata.settings['webdavComicLibrary'] = [];
    } else {
      appdata.settings['webdavComicLibrary'] = [
        config.url,
        config.user,
        config.pass,
      ];
    }
    appdata.settings['webdavComicLibraryPath'] = config.remotePath;
    await appdata.saveData(false);
    if (previous.connectionKey != config.connectionKey) {
      WebDavLibrarySource.onConfigurationChanged(previous);
    }
  }

  String childDirectoryPath(String name) {
    return childDirectoryPathFrom(remotePath, name);
  }

  String childFilePath(String parent, String name) {
    return joinWebDavFilePath(parent, name);
  }

  String childDirectoryPathFrom(String parent, String name) {
    return joinWebDavDirectoryPath(parent, name);
  }

  String fileUrl(String remoteFilePath) => endpoint.fileUrl(remoteFilePath);
}

class WebDavLibraryEntry {
  const WebDavLibraryEntry({
    required this.name,
    required this.isDirectory,
    this.eTag,
    this.modifiedAt,
  });

  final String name;
  final bool isDirectory;
  final String? eTag;
  final int? modifiedAt;
}

abstract class WebDavLibraryOps {
  Future<void> test(WebDavLibraryConfig config);

  Future<List<WebDavLibraryEntry>> readDir(
    WebDavLibraryConfig config,
    String remotePath,
  );

  Future<WebDavTextFile> readText(
    WebDavLibraryConfig config,
    String remotePath,
  );

  Future<WebDavWriteResult> writeText(
    WebDavLibraryConfig config,
    String remotePath,
    String content, {
    bool createOnly = false,
    String? ifMatch,
    int? ifUnmodifiedSince,
  });
}

class _WebDavLibraryOps implements WebDavLibraryOps {
  final _clients = <String, Client>{};

  Client _client(WebDavLibraryConfig config) {
    return _clients.putIfAbsent(
      config.connectionKey,
      config.endpoint.createClient,
    );
  }

  @override
  Future<void> test(WebDavLibraryConfig config) async {
    await _client(config).readDir(config.remotePath);
  }

  @override
  Future<List<WebDavLibraryEntry>> readDir(
    WebDavLibraryConfig config,
    String remotePath,
  ) async {
    final entries = await _client(config).readDir(remotePath);
    return entries
        .where((entry) => entry.name != null)
        .map(
          (entry) => WebDavLibraryEntry(
            name: entry.name!,
            isDirectory: entry.isDir == true,
            eTag: entry.eTag?.isEmpty == true ? null : entry.eTag,
            modifiedAt: entry.mTime?.millisecondsSinceEpoch,
          ),
        )
        .toList();
  }

  @override
  Future<WebDavTextFile> readText(
    WebDavLibraryConfig config,
    String remotePath,
  ) async {
    final client = _client(config);
    try {
      final response = await client.c.req<List<int>>(
        client,
        'GET',
        remotePath,
        optionsHandler: (options) => options.responseType = ResponseType.bytes,
      );
      _throwForStatus(response.statusCode, remotePath);
      return WebDavTextFile(
        content: utf8.decode(response.data ?? const [], allowMalformed: false),
        eTag: _header(response.headers.map, 'etag'),
        modifiedAt: _modifiedAt(response.headers.map),
      );
    } on DioException catch (error) {
      throw _classifyDioError(error, remotePath);
    }
  }

  @override
  Future<WebDavWriteResult> writeText(
    WebDavLibraryConfig config,
    String remotePath,
    String content, {
    bool createOnly = false,
    String? ifMatch,
    int? ifUnmodifiedSince,
  }) async {
    if (createOnly && (ifMatch != null || ifUnmodifiedSince != null)) {
      throw ArgumentError(
        'createOnly cannot be combined with update preconditions',
      );
    }
    final client = _client(config);
    try {
      final response = await client.c.req<Object?>(
        client,
        'PUT',
        remotePath,
        data: Uint8List.fromList(utf8.encode(content)),
        optionsHandler: (options) {
          options.headers ??= {};
          options.headers!['content-type'] = 'application/json; charset=utf-8';
          if (createOnly) {
            options.headers!['if-none-match'] = '*';
          } else if (ifMatch != null) {
            options.headers!['if-match'] = ifMatch;
          } else if (ifUnmodifiedSince != null) {
            options.headers!['if-unmodified-since'] = HttpDate.format(
              DateTime.fromMillisecondsSinceEpoch(
                ifUnmodifiedSince,
                isUtc: true,
              ),
            );
          }
        },
      );
      _throwForStatus(response.statusCode, remotePath);
      return WebDavWriteResult(
        eTag: _header(response.headers.map, 'etag'),
        modifiedAt: _modifiedAt(response.headers.map),
      );
    } on DioException catch (error) {
      throw _classifyDioError(error, remotePath);
    }
  }

  static String? _header(Map<String, List<String>> headers, String name) {
    final values = headers[name];
    if (values == null || values.isEmpty || values.first.trim().isEmpty) {
      return null;
    }
    return values.first;
  }

  static int? _modifiedAt(Map<String, List<String>> headers) {
    final value = _header(headers, 'last-modified');
    if (value == null) return null;
    try {
      return HttpDate.parse(value).millisecondsSinceEpoch;
    } catch (_) {
      return null;
    }
  }

  static void _throwForStatus(int? statusCode, String path) {
    if (statusCode != null && statusCode >= 200 && statusCode < 300) return;
    if (statusCode == 412) throw WebDavPreconditionFailedException(path);
    if (statusCode == 401 || statusCode == 403) {
      throw WebDavAuthenticationException(path, statusCode: statusCode!);
    }
    if (statusCode == 405 || statusCode == 501) {
      throw WebDavUnsupportedException(path, statusCode: statusCode);
    }
    if (statusCode == null ||
        statusCode == 408 ||
        statusCode == 425 ||
        statusCode == 429 ||
        statusCode >= 500) {
      throw WebDavTransientException(path, statusCode: statusCode);
    }
    throw WebDavLibraryException(
      'WebDAV request failed with HTTP $statusCode for $path',
      kind: WebDavLibraryFailureKind.other,
      statusCode: statusCode,
      path: path,
    );
  }

  static WebDavLibraryException _classifyDioError(
    DioException error,
    String path,
  ) {
    final status = error.response?.statusCode;
    if (status == 412) return WebDavPreconditionFailedException(path);
    if (status == 401 || status == 403) {
      return WebDavAuthenticationException(
        path,
        statusCode: status!,
        cause: error,
      );
    }
    if (status == 405 || status == 501) {
      return WebDavUnsupportedException(path, statusCode: status, cause: error);
    }
    if (status == null ||
        status == 408 ||
        status == 425 ||
        status == 429 ||
        status >= 500) {
      return WebDavTransientException(path, statusCode: status, cause: error);
    }
    return WebDavLibraryException(
      'WebDAV request failed with HTTP $status for $path',
      kind: WebDavLibraryFailureKind.other,
      statusCode: status,
      path: path,
      cause: error,
    );
  }
}

enum WebDavMetadataPendingFailure {
  none,
  authentication,
  transient,
  unsupported,
  conflict,
  rejected,
  invalidMetadata,
  other,
}

class WebDavMetadataPendingStatus {
  const WebDavMetadataPendingStatus({
    required this.libraryId,
    required this.comicId,
    required this.subjectId,
    required this.attempts,
    required this.lastAttemptAt,
    required this.nextRetryAt,
    required this.failure,
    required this.errorMessage,
  });

  final String libraryId;
  final String comicId;
  final int? subjectId;
  final int attempts;
  final int? lastAttemptAt;
  final int? nextRetryAt;
  final WebDavMetadataPendingFailure failure;
  final String? errorMessage;
}

class WebDavMetadataWriteRejectedException implements Exception {
  const WebDavMetadataWriteRejectedException();

  @override
  String toString() => 'The WebDAV metadata write is no longer current';
}

class WebDavLibrarySyncStatus {
  const WebDavLibrarySyncStatus({
    required this.isSyncing,
    required this.lastSuccessfulSync,
    this.processed = 0,
    this.total = 0,
    this.failed = 0,
    this.errorMessage,
  });

  final bool isSyncing;
  final int lastSuccessfulSync;
  final int processed;
  final int total;
  final int failed;
  final String? errorMessage;

  String get formattedLastSuccessfulSync {
    if (lastSuccessfulSync <= 0) return '';
    final time = DateTime.fromMillisecondsSinceEpoch(lastSuccessfulSync);
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${twoDigits(time.month)}-${twoDigits(time.day)} '
        '${twoDigits(time.hour)}:${twoDigits(time.minute)}';
  }
}

class _WebDavLibrarySyncRun {
  const _WebDavLibrarySyncRun({
    required this.configurationIdentity,
    required this.generation,
    required this.indexReady,
    required this.complete,
  });

  final String configurationIdentity;
  final int generation;
  final Future<Res<bool>> indexReady;
  final Future<Res<bool>> complete;
}

class _WebDavSynchronizationObsoleteException implements Exception {
  const _WebDavSynchronizationObsoleteException();
}

class WebDavLibrarySource {
  const WebDavLibrarySource._();

  static const sourceKey = 'webdav_library';
  static const explorePageTitle = 'WebDAV Library';
  static const pageSize = 20;
  static const rootChapterId = '__root__';
  static const rootChapterTitle = 'Images';
  static const _metadataFileName = 'metadata.json';
  static const _metadataChapterPrefix = '__cbz_range_';
  static const _maxDiscoveryDepth = 8;
  static const _maxDiscoveryDirectories = 2000;
  @visibleForTesting
  static int? discoveryDirectoryLimitOverride;
  @visibleForTesting
  static int Function() metadataNowProvider = () =>
      DateTime.now().millisecondsSinceEpoch;
  static const _maxMetadataMergeAttempts = 3;
  static const _maxMetadataRetryAttempts = 4;
  static const _defaultScraperVersion = '1';
  static const _metadataPendingKey = 'webdavMetadataPending';
  static const _autoSyncCheckInterval = Duration(minutes: 15);

  static final _snapshotCache = <String, _WebDavComicSnapshot>{};
  static final _snapshotInFlight = <String, Future<_WebDavComicSnapshot>>{};
  static final contentVersion = ValueNotifier<int>(0);
  static final syncStatus = ValueNotifier<WebDavLibrarySyncStatus>(
    const WebDavLibrarySyncStatus(isSyncing: false, lastSuccessfulSync: 0),
  );
  static final metadataPendingVersion = ValueNotifier<int>(0);
  static final _cache = WebDavLibraryCache.instance;
  static WebDavLibraryOps _ops = _WebDavLibraryOps();
  static _WebDavLibrarySyncRun? _syncRun;
  static int _syncGeneration = 0;
  static Timer? _autoSyncTimer;
  static Timer? _metadataRetryTimer;
  static final _metadataWriteTails = <String, Future<void>>{};
  static WebDavLibraryMetadataScraper? _metadataScraper;
  static bool Function()? _metadataScrapingEnabled;
  static String _metadataScraperVersion = _defaultScraperVersion;
  static WebDavLibraryMetadataWriteGuard? _metadataWriteGuard;
  static int _metadataPayloadSequence = 0;

  static String get currentLibraryId =>
      WebDavLibraryConfig.fromSettings().libraryId;

  static List<WebDavMetadataPendingStatus> get metadataPendingStatuses =>
      _pendingMetadataWrites()
          .map((pending) => pending.status)
          .toList(growable: false);

  static void configureMetadataScraper(
    WebDavLibraryMetadataScraper? scraper, {
    bool Function()? isEnabled,
    String scraperVersion = _defaultScraperVersion,
  }) {
    _metadataScraper = scraper;
    _metadataScrapingEnabled = isEnabled;
    _metadataScraperVersion = scraperVersion.trim().isEmpty
        ? _defaultScraperVersion
        : scraperVersion.trim();
  }

  static void configureMetadataWriteGuard(
    WebDavLibraryMetadataWriteGuard? guard,
  ) {
    _metadataWriteGuard = guard;
  }

  static bool get _canScrapeMetadata =>
      _metadataScraper != null &&
      (_metadataScrapingEnabled == null || _metadataScrapingEnabled!());

  static WebDavLibraryOps get ops => _ops;

  static set ops(WebDavLibraryOps value) {
    _ops = value;
    _clearMemoryCaches();
  }

  static void resetOps() {
    _ops = _WebDavLibraryOps();
    _clearMemoryCaches();
  }

  static void _clearMemoryCaches() {
    _snapshotCache.clear();
    _snapshotInFlight.clear();
  }

  static void _invalidateSynchronization() {
    _syncGeneration++;
    _syncRun = null;
  }

  static void _resetSyncStatusForCurrentConfiguration() {
    final config = WebDavLibraryConfig.fromSettings();
    syncStatus.value = WebDavLibrarySyncStatus(
      isSyncing: false,
      lastSuccessfulSync: config.isValid
          ? _cache.lastSuccessfulSync(config.cacheKey)
          : 0,
    );
  }

  static void onConfigurationChanged(WebDavLibraryConfig previous) {
    _invalidateSynchronization();
    _metadataRetryTimer?.cancel();
    _metadataRetryTimer = null;
    _clearMemoryCaches();
    _ops = _WebDavLibraryOps();
    _resetSyncStatusForCurrentConfiguration();
    final current = WebDavLibraryConfig.fromSettings();
    if (previous.isValid && previous.cacheKey != current.cacheKey) {
      _cache.clear(previous.cacheKey);
    }
    contentVersion.value++;
    initializeMetadataRetry();
  }

  static void onSettingsImported() {
    _invalidateSynchronization();
    _metadataRetryTimer?.cancel();
    _metadataRetryTimer = null;
    _clearMemoryCaches();
    _ops = _WebDavLibraryOps();
    _resetSyncStatusForCurrentConfiguration();
    contentVersion.value++;
    initializeMetadataRetry();
  }

  static void initializeAutoSync() {
    updateSyncStatusFromCache();
    _autoSyncTimer ??= Timer.periodic(
      _autoSyncCheckInterval,
      (_) => checkForAutomaticSync(),
    );
    checkForAutomaticSync();
  }

  static void updateSyncStatusFromCache() {
    if (syncStatus.value.isSyncing) return;
    final config = WebDavLibraryConfig.fromSettings();
    if (!config.isValid) return;
    final lastSync = _cache.lastSuccessfulSync(config.cacheKey);
    if (syncStatus.value.lastSuccessfulSync == lastSync) return;
    syncStatus.value = WebDavLibrarySyncStatus(
      isSyncing: false,
      lastSuccessfulSync: lastSync,
    );
  }

  static void checkForAutomaticSync() {
    updateSyncStatusFromCache();
    final config = WebDavLibraryConfig.fromSettings();
    if (!config.isValid ||
        appdata.settings['webdavComicLibraryAutoSync'] != true) {
      return;
    }
    final interval =
        (appdata.settings['webdavComicLibrarySyncIntervalMinutes'] as num?)
            ?.round() ??
        360;
    final lastSync = _cache.lastSuccessfulSync(config.cacheKey);
    final elapsed = DateTime.now().millisecondsSinceEpoch - lastSync;
    if (lastSync == 0 ||
        elapsed >= Duration(minutes: interval).inMilliseconds) {
      unawaited(synchronize());
    }
  }

  @visibleForTesting
  static void resetCacheForTesting() {
    _syncRun = null;
    _syncGeneration++;
    _autoSyncTimer?.cancel();
    _autoSyncTimer = null;
    _metadataRetryTimer?.cancel();
    _metadataRetryTimer = null;
    _metadataWriteTails.clear();
    _metadataPayloadSequence = 0;
    _metadataWriteGuard = null;
    discoveryDirectoryLimitOverride = null;
    metadataNowProvider = () => DateTime.now().millisecondsSinceEpoch;
    _clearMemoryCaches();
    _cache.resetForTesting();
    appdata.implicitData.remove(_metadataPendingKey);
    metadataPendingVersion.value++;
    syncStatus.value = const WebDavLibrarySyncStatus(
      isSyncing: false,
      lastSuccessfulSync: 0,
    );
    contentVersion.value++;
  }

  static ComicSource create() {
    return ComicSource(
      'WebDAV Library',
      sourceKey,
      null,
      null,
      null,
      null,
      [
        ExplorePageData(
          explorePageTitle,
          ExplorePageType.multiPageComicList,
          loadComics,
          null,
          null,
          null,
          changeListenable: contentVersion,
          onRefresh: () async {
            await synchronize(force: true);
          },
        ),
      ],
      null,
      null,
      loadComicInfo,
      null,
      loadComicPages,
      getImageLoadingConfig,
      getThumbnailLoadingConfig,
      '',
      '',
      '',
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      false,
      false,
      null,
      null,
    );
  }

  static Future<Res<bool>> testConnection(WebDavLibraryConfig config) async {
    if (!config.isValid) {
      return const Res.error('Invalid WebDAV comic library configuration');
    }
    try {
      await ops.test(config);
      return const Res(true);
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  static Future<Res<List<Comic>>> loadComics(int page) async {
    final config = WebDavLibraryConfig.fromSettings();
    if (!config.isValid) {
      return const Res.error('Invalid WebDAV comic library configuration');
    }
    try {
      if (page < 1) return const Res([], subData: 1);
      final indexResult = await _ensureIndex(config);
      if (indexResult.error) {
        return Res.error(indexResult.errorMessage!);
      }
      final count = _cache.count(config.cacheKey);
      final maxPage = count == 0 ? 1 : (count + pageSize - 1) ~/ pageSize;
      if (page > maxPage) return Res([], subData: maxPage);
      final comics = _cache
          .page(config.cacheKey, page: page, pageSize: pageSize)
          .map(
            (comic) => Comic(
              comic.title,
              comic.cover,
              comic.id,
              null,
              comic.tags,
              '',
              sourceKey,
              null,
              null,
            ),
          )
          .toList();
      checkForAutomaticSync();
      return Res(comics, subData: maxPage);
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  static Future<Res<bool>> _ensureIndex(WebDavLibraryConfig config) async {
    if (_cache.hasDirectoryIndex(config.cacheKey)) {
      checkForAutomaticSync();
      return const Res(true);
    }
    return (await _startSynchronization(config: config).indexReady);
  }

  static Future<Res<bool>> synchronize({bool force = false}) {
    final config = WebDavLibraryConfig.fromSettings();
    if (!config.isValid) {
      return Future.value(
        const Res.error('Invalid WebDAV comic library configuration'),
      );
    }
    return _startSynchronization(config: config, force: force).complete;
  }

  static _WebDavLibrarySyncRun _startSynchronization({
    required WebDavLibraryConfig config,
    bool force = false,
  }) {
    final configurationIdentity = _configurationIdentity(config);
    final current = _syncRun;
    if (current != null &&
        current.generation == _syncGeneration &&
        current.configurationIdentity == configurationIdentity) {
      return current;
    }

    final indexReady = Completer<Res<bool>>();
    late final _WebDavLibrarySyncRun run;
    final complete = Future<Res<bool>>.microtask(
      () => _runSynchronization(config, run, indexReady, force: force),
    );
    run = _WebDavLibrarySyncRun(
      configurationIdentity: configurationIdentity,
      generation: _syncGeneration,
      indexReady: indexReady.future,
      complete: complete,
    );
    _syncRun = run;
    unawaited(
      complete.whenComplete(() {
        if (identical(_syncRun, run)) {
          _syncRun = null;
        }
      }),
    );
    return run;
  }

  static String _configurationIdentity(WebDavLibraryConfig config) =>
      jsonEncode([config.url, config.user, config.pass, config.remotePath]);

  static bool _isSynchronizationCurrent(_WebDavLibrarySyncRun run) {
    if (!identical(_syncRun, run) || run.generation != _syncGeneration) {
      return false;
    }
    final current = WebDavLibraryConfig.fromSettings();
    return current.isValid &&
        _configurationIdentity(current) == run.configurationIdentity;
  }

  static void _throwIfSynchronizationObsolete(_WebDavLibrarySyncRun run) {
    if (!_isSynchronizationCurrent(run)) {
      throw const _WebDavSynchronizationObsoleteException();
    }
  }

  static Res<bool> _completeObsoleteSynchronization(
    Completer<Res<bool>> indexReady,
  ) {
    const result = Res<bool>(true);
    if (!indexReady.isCompleted) indexReady.complete(result);
    return result;
  }

  static Future<Res<bool>> _runSynchronization(
    WebDavLibraryConfig config,
    _WebDavLibrarySyncRun run,
    Completer<Res<bool>> indexReady, {
    required bool force,
  }) async {
    final configKey = config.cacheKey;
    final previousLastSync = _cache.lastSuccessfulSync(configKey);
    final hadDirectoryIndex = _cache.hasDirectoryIndex(configKey);
    try {
      _throwIfSynchronizationObsolete(run);
      syncStatus.value = WebDavLibrarySyncStatus(
        isSyncing: true,
        lastSuccessfulSync: previousLastSync,
      );
      final rootEntries = List<WebDavLibraryEntry>.from(
        await ops.readDir(config, config.remotePath),
      );
      _throwIfSynchronizationObsolete(run);
      final previous = _cache.all(configKey);
      final provisionalDirectories = _sortedDirectories(rootEntries);
      if (!hadDirectoryIndex) {
        _cache.replaceDirectoryIndex(configKey, [
          for (var index = 0; index < provisionalDirectories.length; index++)
            WebDavLibraryRemoteDirectory(
              id: provisionalDirectories[index].name,
              sortIndex: index,
              eTag: provisionalDirectories[index].eTag,
              modifiedAt: provisionalDirectories[index].modifiedAt,
            ),
        ]);
      }
      _throwIfSynchronizationObsolete(run);
      if (!indexReady.isCompleted) {
        indexReady.complete(const Res(true));
      }
      contentVersion.value++;
      final discovered = await _discoverComicDirectories(
        config,
        rootEntries: rootEntries,
        syncRun: run,
      );
      _throwIfSynchronizationObsolete(run);
      final remoteDirectories = <WebDavLibraryRemoteDirectory>[
        for (var index = 0; index < discovered.length; index++)
          WebDavLibraryRemoteDirectory(
            id: discovered[index].id,
            sortIndex: index,
            eTag: discovered[index].eTag,
            modifiedAt: discovered[index].modifiedAt,
          ),
      ];
      _cache.replaceDirectoryIndex(configKey, remoteDirectories);
      contentVersion.value++;

      final scrapeCheckTime = metadataNowProvider();
      final toRefresh = <WebDavLibraryRemoteDirectory>[];
      for (final directory in remoteDirectories) {
        final cached = previous[directory.id];
        if (force ||
            !hadDirectoryIndex ||
            cached == null ||
            !cached.isReady ||
            (_canScrapeMetadata &&
                cached.shouldRetryMetadataScrape(
                  scraperVersion: _metadataScraperVersion,
                  now: scrapeCheckTime,
                )) ||
            !cached.hasSameRemoteVersion(
              eTag: directory.eTag,
              modifiedAt: directory.modifiedAt,
            )) {
          toRefresh.add(directory);
        }
      }

      var processed = 0;
      var failed = 0;
      _throwIfSynchronizationObsolete(run);
      syncStatus.value = WebDavLibrarySyncStatus(
        isSyncing: true,
        lastSuccessfulSync: previousLastSync,
        total: toRefresh.length,
      );
      await runThrottledTasks(
        toRefresh,
        concurrency: 4,
        throttleEvery: 0,
        run: (directory) async {
          try {
            _throwIfSynchronizationObsolete(run);
            final discoveredDirectory = discovered.firstWhere(
              (candidate) => candidate.id == directory.id,
            );
            await _loadSnapshot(
              config,
              directory.id,
              forceRefresh: true,
              remoteDirectory: directory,
              rootEntries: discoveredDirectory.entries.isEmpty
                  ? null
                  : discoveredDirectory.entries,
              childEntries: discoveredDirectory.childEntries,
              syncRun: run,
            );
          } on _WebDavSynchronizationObsoleteException {
            rethrow;
          } catch (e) {
            failed++;
            Log.warning(
              'WebDAV Library',
              'Failed to inspect ${directory.id}: $e',
            );
          } finally {
            processed++;
            if (_isSynchronizationCurrent(run) &&
                (processed % 5 == 0 || processed == toRefresh.length)) {
              contentVersion.value++;
              syncStatus.value = WebDavLibrarySyncStatus(
                isSyncing: true,
                lastSuccessfulSync: previousLastSync,
                processed: processed,
                total: toRefresh.length,
                failed: failed,
              );
            }
          }
        },
      );

      _throwIfSynchronizationObsolete(run);
      final now = DateTime.now().millisecondsSinceEpoch;
      _cache.setLastSuccessfulSync(configKey, now);
      syncStatus.value = WebDavLibrarySyncStatus(
        isSyncing: false,
        lastSuccessfulSync: now,
        processed: processed,
        total: toRefresh.length,
        failed: failed,
      );
      contentVersion.value++;
      return const Res(true);
    } on _WebDavSynchronizationObsoleteException {
      return _completeObsoleteSynchronization(indexReady);
    } catch (e, s) {
      if (!_isSynchronizationCurrent(run)) {
        return _completeObsoleteSynchronization(indexReady);
      }
      Log.error('WebDAV Library Sync', e, s);
      final result = Res<bool>.error(e.toString());
      if (!hadDirectoryIndex) {
        _cache.replaceDirectoryIndex(configKey, const []);
      }
      if (!indexReady.isCompleted) {
        indexReady.complete(result);
      }
      syncStatus.value = WebDavLibrarySyncStatus(
        isSyncing: false,
        lastSuccessfulSync: previousLastSync,
        errorMessage: e.toString(),
      );
      return result;
    }
  }

  static Future<Res<ComicDetails>> loadComicInfo(String id) async {
    final config = WebDavLibraryConfig.fromSettings();
    if (!config.isValid) {
      return const Res.error('Invalid WebDAV comic library configuration');
    }
    try {
      final snapshot = await _loadSnapshot(config, id);
      return Res(
        ComicDetails.fromJson({
          'title': snapshot.title,
          'subtitle': null,
          'cover': snapshot.cover,
          'description': snapshot.description,
          'tags': snapshot.detailTags,
          'chapters':
              snapshot.chapters.length == 1 &&
                  snapshot.chapters.containsKey(rootChapterId)
              ? null
              : snapshot.chapters,
          'sourceKey': sourceKey,
          'comicId': id,
          'externalIds': {
            if (snapshot.bangumiSubjectId != null)
              'bangumi': snapshot.bangumiSubjectId.toString(),
          },
          'thumbnails': null,
          'recommend': null,
          'isFavorite': false,
          'subId': null,
          'likesCount': null,
          'isLiked': null,
          'commentCount': null,
          'uploader': null,
          'uploadTime': null,
          'updateTime': null,
          'url': null,
          'maxPage': null,
        }),
      );
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  static Future<Res<List<String>>> loadComicPages(String id, String? ep) async {
    final config = WebDavLibraryConfig.fromSettings();
    if (!config.isValid) {
      return const Res.error('Invalid WebDAV comic library configuration');
    }
    try {
      final comicPath = config.childDirectoryPath(id);
      if (ep != null &&
          ep != rootChapterId &&
          !ep.startsWith(_metadataChapterPrefix)) {
        final path = config.childDirectoryPathFrom(comicPath, ep);
        final entries = List<WebDavLibraryEntry>.from(
          await ops.readDir(config, path),
        );
        final files = _imageEntries(entries)
            .where((entry) => !isNamedComicCover(entry.name))
            .map((entry) => config.childFilePath(path, entry.name))
            .toList();
        if (files.isEmpty) {
          return const Res.error('No images found in the WebDAV chapter');
        }
        return Res(files);
      }

      final snapshot = await _loadSnapshot(config, id);
      final metadataChapter = ep == null ? null : snapshot.metadataChapters[ep];
      if (metadataChapter != null) {
        final files = snapshot.rootImages
            .sublist(metadataChapter.start - 1, metadataChapter.end)
            .map((entry) => config.childFilePath(comicPath, entry.name))
            .toList();
        return Res(files);
      }
      if (ep?.startsWith(_metadataChapterPrefix) == true) {
        return const Res.error('Invalid WebDAV metadata chapter');
      }
      if (ep == null || ep == rootChapterId) {
        final files = snapshot.rootImages
            .map((entry) => config.childFilePath(comicPath, entry.name))
            .toList();
        if (files.isEmpty) {
          return const Res.error('No images found in the WebDAV chapter');
        }
        return Res(files);
      }
      return const Res.error('No images found in the WebDAV chapter');
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  static Future<_WebDavComicSnapshot> _loadSnapshot(
    WebDavLibraryConfig config,
    String id, {
    bool forceRefresh = false,
    WebDavLibraryRemoteDirectory? remoteDirectory,
    List<WebDavLibraryEntry>? rootEntries,
    Map<String, List<WebDavLibraryEntry>>? childEntries,
    _WebDavLibrarySyncRun? syncRun,
  }) async {
    final memoryKey = jsonEncode([config.cacheKey, id]);
    if (!forceRefresh) {
      final memoryCached = _snapshotCache[memoryKey];
      if (memoryCached != null) return memoryCached;
      final diskCached = _cache.find(config.cacheKey, id);
      if (diskCached?.isReady == true) {
        final snapshot = _WebDavComicSnapshot.fromJson(diskCached!.snapshot!);
        _snapshotCache[memoryKey] = snapshot;
        return snapshot;
      }
    }

    final inFlight = _snapshotInFlight[memoryKey];
    if (inFlight != null) return inFlight;
    final future = () async {
      final existing = _cache.find(config.cacheKey, id);
      final previousSnapshot = existing?.snapshot == null
          ? null
          : _WebDavComicSnapshot.fromJson(existing!.snapshot!);
      final snapshot = await _buildSnapshot(
        config,
        id,
        rootEntries: rootEntries,
        childEntries: childEntries,
        previousSnapshot: previousSnapshot,
        syncRun: syncRun,
      );
      if (syncRun != null) _throwIfSynchronizationObsolete(syncRun);
      _cache.upsertSnapshot(
        config.cacheKey,
        WebDavLibraryCachedComic(
          id: id,
          sortIndex: remoteDirectory?.sortIndex ?? existing?.sortIndex ?? 0,
          title: snapshot.title,
          author: snapshot.author,
          tags: snapshot.tags,
          cover: snapshot.cover,
          snapshot: snapshot.toJson(),
          remoteETag: remoteDirectory?.eTag ?? existing?.remoteETag,
          remoteModifiedAt:
              remoteDirectory?.modifiedAt ?? existing?.remoteModifiedAt,
        ),
      );
      _snapshotCache[memoryKey] = snapshot;
      return snapshot;
    }();
    _snapshotInFlight[memoryKey] = future;
    try {
      return await future;
    } finally {
      if (identical(_snapshotInFlight[memoryKey], future)) {
        _snapshotInFlight.remove(memoryKey);
      }
    }
  }

  static Future<_WebDavComicSnapshot> _buildSnapshot(
    WebDavLibraryConfig config,
    String id, {
    List<WebDavLibraryEntry>? rootEntries,
    Map<String, List<WebDavLibraryEntry>>? childEntries,
    _WebDavComicSnapshot? previousSnapshot,
    _WebDavLibrarySyncRun? syncRun,
  }) async {
    final comicPath = config.childDirectoryPath(id);
    final entries = List<WebDavLibraryEntry>.from(
      rootEntries ?? await ops.readDir(config, comicPath),
    );
    if (syncRun != null) _throwIfSynchronizationObsolete(syncRun);
    final rootImages = _imageEntries(
      entries,
    ).where((entry) => !isNamedComicCover(entry.name)).toList();
    final directories =
        entries
            .where((entry) => entry.isDirectory)
            .where((entry) => !_isIgnoredEntry(entry.name))
            .toList()
          ..sort((a, b) => compareComicFileNames(a.name, b.name));
    var metadataFilePresent = _hasMetadataFile(entries);
    var metadataScrapeStatus = metadataFilePresent
        ? 'notNeeded'
        : (previousSnapshot?.metadataScrapeStatus ?? 'pending');
    var metadataScraperVersion = metadataFilePresent
        ? ''
        : (previousSnapshot?.metadataScraperVersion ?? '');
    int? metadataScrapeAttemptedAt =
        previousSnapshot?.metadataScrapeAttemptedAt;
    int? metadataScrapeRetryAt = previousSnapshot?.metadataScrapeRetryAt;
    String? metadataScrapeError = previousSnapshot?.metadataScrapeError;
    var metadata = await _readMetadata(
      config,
      comicPath,
      entries,
      pageCount: directories.isEmpty ? rootImages.length : null,
    );
    if (syncRun != null) _throwIfSynchronizationObsolete(syncRun);
    final shouldScrape = _shouldAttemptMetadataScrape(
      previousSnapshot: previousSnapshot,
      metadataFilePresent: metadataFilePresent,
      scraperVersion: _metadataScraperVersion,
      now: metadataNowProvider(),
      automaticScrapingEnabled: _canScrapeMetadata,
    );
    if (shouldScrape) {
      if (syncRun != null) _throwIfSynchronizationObsolete(syncRun);
      final scraped = await _scrapeMissingMetadata(
        config,
        id,
        comicPath,
        pageCount: directories.isEmpty ? rootImages.length : null,
        syncRun: syncRun,
      );
      if (syncRun != null) _throwIfSynchronizationObsolete(syncRun);
      metadata = scraped.metadata;
      metadataFilePresent = scraped.filePresent;
      metadataScrapeStatus = scraped.status;
      metadataScraperVersion = _metadataScraperVersion;
      metadataScrapeAttemptedAt = scraped.attemptedAt;
      metadataScrapeRetryAt = scraped.retryAt;
      metadataScrapeError = scraped.error;
    }

    final inspectedChapterEntries = <String, List<WebDavLibraryEntry>>{
      ...?childEntries,
    };

    final metadataChapters = <String, ComicChapter>{};
    final chapterMap = <String, String>{};
    if (directories.isNotEmpty) {
      for (final directory in directories) {
        var chapterEntries = inspectedChapterEntries[directory.name];
        if (chapterEntries == null) {
          final chapterPath = config.childDirectoryPathFrom(
            comicPath,
            directory.name,
          );
          try {
            chapterEntries = List<WebDavLibraryEntry>.from(
              await ops.readDir(config, chapterPath),
            );
            if (syncRun != null) _throwIfSynchronizationObsolete(syncRun);
            inspectedChapterEntries[directory.name] = chapterEntries;
          } on _WebDavSynchronizationObsoleteException {
            rethrow;
          } catch (e) {
            if (syncRun != null) rethrow;
            Log.warning(
              'WebDAV Library',
              'Failed to inspect chapter directory at $chapterPath: $e',
            );
          }
        }
        final hasReadablePages =
            chapterEntries != null &&
            _imageEntries(
              chapterEntries,
            ).any((entry) => !isNamedComicCover(entry.name));
        if (hasReadablePages) {
          chapterMap[directory.name] = directory.name;
        }
      }
      if (rootImages.isNotEmpty) {
        chapterMap[rootChapterId] = rootChapterTitle;
      }
    } else if (metadata?.chapters?.isNotEmpty == true) {
      for (var index = 0; index < metadata!.chapters!.length; index++) {
        final chapter = metadata.chapters![index];
        final chapterId = '$_metadataChapterPrefix$index';
        metadataChapters[chapterId] = chapter;
        chapterMap[chapterId] = chapter.title;
      }
    } else if (rootImages.isNotEmpty) {
      chapterMap[rootChapterId] = rootChapterTitle;
    }
    if (chapterMap.isEmpty) {
      throw const FormatException(
        'No images found in the WebDAV comic directory',
      );
    }

    final namedCover = _findNamedCover(entries);
    String? coverPath = namedCover == null
        ? null
        : config.childFilePath(comicPath, namedCover.name);
    if (rootImages.isNotEmpty) {
      coverPath ??= config.childFilePath(comicPath, rootImages.first.name);
    }
    if (coverPath == null) {
      for (final directory in directories) {
        if (!chapterMap.containsKey(directory.name)) continue;
        final chapterPath = config.childDirectoryPathFrom(
          comicPath,
          directory.name,
        );
        var chapterEntries = inspectedChapterEntries[directory.name];
        if (chapterEntries == null) {
          try {
            chapterEntries = List<WebDavLibraryEntry>.from(
              await ops.readDir(config, chapterPath),
            );
            if (syncRun != null) _throwIfSynchronizationObsolete(syncRun);
            inspectedChapterEntries[directory.name] = chapterEntries;
          } on _WebDavSynchronizationObsoleteException {
            rethrow;
          } catch (e) {
            Log.warning(
              'WebDAV Library',
              'Failed to inspect chapter cover at $chapterPath: $e',
            );
          }
        }
        if (chapterEntries != null) {
          final chapterCover = _findNamedCover(chapterEntries);
          final chapterPages = _imageEntries(
            chapterEntries,
          ).where((entry) => !isNamedComicCover(entry.name)).toList();
          final coverEntry = chapterCover ?? chapterPages.firstOrNull;
          if (coverEntry != null) {
            coverPath = config.childFilePath(chapterPath, coverEntry.name);
            break;
          }
        }
      }
    }
    final metadataTitle = metadata?.title.trim() ?? '';
    return _WebDavComicSnapshot(
      title: metadataTitle.isEmpty ? _directoryName(id) : metadataTitle,
      author: metadata?.author ?? '',
      tags: metadata?.tags ?? const [],
      description: metadata?.description ?? '',
      cover: coverPath ?? '',
      chapters: chapterMap,
      metadataChapters: metadataChapters,
      rootImages: rootImages,
      bangumiSubjectId: metadata?.bangumiSubjectId,
      metadataFilePresent: metadataFilePresent,
      metadataScrapeStatus: metadataScrapeStatus,
      metadataScraperVersion: metadataScraperVersion,
      metadataScrapeAttemptedAt: metadataScrapeAttemptedAt,
      metadataScrapeRetryAt: metadataScrapeRetryAt,
      metadataScrapeError: metadataScrapeError,
    );
  }

  static int _nextMetadataPayloadSequence() {
    for (final pending in _pendingMetadataWrites()) {
      if (pending.sequence > _metadataPayloadSequence) {
        _metadataPayloadSequence = pending.sequence;
      }
    }
    return ++_metadataPayloadSequence;
  }

  static Future<void> writeMetadata(
    String id,
    ComicMetaData metadata, {
    String? expectedLibraryId,
    int? expectedSubjectId,
  }) async {
    final config = WebDavLibraryConfig.fromSettings();
    if (!config.isValid) {
      throw StateError('Invalid WebDAV comic library configuration');
    }
    final pending = _WebDavPendingMetadataWrite(
      libraryId: expectedLibraryId ?? config.libraryId,
      comicId: id,
      subjectId: expectedSubjectId ?? metadata.bangumiSubjectId,
      metadata: metadata,
      sequence: _nextMetadataPayloadSequence(),
    );
    try {
      await _writeMetadataNow(config, pending);
    } on WebDavMetadataWriteRejectedException {
      await _removePendingMetadataWrite(pending);
      rethrow;
    } catch (error, stackTrace) {
      await _recordPendingMetadataWrite(pending, error);
      Error.throwWithStackTrace(error, stackTrace);
    }
    await _removePendingMetadataWrite(pending);
    await _refreshSnapshotAfterMetadataWrite(config, id);
  }

  static Future<void> _writeMetadataNow(
    WebDavLibraryConfig config,
    _WebDavPendingMetadataWrite pending,
  ) async {
    await _ensureMetadataWriteCurrent(config, pending);
    final comicPath = config.childDirectoryPath(pending.comicId);
    await _runMetadataWrite(config, pending.comicId, () async {
      for (var attempt = 0; attempt < _maxMetadataMergeAttempts; attempt++) {
        await _ensureMetadataWriteCurrent(config, pending);
        final entries = List<WebDavLibraryEntry>.from(
          await ops.readDir(config, comicPath),
        );
        final pageCount = _metadataPageCount(entries);
        final metadataEntry = entries.firstWhereOrNull(
          (entry) =>
              !entry.isDirectory &&
              entry.name.toLowerCase() == _metadataFileName,
        );
        final metadataPath = config.childFilePath(
          comicPath,
          metadataEntry?.name ?? _metadataFileName,
        );
        try {
          if (metadataEntry == null) {
            final document = _mergeMetadataDocument(
              const {},
              pending.metadata,
              fallbackTitle: _directoryName(pending.comicId),
              pageCount: pageCount,
            );
            await _ensureMetadataWriteCurrent(config, pending);
            await ops.writeText(
              config,
              metadataPath,
              _encodeMetadataDocument(document),
              createOnly: true,
            );
          } else {
            final current = await ops.readText(config, metadataPath);
            final document = _mergeMetadataDocument(
              _decodeMetadataDocument(current.content),
              pending.metadata,
              fallbackTitle: _directoryName(pending.comicId),
              pageCount: pageCount,
            );
            final strongETag = _strongETag(current.eTag);
            if (strongETag == null && current.modifiedAt == null) {
              throw WebDavUnsupportedException(
                metadataPath,
                message:
                    'The WebDAV server returned no strong ETag or '
                    'Last-Modified validator for $metadataPath',
              );
            }
            await _ensureMetadataWriteCurrent(config, pending);
            await ops.writeText(
              config,
              metadataPath,
              _encodeMetadataDocument(document),
              ifMatch: strongETag,
              ifUnmodifiedSince: strongETag == null ? current.modifiedAt : null,
            );
          }
          return;
        } on WebDavPreconditionFailedException {
          if (attempt + 1 >= _maxMetadataMergeAttempts) rethrow;
        }
      }
    });
  }

  static String? _strongETag(String? eTag) {
    final candidate = eTag?.trim();
    if (candidate == null ||
        candidate.isEmpty ||
        candidate.toLowerCase().startsWith('w/')) {
      return null;
    }
    return candidate;
  }

  static Future<void> _ensureMetadataWriteCurrent(
    WebDavLibraryConfig config,
    _WebDavPendingMetadataWrite pending,
  ) async {
    if (config.libraryId != pending.libraryId ||
        WebDavLibraryConfig.fromSettings().libraryId != pending.libraryId) {
      throw const WebDavMetadataWriteRejectedException();
    }
    final guard = _metadataWriteGuard;
    if (guard != null &&
        !await Future.sync(
          () => guard(pending.libraryId, pending.comicId, pending.subjectId),
        )) {
      throw const WebDavMetadataWriteRejectedException();
    }
  }

  static Map<String, dynamic> _decodeMetadataDocument(String content) {
    final decoded = jsonDecode(content);
    if (decoded is! Map) {
      throw const FormatException('metadata.json must contain an object');
    }
    return Map<String, dynamic>.from(decoded);
  }

  static Map<String, dynamic> _mergeMetadataDocument(
    Map<String, dynamic> current,
    ComicMetaData metadata, {
    required String fallbackTitle,
    required int? pageCount,
  }) {
    List<ComicChapter>? chapters = metadata.chapters;
    final currentChapters = current['chapters'];
    if (currentChapters == null) {
      if (current.containsKey('chapters')) chapters = null;
    } else if (currentChapters is List) {
      try {
        final parsed = currentChapters.map((chapter) {
          if (chapter is! Map) {
            throw const FormatException(
              'metadata.chapters entries must be objects',
            );
          }
          return ComicChapter.fromJson(Map<String, dynamic>.from(chapter));
        }).toList();
        final candidate = ComicMetaData(
          title: metadata.title,
          author: metadata.author,
          tags: metadata.tags,
          description: metadata.description,
          chapters: parsed,
          bangumiSubjectId: metadata.bangumiSubjectId,
        );
        candidate.validateChapterRanges(pageCount: pageCount);
        chapters = parsed;
      } on FormatException {
        // Preserve only a structurally valid chapter list. Other corrupt
        // metadata fields must not make valid ranges disappear on update.
      }
    }
    final currentSubjectId = current['bangumiSubjectId'];
    final merged = ComicMetaData(
      title: metadata.title.trim().isEmpty ? fallbackTitle : metadata.title,
      author: metadata.author,
      tags: metadata.tags,
      description: metadata.description,
      chapters: chapters,
      bangumiSubjectId:
          metadata.bangumiSubjectId ??
          (currentSubjectId is int && currentSubjectId > 0
              ? currentSubjectId
              : null),
    );
    merged.validateChapterRanges(pageCount: pageCount);
    final result = <String, dynamic>{...current, ...merged.toJson()};
    if (merged.bangumiSubjectId == null) {
      result.remove('bangumiSubjectId');
    }
    return result;
  }

  static Future<void> _refreshSnapshotAfterMetadataWrite(
    WebDavLibraryConfig config,
    String id,
  ) async {
    final memoryKey = jsonEncode([config.cacheKey, id]);
    final inFlight = _snapshotInFlight[memoryKey];
    if (inFlight != null) {
      try {
        await inFlight;
      } catch (_) {}
    }
    _snapshotCache.remove(memoryKey);
    try {
      await _loadSnapshot(config, id, forceRefresh: true);
      contentVersion.value++;
    } catch (error, stackTrace) {
      Log.error('WebDAV metadata cache refresh', error, stackTrace);
    }
  }

  static Future<
    ({
      ComicMetaData? metadata,
      bool filePresent,
      String status,
      int? attemptedAt,
      int? retryAt,
      String? error,
    })
  >
  _scrapeMissingMetadata(
    WebDavLibraryConfig config,
    String id,
    String comicPath, {
    required int? pageCount,
    _WebDavLibrarySyncRun? syncRun,
  }) async {
    final scraper = _metadataScraper;
    if (scraper == null || !_canScrapeMetadata) {
      return (
        metadata: null,
        filePresent: false,
        status: 'pending',
        attemptedAt: null,
        retryAt: null,
        error: null,
      );
    }
    final attemptedAt = metadataNowProvider();
    try {
      final scraped = await scraper(_directoryName(id));
      if (syncRun != null) _throwIfSynchronizationObsolete(syncRun);
      if (scraped == null) {
        return (
          metadata: null,
          filePresent: false,
          status: 'noMatch',
          attemptedAt: attemptedAt,
          retryAt: null,
          error: null,
        );
      }
      scraped.validateChapterRanges(pageCount: pageCount);
      return await _runMetadataWrite(config, id, () async {
        final latestEntries = List<WebDavLibraryEntry>.from(
          await ops.readDir(config, comicPath),
        );
        if (syncRun != null) _throwIfSynchronizationObsolete(syncRun);
        if (_hasMetadataFile(latestEntries)) {
          return (
            metadata: await _readMetadata(
              config,
              comicPath,
              latestEntries,
              pageCount: _metadataPageCount(latestEntries),
            ),
            filePresent: true,
            status: 'notNeeded',
            attemptedAt: attemptedAt,
            retryAt: null,
            error: null,
          );
        }
        try {
          if (syncRun != null) _throwIfSynchronizationObsolete(syncRun);
          await ops.writeText(
            config,
            config.childFilePath(comicPath, _metadataFileName),
            _encodeMetadata(scraped),
            createOnly: true,
          );
          if (syncRun != null) _throwIfSynchronizationObsolete(syncRun);
          return (
            metadata: scraped,
            filePresent: true,
            status: 'matched',
            attemptedAt: attemptedAt,
            retryAt: null,
            error: null,
          );
        } on WebDavPreconditionFailedException {
          final refreshedEntries = List<WebDavLibraryEntry>.from(
            await ops.readDir(config, comicPath),
          );
          if (syncRun != null) _throwIfSynchronizationObsolete(syncRun);
          if (!_hasMetadataFile(refreshedEntries)) rethrow;
          return (
            metadata: await _readMetadata(
              config,
              comicPath,
              refreshedEntries,
              pageCount: _metadataPageCount(refreshedEntries),
            ),
            filePresent: true,
            status: 'notNeeded',
            attemptedAt: attemptedAt,
            retryAt: null,
            error: null,
          );
        }
      });
    } on _WebDavSynchronizationObsoleteException {
      rethrow;
    } catch (error) {
      Log.warning(
        'WebDAV Library',
        'Failed to scrape metadata for $id: $error',
      );
      return (
        metadata: null,
        filePresent: false,
        status: 'failed',
        attemptedAt: attemptedAt,
        retryAt: attemptedAt + const Duration(minutes: 15).inMilliseconds,
        error: error.toString(),
      );
    }
  }

  static Future<T> _runMetadataWrite<T>(
    WebDavLibraryConfig config,
    String id,
    Future<T> Function() action,
  ) async {
    final key = jsonEncode([config.cacheKey, id]);
    final previous = _metadataWriteTails[key];
    final done = Completer<void>();
    _metadataWriteTails[key] = done.future;
    try {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {}
      }
      return await action();
    } finally {
      done.complete();
      if (identical(_metadataWriteTails[key], done.future)) {
        _metadataWriteTails.remove(key);
      }
    }
  }

  static int? _metadataPageCount(List<WebDavLibraryEntry> entries) {
    if (entries.any(
      (entry) => entry.isDirectory && !_isIgnoredEntry(entry.name),
    )) {
      return null;
    }
    return _imageEntries(
      entries,
    ).where((entry) => !isNamedComicCover(entry.name)).length;
  }

  static String _encodeMetadata(ComicMetaData metadata) =>
      _encodeMetadataDocument(metadata.toJson());

  static String _encodeMetadataDocument(Map<String, dynamic> metadata) =>
      '${const JsonEncoder.withIndent('  ').convert(metadata)}\n';

  static Future<ComicMetaData?> _readMetadata(
    WebDavLibraryConfig config,
    String comicPath,
    List<WebDavLibraryEntry> entries, {
    int? pageCount,
  }) async {
    final metadataEntry = entries.firstWhereOrNull(
      (entry) =>
          !entry.isDirectory && entry.name.toLowerCase() == _metadataFileName,
    );
    if (metadataEntry == null) return null;

    final metadataPath = config.childFilePath(comicPath, metadataEntry.name);
    try {
      final file = await ops.readText(config, metadataPath);
      final metadata = ComicMetaData.fromJson(
        _decodeMetadataDocument(file.content),
      );
      metadata.validateChapterRanges(pageCount: pageCount);
      return metadata;
    } catch (error) {
      Log.warning(
        'WebDAV Library',
        'Ignoring invalid metadata at $metadataPath: $error',
      );
      return null;
    }
  }

  static void initializeMetadataRetry() {
    unawaited(retryPendingMetadata(force: true));
  }

  static Future<void> retryPendingMetadata({bool force = false}) async {
    _metadataRetryTimer?.cancel();
    _metadataRetryTimer = null;
    final config = WebDavLibraryConfig.fromSettings();
    if (!config.isValid) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final pending in _pendingMetadataWrites()) {
      if (pending.libraryId != config.libraryId ||
          (!force &&
              (pending.attempts >= _maxMetadataRetryAttempts ||
                  pending.nextRetryAt == null ||
                  pending.nextRetryAt! > now))) {
        continue;
      }
      try {
        await _writeMetadataNow(config, pending);
        await _removePendingMetadataWrite(pending);
        await _refreshSnapshotAfterMetadataWrite(config, pending.comicId);
      } on WebDavMetadataWriteRejectedException {
        await _removePendingMetadataWrite(pending);
      } catch (error) {
        await _recordPendingMetadataWrite(pending, error);
      }
    }
    _scheduleMetadataRetry();
  }

  static List<_WebDavPendingMetadataWrite> _pendingMetadataWrites() {
    final raw = appdata.implicitData[_metadataPendingKey];
    if (raw is! Map) return const [];
    final result = <_WebDavPendingMetadataWrite>[];
    for (final value in raw.values) {
      if (value is! Map) continue;
      try {
        result.add(
          _WebDavPendingMetadataWrite.fromJson(
            Map<String, dynamic>.from(value),
          ),
        );
      } catch (_) {
        continue;
      }
    }
    return result;
  }

  static Future<void> _recordPendingMetadataWrite(
    _WebDavPendingMetadataWrite pending,
    Object error,
  ) async {
    final failure = _metadataPendingFailure(error);
    final key = _pendingMetadataKey(pending.libraryId, pending.comicId);
    final raw = appdata.implicitData[_metadataPendingKey];
    final entries = <String, dynamic>{
      if (raw is Map)
        for (final entry in raw.entries)
          if (entry.key is String) entry.key as String: entry.value,
    };
    final existingRaw = entries[key];
    _WebDavPendingMetadataWrite? existing;
    if (existingRaw is Map) {
      try {
        existing = _WebDavPendingMetadataWrite.fromJson(
          Map<String, dynamic>.from(existingRaw),
        );
      } catch (_) {}
    }
    if (existing != null && existing.sequence > pending.sequence) return;
    final attempts =
        (existing != null &&
            existing.sequence == pending.sequence &&
            existing.subjectId == pending.subjectId)
        ? existing.attempts + 1
        : pending.attempts + 1;
    final now = DateTime.now().millisecondsSinceEpoch;
    final shouldRetry =
        attempts < _maxMetadataRetryAttempts &&
        (failure == WebDavMetadataPendingFailure.transient ||
            failure == WebDavMetadataPendingFailure.conflict ||
            failure == WebDavMetadataPendingFailure.other);
    final retryDelay = Duration(minutes: 1 << (attempts - 1).clamp(0, 3));
    final updated = pending.copyWith(
      attempts: attempts,
      lastAttemptAt: now,
      nextRetryAt: shouldRetry ? now + retryDelay.inMilliseconds : null,
      failure: failure,
      errorMessage: error.toString(),
    );
    entries[key] = updated.toJson();
    appdata.implicitData[_metadataPendingKey] = entries;
    await appdata.writeImplicitData();
    metadataPendingVersion.value++;
    _scheduleMetadataRetry();
  }

  static Future<void> _removePendingMetadataWrite(
    _WebDavPendingMetadataWrite pending,
  ) async {
    final raw = appdata.implicitData[_metadataPendingKey];
    if (raw is! Map) return;
    final key = _pendingMetadataKey(pending.libraryId, pending.comicId);
    final current = raw[key];
    if (current is Map) {
      try {
        final stored = _WebDavPendingMetadataWrite.fromJson(
          Map<String, dynamic>.from(current),
        );
        if (stored.sequence > pending.sequence) return;
      } catch (_) {}
    }
    final entries = <String, dynamic>{
      for (final entry in raw.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
    if (entries.remove(key) == null) return;
    appdata.implicitData[_metadataPendingKey] = entries;
    await appdata.writeImplicitData();
    metadataPendingVersion.value++;
    _scheduleMetadataRetry();
  }

  static WebDavMetadataPendingFailure _metadataPendingFailure(Object error) {
    if (error is WebDavAuthenticationException) {
      return WebDavMetadataPendingFailure.authentication;
    }
    if (error is WebDavTransientException) {
      return WebDavMetadataPendingFailure.transient;
    }
    if (error is WebDavUnsupportedException) {
      return WebDavMetadataPendingFailure.unsupported;
    }
    if (error is WebDavPreconditionFailedException) {
      return WebDavMetadataPendingFailure.conflict;
    }
    if (error is FormatException) {
      return WebDavMetadataPendingFailure.invalidMetadata;
    }
    return WebDavMetadataPendingFailure.other;
  }

  static String _pendingMetadataKey(String libraryId, String comicId) =>
      jsonEncode([libraryId, comicId]);

  static void _scheduleMetadataRetry() {
    _metadataRetryTimer?.cancel();
    _metadataRetryTimer = null;
    final libraryId = WebDavLibraryConfig.fromSettings().libraryId;
    final due = _pendingMetadataWrites()
        .where(
          (pending) =>
              pending.libraryId == libraryId &&
              pending.attempts < _maxMetadataRetryAttempts &&
              pending.nextRetryAt != null,
        )
        .map((pending) => pending.nextRetryAt!)
        .fold<int?>(null, (earliest, value) {
          return earliest == null || value < earliest ? value : earliest;
        });
    if (due == null) return;
    final delay = Duration(
      milliseconds: (due - DateTime.now().millisecondsSinceEpoch).clamp(
        0,
        const Duration(days: 1).inMilliseconds,
      ),
    );
    _metadataRetryTimer = Timer(delay, () {
      _metadataRetryTimer = null;
      unawaited(retryPendingMetadata());
    });
  }

  static bool _shouldAttemptMetadataScrape({
    required _WebDavComicSnapshot? previousSnapshot,
    required bool metadataFilePresent,
    required String scraperVersion,
    required int now,
    required bool automaticScrapingEnabled,
    bool forceMetadataScrape = false,
  }) {
    if (metadataFilePresent) return false;
    if (!automaticScrapingEnabled && !forceMetadataScrape) return false;
    if (forceMetadataScrape) return true;
    if (previousSnapshot == null) return true;
    if (previousSnapshot.metadataScraperVersion != scraperVersion) return true;

    switch (previousSnapshot.metadataScrapeStatus) {
      case 'pending':
        return true;
      case 'noMatch':
      case 'matched':
      case 'notNeeded':
        return false;
      case 'failed':
        final retryAt = previousSnapshot.metadataScrapeRetryAt;
        return retryAt == null || retryAt <= now;
      default:
        return true;
    }
  }

  static bool _looksLikeChapterName(String name) {
    final normalized = name.trim().toLowerCase();
    return RegExp(
      r'^(?:'
      r'\d+(?:[._-]\d+)?|'
      r'第?\s*(?:\d+|[零〇一二三四五六七八九十百两兩]+)\s*(?:话|話|章|卷|册|冊|回|集)(?:[\s._:—–~\[-].*)?|'
      r'\d+\s+第?\s*(?:\d+|[零〇一二三四五六七八九十百两兩]+)\s*(?:话|話|章|卷|册|冊|回|集)?(?:[\s._:—–~\[-].*)?|'
      r'卷\s*(?:\d+|[零〇一二三四五六七八九十百两兩]+)(?:[\s._:—–~\[-].*)?|'
      r'全\s*(?:\d+|[零〇一二三四五六七八九十百两兩]+)\s*(?:卷|册|冊|部|篇)(?:[\s._:—–~\[-].*)?|'
      r'(?:上|中|下|全)\s*(?:卷|册|冊|部|篇)(?:[\s._:—–~\[-].*)?|'
      r'(?:单行本|單行本)\s*\d+(?:[\s._:—–~\[-].*)?|'
      r'(?:ch(?:apter)?|ep(?:isode)?|vol(?:ume)?)\.?\s*\d+(?:[._-]\d+)?(?:[\s._:—–~\[-].*)?|'
      r'序章|终章|終章|番外(?:合集)?|外传|外傳|后日谈|後日談|后记|後記|短篇(?:集)?|特别篇(?:合集)?|附录|附錄|'
      r'prologue|epilogue|extra|extras|bonus|special|omake|side\s*story'
      r')$',
      caseSensitive: false,
    ).hasMatch(normalized);
  }

  static Future<List<_WebDavDiscoveredDirectory>> _discoverComicDirectories(
    WebDavLibraryConfig config, {
    required List<WebDavLibraryEntry> rootEntries,
    required _WebDavLibrarySyncRun syncRun,
  }) async {
    final result = <_WebDavDiscoveredDirectory>[];
    var inspectedDirectories = 0;
    final maxDirectories =
        discoveryDirectoryLimitOverride ?? _maxDiscoveryDirectories;

    Future<List<_WebDavDiscoveredDirectory>> scan({
      required WebDavLibraryEntry directory,
      required String id,
      required List<WebDavLibraryEntry> entries,
      required int depth,
      required bool preserveFallback,
    }) async {
      _throwIfSynchronizationObsolete(syncRun);
      final version = _directoryContentVersion(directory, entries);
      _WebDavDiscoveredDirectory current({
        Map<String, List<WebDavLibraryEntry>> childEntries = const {},
      }) => _WebDavDiscoveredDirectory(
        id: id,
        entries: entries,
        childEntries: childEntries,
        eTag: version.eTag,
        modifiedAt: version.modifiedAt,
      );

      if (_hasMetadataFile(entries) ||
          _imageEntries(
            entries,
          ).any((entry) => !isNamedComicCover(entry.name))) {
        return [current()];
      }
      final childDirectories = _sortedDirectories(entries);
      if (childDirectories.isEmpty) {
        return preserveFallback ? [current()] : const [];
      }

      if (depth >= _maxDiscoveryDepth) {
        Log.warning(
          'WebDAV Library',
          'Discovery depth limit reached while inspecting $id',
        );
        throw FormatException(
          'WebDAV comic discovery depth limit reached at $id',
        );
      }

      if (inspectedDirectories >= maxDirectories) {
        Log.warning(
          'WebDAV Library',
          'Discovery inspection limit reached while inspecting $id',
        );
        throw FormatException(
          'WebDAV comic discovery directory limit reached at $id',
        );
      }
      final children =
          <
            ({
              WebDavLibraryEntry directory,
              String id,
              List<WebDavLibraryEntry> entries,
            })
          >[];
      final childEntriesMap = <String, List<WebDavLibraryEntry>>{};
      for (final child in childDirectories) {
        if (inspectedDirectories >= maxDirectories) {
          Log.warning(
            'WebDAV Library',
            'Discovery inspection limit reached while inspecting $id',
          );
          throw FormatException(
            'Discovery inspection limit reached while inspecting $id',
          );
        }
        inspectedDirectories++;
        final childId = _joinRelativeDirectoryPath(id, child.name);
        final childPath = config.childDirectoryPath(childId);
        final childEntries = List<WebDavLibraryEntry>.from(
          await ops.readDir(config, childPath),
        );
        _throwIfSynchronizationObsolete(syncRun);
        children.add((directory: child, id: childId, entries: childEntries));
        childEntriesMap[child.name] = childEntries;
      }

      final hasExplicitComicChild = children.any(
        (child) => _hasMetadataFile(child.entries),
      );
      final hasNestedDirectoryChild = children.any(
        (child) => _sortedDirectories(child.entries).isNotEmpty,
      );

      if (!hasExplicitComicChild && !hasNestedDirectoryChild) {
        final childrenWithImages = children.where(
          (child) => _imageEntries(
            child.entries,
          ).any((entry) => !isNamedComicCover(entry.name)),
        );

        if (childrenWithImages.isNotEmpty) {
          final allImagesLookLikeChapters = childrenWithImages.every(
            (child) => _looksLikeChapterName(child.directory.name),
          );
          if (allImagesLookLikeChapters) {
            Log.info(
              'WebDAV Library',
              'Treating "$id" as comic root because all image child directories match chapter naming',
            );
            return [current(childEntries: childEntriesMap)];
          }
        } else if (childDirectories.every(
          (child) => _looksLikeChapterName(child.name),
        )) {
          Log.info(
            'WebDAV Library',
            'Treating "$id" as comic root because all child directory names match chapter naming',
          );
          return [current(childEntries: childEntriesMap)];
        }
      }

      final nested = <_WebDavDiscoveredDirectory>[];
      for (final child in children) {
        nested.addAll(
          await scan(
            directory: child.directory,
            id: child.id,
            entries: child.entries,
            depth: depth + 1,
            preserveFallback: false,
          ),
        );
      }
      if (nested.isNotEmpty) return nested;
      return preserveFallback ? [current()] : const [];
    }

    for (final directory in _sortedDirectories(rootEntries)) {
      if (inspectedDirectories >= maxDirectories) {
        Log.warning(
          'WebDAV Library',
          'Discovery inspection limit reached at library root',
        );
        throw const FormatException(
          'WebDAV comic discovery directory limit reached',
        );
      }
      inspectedDirectories++;
      final id = directory.name;
      final path = config.childDirectoryPath(id);
      final entries = List<WebDavLibraryEntry>.from(
        await ops.readDir(config, path),
      );
      _throwIfSynchronizationObsolete(syncRun);

      result.addAll(
        await scan(
          directory: directory,
          id: id,
          entries: entries,
          depth: 0,
          preserveFallback: true,
        ),
      );
      _throwIfSynchronizationObsolete(syncRun);
    }

    result.sort((a, b) => compareComicFileNames(a.id, b.id));
    return result;
  }

  static ({String? eTag, int? modifiedAt}) _directoryContentVersion(
    WebDavLibraryEntry directory,
    List<WebDavLibraryEntry> entries,
  ) {
    final trackedEntries = entries
        .where((entry) => !_isIgnoredEntry(entry.name))
        .toList();
    final hasReliableValidators =
        trackedEntries.isNotEmpty &&
        trackedEntries.every(
          (entry) => entry.eTag?.isNotEmpty == true || entry.modifiedAt != null,
        );
    if (!hasReliableValidators) return (eTag: null, modifiedAt: null);
    final sorted = List<WebDavLibraryEntry>.from(trackedEntries)
      ..sort((a, b) => compareComicFileNames(a.name, b.name));
    final identity = jsonEncode([
      directory.eTag,
      directory.modifiedAt,
      for (final entry in sorted)
        [entry.name, entry.isDirectory, entry.eTag, entry.modifiedAt],
    ]);
    return (
      eTag: 'venera:${sha256.convert(utf8.encode(identity))}',
      modifiedAt: null,
    );
  }

  static List<WebDavLibraryEntry> _sortedDirectories(
    List<WebDavLibraryEntry> entries,
  ) {
    return entries
        .where((entry) => entry.isDirectory)
        .where((entry) => !_isIgnoredEntry(entry.name))
        .toList()
      ..sort((a, b) => compareComicFileNames(a.name, b.name));
  }

  static bool _hasMetadataFile(List<WebDavLibraryEntry> entries) {
    return entries.any(
      (entry) =>
          !entry.isDirectory && entry.name.toLowerCase() == _metadataFileName,
    );
  }

  static String _joinRelativeDirectoryPath(String parent, String name) {
    return parent.isEmpty ? name : '$parent/$name';
  }

  static String _directoryName(String id) {
    final separator = id.lastIndexOf('/');
    return separator < 0 ? id : id.substring(separator + 1);
  }

  static Future<Map<String, dynamic>> getImageLoadingConfig(
    String imageKey,
    String comicId,
    String epId,
  ) async {
    final config = WebDavLibraryConfig.fromSettings();
    return {'url': config.fileUrl(imageKey), 'headers': config.authHeaders};
  }

  static Map<String, dynamic> getThumbnailLoadingConfig(String imageKey) {
    final config = WebDavLibraryConfig.fromSettings();
    if (imageKey.startsWith('cover.')) {
      return {'headers': config.authHeaders};
    }
    return {'url': config.fileUrl(imageKey), 'headers': config.authHeaders};
  }

  static List<WebDavLibraryEntry> _imageEntries(
    List<WebDavLibraryEntry> entries,
  ) {
    return sortedComicImageEntries(
      entries.where((entry) => !entry.isDirectory),
      nameOf: (entry) => entry.name,
    );
  }

  static WebDavLibraryEntry? _findNamedCover(List<WebDavLibraryEntry> entries) {
    return findNamedComicCover(
      _imageEntries(entries),
      nameOf: (entry) => entry.name,
    );
  }

  static bool _isIgnoredEntry(String name) {
    return isIgnoredComicStorageEntry(name) || isComicArchiveFileName(name);
  }
}

class _WebDavDiscoveredDirectory {
  const _WebDavDiscoveredDirectory({
    required this.id,
    required this.entries,
    this.childEntries = const {},
    this.eTag,
    this.modifiedAt,
  });

  final String id;
  final List<WebDavLibraryEntry> entries;
  final Map<String, List<WebDavLibraryEntry>> childEntries;
  final String? eTag;
  final int? modifiedAt;
}

class _WebDavPendingMetadataWrite {
  static const _unset = Object();

  const _WebDavPendingMetadataWrite({
    required this.libraryId,
    required this.comicId,
    required this.subjectId,
    required this.metadata,
    required this.sequence,
    this.attempts = 0,
    this.lastAttemptAt,
    this.nextRetryAt,
    this.failure = WebDavMetadataPendingFailure.none,
    this.errorMessage,
  });

  factory _WebDavPendingMetadataWrite.fromJson(Map<String, dynamic> json) {
    final libraryId = json['libraryId'];
    final comicId = json['comicId'];
    final subjectId = json['subjectId'];
    final rawMetadata = json['metadata'];
    if (libraryId is! String ||
        libraryId.isEmpty ||
        comicId is! String ||
        comicId.isEmpty ||
        (subjectId != null && (subjectId is! int || subjectId <= 0)) ||
        rawMetadata is! Map) {
      throw const FormatException('Invalid pending WebDAV metadata write');
    }
    final failureName = json['failure'];
    final failure = WebDavMetadataPendingFailure.values.firstWhere(
      (value) => value.name == failureName,
      orElse: () => WebDavMetadataPendingFailure.other,
    );
    return _WebDavPendingMetadataWrite(
      libraryId: libraryId,
      comicId: comicId,
      subjectId: subjectId as int?,
      metadata: ComicMetaData.fromJson(Map<String, dynamic>.from(rawMetadata)),
      sequence: (json['sequence'] as num?)?.toInt() ?? 0,
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
      lastAttemptAt: (json['lastAttemptAt'] as num?)?.toInt(),
      nextRetryAt: (json['nextRetryAt'] as num?)?.toInt(),
      failure: failure,
      errorMessage: json['errorMessage'] as String?,
    );
  }

  final String libraryId;
  final String comicId;
  final int? subjectId;
  final ComicMetaData metadata;
  final int sequence;
  final int attempts;
  final int? lastAttemptAt;
  final int? nextRetryAt;
  final WebDavMetadataPendingFailure failure;
  final String? errorMessage;

  WebDavMetadataPendingStatus get status => WebDavMetadataPendingStatus(
    libraryId: libraryId,
    comicId: comicId,
    subjectId: subjectId,
    attempts: attempts,
    lastAttemptAt: lastAttemptAt,
    nextRetryAt: nextRetryAt,
    failure: failure,
    errorMessage: errorMessage,
  );

  _WebDavPendingMetadataWrite copyWith({
    int? attempts,
    int? lastAttemptAt,
    Object? nextRetryAt = _unset,
    WebDavMetadataPendingFailure? failure,
    String? errorMessage,
  }) => _WebDavPendingMetadataWrite(
    libraryId: libraryId,
    comicId: comicId,
    subjectId: subjectId,
    metadata: metadata,
    sequence: sequence,
    attempts: attempts ?? this.attempts,
    lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
    nextRetryAt: identical(nextRetryAt, _unset)
        ? this.nextRetryAt
        : nextRetryAt as int?,
    failure: failure ?? this.failure,
    errorMessage: errorMessage ?? this.errorMessage,
  );

  Map<String, dynamic> toJson() => {
    'libraryId': libraryId,
    'comicId': comicId,
    'subjectId': subjectId,
    'metadata': metadata.toJson(),
    'sequence': sequence,
    'attempts': attempts,
    'lastAttemptAt': lastAttemptAt,
    'nextRetryAt': nextRetryAt,
    'failure': failure.name,
    'errorMessage': errorMessage,
  };
}

class _WebDavComicSnapshot {
  const _WebDavComicSnapshot({
    required this.title,
    required this.author,
    required this.description,
    required this.tags,
    required this.cover,
    required this.chapters,
    required this.metadataChapters,
    required this.rootImages,
    required this.bangumiSubjectId,
    required this.metadataFilePresent,
    required this.metadataScrapeStatus,
    required this.metadataScraperVersion,
    required this.metadataScrapeAttemptedAt,
    required this.metadataScrapeRetryAt,
    required this.metadataScrapeError,
  });

  final String title;
  final String author;
  final String description;
  final List<String> tags;
  final String cover;
  final Map<String, String> chapters;
  final Map<String, ComicChapter> metadataChapters;
  final List<WebDavLibraryEntry> rootImages;
  final int? bangumiSubjectId;
  final bool metadataFilePresent;
  final String metadataScrapeStatus;
  final String metadataScraperVersion;
  final int? metadataScrapeAttemptedAt;
  final int? metadataScrapeRetryAt;
  final String? metadataScrapeError;

  factory _WebDavComicSnapshot.fromJson(Map<String, dynamic> json) {
    final chapters = json['chapters'];
    final metadataChapters = json['metadataChapters'];
    final rootImages = json['rootImages'];
    final metadataFilePresent = json['metadataFilePresent'] == true;
    return _WebDavComicSnapshot(
      title: json['title'] as String,
      author: json['author'] as String? ?? '',
      description: json['description'] as String? ?? '',
      tags: (json['tags'] as List?)?.whereType<String>().toList() ?? const [],
      cover: json['cover'] as String? ?? '',
      chapters: chapters is Map
          ? chapters.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            )
          : const {},
      metadataChapters: metadataChapters is Map
          ? metadataChapters.map(
              (key, value) => MapEntry(
                key.toString(),
                ComicChapter.fromJson(Map<String, dynamic>.from(value as Map)),
              ),
            )
          : const {},
      rootImages: rootImages is List
          ? rootImages
                .whereType<Map>()
                .map(
                  (entry) => WebDavLibraryEntry(
                    name: entry['name'] as String,
                    isDirectory: false,
                    eTag: entry['eTag'] as String?,
                    modifiedAt: entry['modifiedAt'] as int?,
                  ),
                )
                .toList()
          : const [],
      bangumiSubjectId: json['bangumiSubjectId'] as int?,
      metadataFilePresent: metadataFilePresent,
      metadataScrapeStatus:
          json['metadataScrapeStatus'] as String? ??
          (metadataFilePresent ? 'notNeeded' : 'pending'),
      metadataScraperVersion: json['metadataScraperVersion'] as String? ?? '',
      metadataScrapeAttemptedAt: json['metadataScrapeAttemptedAt'] as int?,
      metadataScrapeRetryAt: json['metadataScrapeRetryAt'] as int?,
      metadataScrapeError: json['metadataScrapeError'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'formatVersion': webDavLibrarySnapshotFormatVersion,
    'title': title,
    'author': author,
    'description': description,
    'tags': tags,
    'cover': cover,
    'chapters': chapters,
    'metadataChapters': metadataChapters.map(
      (key, value) => MapEntry(key, value.toJson()),
    ),
    'bangumiSubjectId': bangumiSubjectId,
    'metadataFilePresent': metadataFilePresent,
    'metadataScrapeStatus': metadataScrapeStatus,
    'metadataScraperVersion': metadataScraperVersion,
    'metadataScrapeAttemptedAt': metadataScrapeAttemptedAt,
    'metadataScrapeRetryAt': metadataScrapeRetryAt,
    'metadataScrapeError': metadataScrapeError,
    'rootImages': [
      for (final entry in rootImages)
        {
          'name': entry.name,
          'eTag': entry.eTag,
          'modifiedAt': entry.modifiedAt,
        },
    ],
  };

  Map<String, List<String>> get detailTags => {
    if (author.trim().isNotEmpty) '作者': [author],
    if (tags.isNotEmpty) '标签': tags,
  };
}
