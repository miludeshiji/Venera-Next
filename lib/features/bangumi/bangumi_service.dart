import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera_next/features/bangumi/bangumi_api.dart';
import 'package:venera_next/features/bangumi/bangumi_models.dart';
import 'package:venera_next/foundation/appdata.dart';

typedef BangumiGatewayFactory = BangumiGateway Function(String token);
typedef BangumiSettingsSaver = Future<void> Function();
typedef BangumiRetryTimerFactory =
    Timer Function(Duration duration, void Function() callback);

class BangumiProgressDecreaseRequired implements Exception {
  const BangumiProgressDecreaseRequired({
    required this.remote,
    required this.proposed,
  });

  final int remote;
  final int proposed;
}

class BangumiLocalPersistenceException implements Exception {
  const BangumiLocalPersistenceException({
    required this.remoteSucceeded,
    required this.cause,
  });

  final bool remoteSucceeded;
  final Object cause;
}

class BangumiService {
  BangumiService._({
    required BangumiGatewayFactory gatewayFactory,
    required BangumiSettingsSaver saveSettings,
    required Map<String, dynamic> implicitData,
    required void Function() writeImplicitData,
    required DateTime Function() now,
    required BangumiRetryTimerFactory timerFactory,
  }) : _gatewayFactory = gatewayFactory,
       _saveSettings = saveSettings,
       _implicitData = implicitData,
       _writeImplicitData = writeImplicitData,
       _now = now,
       _timerFactory = timerFactory;

  static BangumiService? _instance;

  factory BangumiService() => _instance ??= BangumiService._(
    gatewayFactory: (token) => BangumiApi(token: token),
    saveSettings: appdata.saveData,
    implicitData: appdata.implicitData,
    writeImplicitData: appdata.writeImplicitData,
    now: DateTime.now,
    timerFactory: (duration, callback) => Timer(duration, callback),
  );

  @visibleForTesting
  factory BangumiService.forTesting({
    required BangumiGatewayFactory gatewayFactory,
    BangumiSettingsSaver? saveSettings,
    Map<String, dynamic>? implicitData,
    void Function()? writeImplicitData,
    DateTime Function()? now,
    BangumiRetryTimerFactory? timerFactory,
  }) => BangumiService._(
    gatewayFactory: gatewayFactory,
    saveSettings: saveSettings ?? () async {},
    implicitData: implicitData ?? <String, dynamic>{},
    writeImplicitData: writeImplicitData ?? () {},
    now: now ?? DateTime.now,
    timerFactory:
        timerFactory ?? ((duration, callback) => Timer(duration, callback)),
  );

  final BangumiGatewayFactory _gatewayFactory;
  final BangumiSettingsSaver _saveSettings;
  final Map<String, dynamic> _implicitData;
  final void Function() _writeImplicitData;
  final DateTime Function() _now;
  final BangumiRetryTimerFactory _timerFactory;
  Future<void> _connectionTail = Future.value();
  final _bindingTails = <String, Future<void>>{};
  Future<void> _bindingCommitTail = Future.value();
  Timer? _retryTimer;
  bool _disposed = false;
  bool _authenticationPaused = false;

  bool get isConnected =>
      _settingString('bangumiAccessToken').isNotEmpty &&
      _settingString('bangumiUsername').isNotEmpty;

  bool get isAuthenticationPaused => _authenticationPaused;

  Future<BangumiUser> connect(String token) =>
      _runConnection(() => _connect(token));

  Future<BangumiUser> _connect(String token) async {
    final trimmedToken = token.trim();
    if (trimmedToken.isEmpty) {
      throw ArgumentError.value(token, 'token', 'Token must not be empty');
    }

    final user = await _gatewayFactory(trimmedToken).currentUser();
    final username = user.username.trim();
    if (username.isEmpty) {
      throw StateError('Bangumi user has no username');
    }
    _cancelRetry();
    final oldToken = appdata.settings['bangumiAccessToken'];
    final oldUsername = appdata.settings['bangumiUsername'];
    appdata.settings['bangumiAccessToken'] = trimmedToken;
    appdata.settings['bangumiUsername'] = username;
    var saved = false;
    try {
      await _saveSettings();
      saved = true;
    } catch (_) {
      appdata.settings['bangumiAccessToken'] = oldToken;
      appdata.settings['bangumiUsername'] = oldUsername;
      rethrow;
    } finally {
      if (saved) _authenticationPaused = false;
      _scheduleRetry();
    }
    return user;
  }

  Future<void> disconnect() => _runConnection(_disconnect);

  Future<void> _disconnect() async {
    _cancelRetry();
    final oldToken = appdata.settings['bangumiAccessToken'];
    final oldUsername = appdata.settings['bangumiUsername'];
    appdata.settings['bangumiAccessToken'] = '';
    appdata.settings['bangumiUsername'] = '';
    var saved = false;
    try {
      await _saveSettings();
      saved = true;
    } catch (_) {
      appdata.settings['bangumiAccessToken'] = oldToken;
      appdata.settings['bangumiUsername'] = oldUsername;
      rethrow;
    } finally {
      if (saved) _authenticationPaused = false;
      _scheduleRetry();
    }
  }

  Future<List<BangumiSubject>> searchSubjects(String keyword) =>
      _runConnection(() => _gateway().searchSubjects(keyword));

  Future<BangumiSubject> getSubject(int subjectId) =>
      _runConnection(() => _gateway().getSubject(subjectId));

  BangumiBinding? bindingFor(String sourceKey, String comicId) {
    final rawBindings = appdata.settings['bangumiBindings'];
    if (rawBindings is! Map) {
      return null;
    }
    final rawBinding = rawBindings[bangumiBindingKey(sourceKey, comicId)];
    if (rawBinding is! Map) {
      return null;
    }
    try {
      final binding = BangumiBinding.fromJson(
        Map<String, dynamic>.from(rawBinding),
      );
      if (!_isValidBinding(binding, sourceKey: sourceKey, comicId: comicId)) {
        return null;
      }
      return binding;
    } catch (_) {
      return null;
    }
  }

  Future<BangumiBinding> bind({
    required String sourceKey,
    required String comicId,
    required BangumiSubject subject,
    required BangumiProgressMode mode,
    BangumiProgress? reliableLocalProgress,
  }) => _runBinding(
    sourceKey,
    comicId,
    () => _runConnection(
      () => _bind(
        sourceKey: sourceKey,
        comicId: comicId,
        subject: subject,
        mode: mode,
        reliableLocalProgress: reliableLocalProgress,
      ),
    ),
  );

  Future<BangumiBinding> _bind({
    required String sourceKey,
    required String comicId,
    required BangumiSubject subject,
    required BangumiProgressMode mode,
    BangumiProgress? reliableLocalProgress,
  }) async {
    if (subject.id <= 0) {
      throw ArgumentError.value(
        subject.id,
        'subject.id',
        'Subject id must be positive',
      );
    }
    if (subject.totalEpisodes < 0 || subject.totalVolumes < 0) {
      throw ArgumentError.value(
        subject,
        'subject',
        'Subject totals must be non-negative',
      );
    }
    final gateway = _gateway();
    final collection = await gateway.getCollection(_username(), subject.id);
    final localProgress = _reliableProgress(mode, reliableLocalProgress);
    BangumiCollection finalCollection;
    var remoteSucceeded = false;

    if (collection == null) {
      final fields = <String, dynamic>{'type': localProgress == null ? 1 : 3};
      if (localProgress != null) {
        fields[localProgress.apiField] = localProgress.value;
      }
      await gateway.createCollection(subject.id, fields);
      remoteSucceeded = true;
      finalCollection = BangumiCollection(
        type: fields['type'] as int,
        rate: 0,
        epStatus: localProgress?.field == BangumiProgressField.episode
            ? localProgress!.value
            : 0,
        volStatus: localProgress?.field == BangumiProgressField.volume
            ? localProgress!.value
            : 0,
      );
    } else {
      _validateCollection(collection);
      finalCollection = collection;
      if (localProgress != null &&
          localProgress.value >
              _progressValue(collection, localProgress.field)) {
        await gateway.patchCollection(subject.id, {
          localProgress.apiField: localProgress.value,
        });
        remoteSucceeded = true;
        finalCollection = _withProgress(
          collection,
          localProgress.field,
          localProgress.value,
        );
      }
    }

    final binding = BangumiBinding(
      sourceKey: sourceKey,
      comicId: comicId,
      subjectId: subject.id,
      subjectTitle: subject.title,
      subjectOriginalTitle: subject.originalTitle,
      coverUrl: subject.coverUrl,
      progressMode: mode,
      totalEpisodes: subject.totalEpisodes,
      totalVolumes: subject.totalVolumes,
      lastRemoteEpisode: finalCollection.epStatus,
      lastRemoteVolume: finalCollection.volStatus,
      rating: finalCollection.rate,
    );
    try {
      await _saveBinding(binding, remoteSucceeded: remoteSucceeded);
    } on BangumiLocalPersistenceException {
      _removePending(bangumiBindingKey(sourceKey, comicId));
      rethrow;
    }
    _removePending(bangumiBindingKey(sourceKey, comicId));
    return binding;
  }

  Future<BangumiCollection?> refresh(String sourceKey, String comicId) =>
      _runBinding(
        sourceKey,
        comicId,
        () => _runConnection(() => _refresh(sourceKey, comicId)),
      );

  Future<BangumiCollection?> _refresh(String sourceKey, String comicId) async {
    final binding = _requiredBinding(sourceKey, comicId);
    final collection = await _gateway().getCollection(
      _username(),
      binding.subjectId,
    );
    if (collection == null) {
      return null;
    }
    _validateCollection(collection);
    await _saveBinding(
      binding.copyWith(
        lastRemoteEpisode: collection.epStatus,
        lastRemoteVolume: collection.volStatus,
        rating: collection.rate,
      ),
    );
    return collection;
  }

  Future<void> updateMode(
    String sourceKey,
    String comicId,
    BangumiProgressMode mode,
  ) => _runBinding(
    sourceKey,
    comicId,
    () => _updateMode(sourceKey, comicId, mode),
  );

  Future<void> _updateMode(
    String sourceKey,
    String comicId,
    BangumiProgressMode mode,
  ) async {
    final binding = _requiredBinding(sourceKey, comicId);
    await _saveBinding(binding.copyWith(progressMode: mode));
    final expectedField = switch (mode) {
      BangumiProgressMode.episode => 'ep_status',
      BangumiProgressMode.volume => 'vol_status',
      BangumiProgressMode.auto => null,
    };
    if (expectedField != null) {
      _removePending(
        bangumiBindingKey(sourceKey, comicId),
        keepField: expectedField,
      );
    }
  }

  Future<void> updateManual({
    required String sourceKey,
    required String comicId,
    required BangumiProgressField field,
    required int progress,
    required int rating,
    required bool allowDecrease,
  }) => _runBinding(
    sourceKey,
    comicId,
    () => _runConnection(
      () => _updateManual(
        sourceKey: sourceKey,
        comicId: comicId,
        field: field,
        progress: progress,
        rating: rating,
        allowDecrease: allowDecrease,
      ),
    ),
  );

  Future<void> _updateManual({
    required String sourceKey,
    required String comicId,
    required BangumiProgressField field,
    required int progress,
    required int rating,
    required bool allowDecrease,
  }) async {
    if (progress < 0) {
      throw ArgumentError.value(
        progress,
        'progress',
        'Progress must be non-negative',
      );
    }
    if (rating < 0 || rating > 10) {
      throw ArgumentError.value(
        rating,
        'rating',
        'Rating must be from 0 to 10',
      );
    }

    final binding = _requiredBinding(sourceKey, comicId);
    final gateway = _gateway();
    final collection = await gateway.getCollection(
      _username(),
      binding.subjectId,
    );
    if (collection == null) {
      throw StateError('Bangumi collection no longer exists');
    }
    _validateCollection(collection);
    final freshBinding = binding.copyWith(
      lastRemoteEpisode: collection.epStatus,
      lastRemoteVolume: collection.volStatus,
      rating: collection.rate,
    );
    final remoteProgress = _progressValue(collection, field);
    if (progress < remoteProgress && !allowDecrease) {
      throw BangumiProgressDecreaseRequired(
        remote: remoteProgress,
        proposed: progress,
      );
    }

    final fields = <String, dynamic>{};
    if (progress != remoteProgress) {
      fields[field == BangumiProgressField.episode
              ? 'ep_status'
              : 'vol_status'] =
          progress;
    }
    if (rating != collection.rate) {
      fields['rate'] = rating;
    }
    if (fields.isEmpty) {
      try {
        await _saveBinding(freshBinding);
      } finally {
        _removePending(
          bangumiBindingKey(sourceKey, comicId),
          field: field == BangumiProgressField.episode
              ? 'ep_status'
              : 'vol_status',
        );
      }
      return;
    }

    await gateway.patchCollection(binding.subjectId, fields);
    try {
      await _saveBinding(
        freshBinding.copyWith(
          lastRemoteEpisode: field == BangumiProgressField.episode
              ? progress
              : freshBinding.lastRemoteEpisode,
          lastRemoteVolume: field == BangumiProgressField.volume
              ? progress
              : freshBinding.lastRemoteVolume,
          rating: rating,
        ),
        remoteSucceeded: true,
      );
    } finally {
      _removePending(
        bangumiBindingKey(sourceKey, comicId),
        field: field == BangumiProgressField.episode
            ? 'ep_status'
            : 'vol_status',
      );
    }
  }

  Future<void> unbind(String sourceKey, String comicId) =>
      _runBinding(sourceKey, comicId, () => _unbind(sourceKey, comicId));

  Future<void> _unbind(String sourceKey, String comicId) async {
    final key = bangumiBindingKey(sourceKey, comicId);
    await _runBindingCommit(() async {
      final previousBindings = appdata.settings['bangumiBindings'];
      final bindings = _copiedBindings();
      bindings.remove(key);
      appdata.settings['bangumiBindings'] = bindings;
      try {
        await _saveSettings();
      } catch (_) {
        appdata.settings['bangumiBindings'] = previousBindings;
        rethrow;
      }
    });
    _removePending(key);
  }

  Future<void> initialize() async {
    _disposed = false;
    if (!_autoSyncEnabled || _authenticationPaused) {
      _cancelRetry();
      return;
    }
    await _retryPending(readyOnly: true, retryExhausted: true);
    _scheduleRetry();
  }

  Future<void> onChapterCompleted({
    required String sourceKey,
    required String comicId,
    required String chapterTitle,
  }) async {
    if (!isConnected ||
        appdata.settings['bangumiAutoSyncEnabled'] != true ||
        bindingFor(sourceKey, comicId) == null) {
      return;
    }
    try {
      await _runBinding(
        sourceKey,
        comicId,
        () => _runConnection(
          () => _onChapterCompleted(sourceKey, comicId, chapterTitle),
        ),
      );
    } catch (_) {
      // Automatic upload must never interrupt the reader.
    }
  }

  Future<void> _onChapterCompleted(
    String sourceKey,
    String comicId,
    String chapterTitle,
  ) async {
    if (!isConnected || !_autoSyncEnabled) {
      return;
    }
    final binding = _requiredBinding(sourceKey, comicId);
    final key = bangumiBindingKey(sourceKey, comicId);
    final progress = BangumiTitleProgressParser.parse(
      chapterTitle,
      binding.progressMode,
    ).progress;
    if (_authenticationPaused) {
      if (progress != null) {
        _mergePending(key, progress);
        if (_pendingFor(key, progress.field) == null) {
          _enqueueInitialPending(key, progress);
        }
      }
      return;
    }
    for (final pending in _compatiblePending(key, binding)) {
      if (!await _retryPendingForBinding(key, binding, pending)) {
        if (progress != null) {
          _mergePending(key, progress);
          if (_pendingFor(key, progress.field) == null) {
            _enqueueInitialPending(key, progress);
          }
        }
        return;
      }
    }
    if (progress == null) return;
    try {
      await _uploadProgress(key, binding, progress);
    } on BangumiApiException catch (error) {
      if (error.isRetryable || _isAuthenticationError(error)) {
        if (_isAuthenticationError(error)) _pauseForAuthentication();
        _enqueueInitialPending(key, progress);
      }
    }
  }

  Future<void> retryPending({String? bindingKey}) async {
    try {
      if (!isConnected && _pendingEntries(bindingKey).isNotEmpty) {
        throw StateError('Bangumi is not connected');
      }
      await _retryPending(
        bindingKey: bindingKey,
        reportErrors: true,
        retryExhausted: true,
      );
    } finally {
      _scheduleRetry();
    }
  }

  Future<void> _retryPending({
    String? bindingKey,
    bool readyOnly = false,
    bool reportErrors = false,
    bool retryExhausted = false,
  }) async {
    final wasAuthenticationPaused = _authenticationPaused;
    final pendingKeys = _pendingEntries(
      bindingKey,
    ).map((entry) => entry.key).toSet();
    for (final key in pendingKeys) {
      final routeBinding = _bindingForKey(key);
      if (routeBinding == null) {
        _removePending(key);
        continue;
      }
      try {
        await _runBinding(
          routeBinding.sourceKey,
          routeBinding.comicId,
          () => _runConnection(
            () => _retryPendingForKeyLocked(
              key,
              readyOnly:
                  readyOnly ||
                  (wasAuthenticationPaused && !_authenticationPaused),
              reportErrors: reportErrors,
              retryExhausted: retryExhausted,
            ),
          ),
        );
      } catch (_) {
        if (reportErrors) rethrow;
      }
      if (_authenticationPaused) return;
    }
  }

  Future<void> _retryPendingForKeyLocked(
    String key, {
    required bool readyOnly,
    required bool reportErrors,
    required bool retryExhausted,
  }) async {
    final currentBinding = _bindingForKey(key);
    if (currentBinding == null) {
      _removePending(key);
      return;
    }
    if (!isConnected || (readyOnly && !_autoSyncEnabled)) {
      return;
    }
    for (final currentPending in _compatiblePending(key, currentBinding)) {
      if (!retryExhausted && currentPending.attempts >= 4) {
        continue;
      }
      if (readyOnly &&
          (!retryExhausted || currentPending.attempts < 4) &&
          currentPending.nextAttemptAt.isAfter(_now())) {
        continue;
      }
      await _retryPendingForBinding(
        key,
        currentBinding,
        currentPending,
        reportErrors: reportErrors,
      );
      if (_authenticationPaused) return;
    }
  }

  Future<bool> _retryPendingForBinding(
    String key,
    BangumiBinding binding,
    _BangumiPendingProgress pending, {
    bool reportErrors = false,
  }) async {
    try {
      await _uploadProgress(
        key,
        binding,
        BangumiProgress(pending.field, pending.value),
      );
      if (reportErrors) _authenticationPaused = false;
      return true;
    } on BangumiApiException catch (error) {
      if (_isAuthenticationError(error)) {
        _pauseForAuthentication();
      } else if (error.isRetryable) {
        _enqueueRetryPending(
          key,
          BangumiProgress(pending.field, pending.value),
        );
      } else {
        _removePending(key, field: _apiField(pending.field));
      }
      if (reportErrors) rethrow;
      if (_isAuthenticationError(error)) return false;
      if (!error.isRetryable) return true;
      return false;
    } on BangumiLocalPersistenceException {
      if (reportErrors) _authenticationPaused = false;
      return true;
    } catch (error) {
      _removePending(key, field: _apiField(pending.field));
      if (reportErrors) rethrow;
      return true;
    }
  }

  Future<void> _uploadProgress(
    String key,
    BangumiBinding binding,
    BangumiProgress progress,
  ) async {
    final gateway = _gateway();
    final collection = await gateway.getCollection(
      _username(),
      binding.subjectId,
    );
    if (collection == null) {
      throw StateError('Bangumi collection no longer exists');
    }
    _validateCollection(collection);
    final freshBinding = binding.copyWith(
      lastRemoteEpisode: collection.epStatus,
      lastRemoteVolume: collection.volStatus,
      rating: collection.rate,
    );
    if (progress.value <= _progressValue(collection, progress.field)) {
      try {
        await _saveBinding(freshBinding);
      } finally {
        _removePending(key, field: progress.apiField);
      }
      return;
    }

    final fields = <String, dynamic>{progress.apiField: progress.value};
    final total = progress.field == BangumiProgressField.episode
        ? binding.totalEpisodes
        : binding.totalVolumes;
    if (collection.type != 2 && total > 0 && progress.value >= total) {
      fields['type'] = 2;
    } else if ({1, 4, 5}.contains(collection.type)) {
      fields['type'] = 3;
    }
    await gateway.patchCollection(binding.subjectId, fields);
    try {
      await _saveBinding(
        freshBinding.copyWith(
          lastRemoteEpisode: progress.field == BangumiProgressField.episode
              ? progress.value
              : freshBinding.lastRemoteEpisode,
          lastRemoteVolume: progress.field == BangumiProgressField.volume
              ? progress.value
              : freshBinding.lastRemoteVolume,
        ),
        remoteSucceeded: true,
      );
    } finally {
      _removePending(key, field: progress.apiField);
    }
  }

  void dispose() {
    _disposed = true;
    _cancelRetry();
  }

  BangumiGateway _gateway() {
    if (!isConnected) {
      throw StateError('Bangumi is not connected');
    }
    return _gatewayFactory(_settingString('bangumiAccessToken'));
  }

  Future<T> _runConnection<T>(Future<T> Function() action) async {
    final previous = _connectionTail;
    final done = Completer<void>();
    _connectionTail = done.future;
    try {
      try {
        await previous;
      } catch (_) {}
      return await action();
    } finally {
      done.complete();
    }
  }

  Future<T> _runBinding<T>(
    String sourceKey,
    String comicId,
    Future<T> Function() action,
  ) {
    final key = bangumiBindingKey(sourceKey, comicId);
    final previous = _bindingTails[key];
    final done = Completer<void>();
    _bindingTails[key] = done.future;
    final result = Completer<T>();

    void finish() {
      done.complete();
      if (identical(_bindingTails[key], done.future)) {
        _bindingTails.remove(key);
      }
    }

    void start() {
      Future<T> operation;
      try {
        operation = action();
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
        finish();
        return;
      }
      operation.then(
        (value) {
          result.complete(value);
          finish();
        },
        onError: (Object error, StackTrace stackTrace) {
          result.completeError(error, stackTrace);
          finish();
        },
      );
    }

    if (previous == null) {
      start();
    } else {
      previous.then<void>(
        (_) => start(),
        onError: (Object _, StackTrace _) => start(),
      );
    }
    return result.future;
  }

  Future<T> _runBindingCommit<T>(Future<T> Function() action) async {
    final previous = _bindingCommitTail;
    final done = Completer<void>();
    _bindingCommitTail = done.future;
    try {
      try {
        await previous;
      } catch (_) {}
      return await action();
    } finally {
      done.complete();
    }
  }

  String _username() => _settingString('bangumiUsername');

  bool get _autoSyncEnabled =>
      appdata.settings['bangumiAutoSyncEnabled'] == true;

  bool _isAuthenticationError(BangumiApiException error) =>
      error.statusCode == 401 || error.statusCode == 403;

  void _pauseForAuthentication() {
    _authenticationPaused = true;
    _cancelRetry();
  }

  String _settingString(String key) {
    final value = appdata.settings[key];
    return value is String ? value : '';
  }

  BangumiBinding _requiredBinding(String sourceKey, String comicId) {
    final binding = bindingFor(sourceKey, comicId);
    if (binding == null) {
      throw StateError('Comic is not bound to Bangumi');
    }
    return binding;
  }

  bool _isValidBinding(
    BangumiBinding binding, {
    String? sourceKey,
    String? comicId,
  }) =>
      (sourceKey == null || binding.sourceKey == sourceKey) &&
      (comicId == null || binding.comicId == comicId) &&
      binding.subjectId > 0 &&
      binding.totalEpisodes >= 0 &&
      binding.totalVolumes >= 0 &&
      binding.lastRemoteEpisode >= 0 &&
      binding.lastRemoteVolume >= 0 &&
      binding.rating >= 0 &&
      binding.rating <= 10;

  void _validateCollection(BangumiCollection collection) {
    if (collection.epStatus < 0 ||
        collection.volStatus < 0 ||
        collection.rate < 0 ||
        collection.rate > 10) {
      throw StateError('Bangumi collection has invalid progress or rating');
    }
  }

  BangumiProgress? _reliableProgress(
    BangumiProgressMode mode,
    BangumiProgress? progress,
  ) {
    if (progress == null || progress.value <= 0) {
      return null;
    }
    final expectedField = switch (mode) {
      BangumiProgressMode.episode => BangumiProgressField.episode,
      BangumiProgressMode.volume => BangumiProgressField.volume,
      BangumiProgressMode.auto => null,
    };
    return expectedField == null || expectedField == progress.field
        ? progress
        : null;
  }

  int _progressValue(
    BangumiCollection collection,
    BangumiProgressField field,
  ) => field == BangumiProgressField.episode
      ? collection.epStatus
      : collection.volStatus;

  BangumiCollection _withProgress(
    BangumiCollection collection,
    BangumiProgressField field,
    int progress,
  ) => BangumiCollection(
    type: collection.type,
    rate: collection.rate,
    epStatus: field == BangumiProgressField.episode
        ? progress
        : collection.epStatus,
    volStatus: field == BangumiProgressField.volume
        ? progress
        : collection.volStatus,
  );

  Future<void> _saveBinding(
    BangumiBinding binding, {
    bool remoteSucceeded = false,
  }) async {
    if (!_isValidBinding(binding)) {
      throw ArgumentError.value(
        binding,
        'binding',
        'Binding has invalid values',
      );
    }
    await _runBindingCommit(() async {
      final previousBindings = appdata.settings['bangumiBindings'];
      final bindings = _copiedBindings();
      bindings[bangumiBindingKey(binding.sourceKey, binding.comicId)] = binding
          .toJson();
      appdata.settings['bangumiBindings'] = bindings;
      try {
        await _saveSettings();
      } catch (error) {
        if (remoteSucceeded) {
          throw BangumiLocalPersistenceException(
            remoteSucceeded: true,
            cause: error,
          );
        }
        appdata.settings['bangumiBindings'] = previousBindings;
        rethrow;
      }
    });
  }

  Map<String, dynamic> _copiedBindings() {
    final copied = <String, dynamic>{};
    final rawBindings = appdata.settings['bangumiBindings'];
    if (rawBindings is Map) {
      for (final entry in rawBindings.entries) {
        if (entry.key is String) {
          copied[entry.key as String] = entry.value;
        }
      }
    }
    return copied;
  }

  _BangumiPendingProgress? _pendingFor(
    String key, [
    BangumiProgressField? field,
  ]) {
    final raw = _pendingMap()?[key];
    if (raw is! Map) return null;
    if (field != null) {
      final item = raw[_apiField(field)];
      if (item is Map) {
        final pending = _BangumiPendingProgress.fromJson(item);
        if (pending?.field == field) return pending;
      }
      final legacy = _BangumiPendingProgress.fromJson(raw);
      return legacy?.field == field ? legacy : null;
    }
    final legacy = _BangumiPendingProgress.fromJson(raw);
    if (legacy != null) return legacy;
    for (final item in raw.values) {
      if (item is Map) {
        final pending = _BangumiPendingProgress.fromJson(item);
        if (pending != null) return pending;
      }
    }
    return null;
  }

  List<_BangumiPendingProgress> _compatiblePending(
    String key,
    BangumiBinding binding,
  ) {
    final pending = _pendingEntries(key)
        .map((entry) => entry.pending)
        .where((entry) => _isPendingCompatible(entry, binding))
        .toList();
    if (binding.progressMode != BangumiProgressMode.auto) {
      _removePending(
        key,
        keepField: binding.progressMode == BangumiProgressMode.episode
            ? 'ep_status'
            : 'vol_status',
      );
    }
    return pending;
  }

  bool _isPendingCompatible(
    _BangumiPendingProgress pending,
    BangumiBinding binding,
  ) => switch (binding.progressMode) {
    BangumiProgressMode.auto => true,
    BangumiProgressMode.episode =>
      pending.field == BangumiProgressField.episode,
    BangumiProgressMode.volume => pending.field == BangumiProgressField.volume,
  };

  List<({String key, _BangumiPendingProgress pending})> _pendingEntries(
    String? onlyKey,
  ) {
    final result = <({String key, _BangumiPendingProgress pending})>[];
    final raw = _implicitData['bangumiPendingProgress'];
    if (raw == null) {
      return result;
    }
    if (raw is! Map) {
      _implicitData.remove('bangumiPendingProgress');
      _writeImplicitData();
      return result;
    }
    final pendingMap = raw;
    Map<String, dynamic>? normalized;
    var changed = false;

    Map<String, dynamic> writableMap() =>
        normalized ??= _normalizedPendingMap();

    for (final entry in pendingMap.entries.toList()) {
      if (entry.key is! String) {
        writableMap();
        changed = true;
        continue;
      }
      final key = entry.key as String;
      if (onlyKey != null && key != onlyKey) {
        continue;
      }
      if (entry.value is! Map) {
        writableMap().remove(key);
        changed = true;
        continue;
      }
      final legacy = _BangumiPendingProgress.fromJson(entry.value as Map);
      if (legacy != null) {
        writableMap()[key] = {_apiField(legacy.field): legacy.toJson()};
        changed = true;
        result.add((key: key, pending: legacy));
        continue;
      }
      var valid = false;
      var hasInvalidSibling = false;
      final canonical = <String, dynamic>{};
      for (final item in (entry.value as Map).entries) {
        if (item.key is String && item.value is Map) {
          final pending = _BangumiPendingProgress.fromJson(item.value as Map);
          if (pending != null && item.key == _apiField(pending.field)) {
            valid = true;
            canonical[item.key as String] = pending.toJson();
            result.add((key: key, pending: pending));
          } else {
            hasInvalidSibling = true;
          }
        } else {
          hasInvalidSibling = true;
        }
      }
      if (!valid) {
        writableMap().remove(key);
        changed = true;
      } else if (hasInvalidSibling) {
        writableMap()[key] = canonical;
        changed = true;
      }
    }
    if (changed) _writeImplicitData();
    return result;
  }

  Map<dynamic, dynamic>? _pendingMap() {
    final raw = _implicitData['bangumiPendingProgress'];
    return raw is Map ? raw : null;
  }

  Map<dynamic, dynamic> _ensurePendingMap() {
    return _normalizedPendingMap();
  }

  Map<String, dynamic> _normalizedPendingMap() {
    final normalized = <String, dynamic>{};
    final existing = _pendingMap();
    if (existing != null) {
      for (final entry in existing.entries) {
        if (entry.key is String) {
          normalized[entry.key as String] = entry.value;
        }
      }
    }
    _implicitData['bangumiPendingProgress'] = normalized;
    return normalized;
  }

  BangumiBinding? _bindingForKey(String key) {
    final rawBindings = appdata.settings['bangumiBindings'];
    if (rawBindings is! Map || rawBindings[key] is! Map) {
      return null;
    }
    try {
      final binding = BangumiBinding.fromJson(
        Map<String, dynamic>.from(rawBindings[key] as Map),
      );
      return _isValidBinding(binding) &&
              bangumiBindingKey(binding.sourceKey, binding.comicId) == key
          ? binding
          : null;
    } catch (_) {
      return null;
    }
  }

  void _enqueueInitialPending(String key, BangumiProgress progress) {
    final existing = _pendingFor(key, progress.field);
    final attempts = existing?.attempts ?? 0;
    final value = existing != null && existing.value > progress.value
        ? existing.value
        : progress.value;
    _setPending(
      key,
      _BangumiPendingProgress(
        field: progress.field,
        value: value,
        attempts: attempts,
        nextAttemptAt: _now().add(const Duration(minutes: 5)),
      ),
    );
  }

  void _enqueueRetryPending(String key, BangumiProgress progress) {
    final existing = _pendingFor(key, progress.field);
    final attempts = (existing?.attempts ?? 0) + 1;
    _setPending(
      key,
      _BangumiPendingProgress(
        field: progress.field,
        value: existing != null && existing.value > progress.value
            ? existing.value
            : progress.value,
        attempts: attempts,
        nextAttemptAt: _now().add(_retryDelay(attempts)),
      ),
    );
  }

  void _mergePending(String key, BangumiProgress progress) {
    final existing = _pendingFor(key, progress.field);
    if (existing == null) return;
    if (progress.value > existing.value) {
      _setPending(key, existing.copyWith(value: progress.value));
    }
  }

  Duration _retryDelay(int attempts) => switch (attempts) {
    1 => const Duration(minutes: 10),
    2 => const Duration(minutes: 20),
    3 => const Duration(minutes: 40),
    _ => const Duration(minutes: 40),
  };

  void _setPending(String key, _BangumiPendingProgress pending) {
    final entries = _ensurePendingMap()[key];
    final fields = <String, dynamic>{};
    if (entries is Map) {
      final legacy = _BangumiPendingProgress.fromJson(entries);
      if (legacy != null) {
        fields[_apiField(legacy.field)] = legacy.toJson();
      } else {
        for (final entry in entries.entries) {
          if (entry.key is String && entry.value is Map) {
            final value = _BangumiPendingProgress.fromJson(entry.value as Map);
            if (value != null && entry.key == _apiField(value.field)) {
              fields[entry.key as String] = value.toJson();
            }
          }
        }
      }
    }
    fields[_apiField(pending.field)] = pending.toJson();
    _ensurePendingMap()[key] = fields;
    _writeImplicitData();
    _scheduleRetry();
  }

  void _removePending(String key, {String? field, String? keepField}) {
    final pendingMap = _pendingMap();
    if (pendingMap == null || !pendingMap.containsKey(key)) return;
    if (field == null && keepField == null) {
      _normalizedPendingMap().remove(key);
      _writeImplicitData();
      _scheduleRetry();
      return;
    }
    final raw = pendingMap[key];
    if (raw is! Map) {
      _normalizedPendingMap().remove(key);
      _writeImplicitData();
      _scheduleRetry();
      return;
    }
    final legacy = _BangumiPendingProgress.fromJson(raw);
    final fields = <String, dynamic>{};
    var needsNormalization = legacy != null;
    if (legacy != null) {
      fields[_apiField(legacy.field)] = legacy.toJson();
    } else {
      for (final entry in raw.entries) {
        if (entry.key is String && entry.value is Map) {
          final value = _BangumiPendingProgress.fromJson(entry.value as Map);
          if (value != null && entry.key == _apiField(value.field)) {
            fields[entry.key as String] = value.toJson();
          } else {
            needsNormalization = true;
          }
        } else {
          needsNormalization = true;
        }
      }
    }
    if (field != null) {
      if (fields.containsKey(field)) {
        fields.remove(field);
      } else if (!needsNormalization) {
        return;
      }
    }
    if (keepField != null) {
      if (fields.keys.any((name) => name != keepField)) {
        fields.removeWhere((name, _) => name != keepField);
      } else if (!needsNormalization) {
        return;
      }
    }
    if (fields.isEmpty) {
      _normalizedPendingMap().remove(key);
    } else {
      _normalizedPendingMap()[key] = fields;
    }
    _writeImplicitData();
    _scheduleRetry();
  }

  String _apiField(BangumiProgressField field) =>
      field == BangumiProgressField.episode ? 'ep_status' : 'vol_status';

  void _scheduleRetry() {
    _cancelRetry();
    if (_disposed ||
        _authenticationPaused ||
        !isConnected ||
        !_autoSyncEnabled) {
      return;
    }
    DateTime? next;
    for (final entry in _pendingEntries(null)) {
      if (entry.pending.attempts >= 4) {
        continue;
      }
      if (next == null || entry.pending.nextAttemptAt.isBefore(next)) {
        next = entry.pending.nextAttemptAt;
      }
    }
    if (next == null) {
      return;
    }
    final delay = next.difference(_now());
    _retryTimer = _timerFactory(delay.isNegative ? Duration.zero : delay, () {
      _retryTimer = null;
      unawaited(_retryReady());
    });
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  Future<void> _retryReady() async {
    if (!_autoSyncEnabled || _authenticationPaused) {
      _cancelRetry();
      return;
    }
    await _retryPending(readyOnly: true);
    _scheduleRetry();
  }
}

class _BangumiPendingProgress {
  const _BangumiPendingProgress({
    required this.field,
    required this.value,
    required this.attempts,
    required this.nextAttemptAt,
  });

  final BangumiProgressField field;
  final int value;
  final int attempts;
  final DateTime nextAttemptAt;

  static _BangumiPendingProgress? fromJson(Map raw) {
    final field = switch (raw['field']) {
      'ep_status' => BangumiProgressField.episode,
      'vol_status' => BangumiProgressField.volume,
      _ => null,
    };
    final value = raw['value'];
    final attempts = raw['attempts'];
    final nextAttemptAt = raw['nextAttemptAt'];
    if (field == null ||
        value is! int ||
        value < 0 ||
        attempts is! int ||
        attempts < 0 ||
        nextAttemptAt is! int) {
      return null;
    }
    try {
      return _BangumiPendingProgress(
        field: field,
        value: value,
        attempts: attempts,
        nextAttemptAt: DateTime.fromMillisecondsSinceEpoch(nextAttemptAt),
      );
    } catch (_) {
      return null;
    }
  }

  _BangumiPendingProgress copyWith({int? value}) => _BangumiPendingProgress(
    field: field,
    value: value ?? this.value,
    attempts: attempts,
    nextAttemptAt: nextAttemptAt,
  );

  Map<String, dynamic> toJson() => {
    'field': field == BangumiProgressField.episode ? 'ep_status' : 'vol_status',
    'value': value,
    'attempts': attempts,
    'nextAttemptAt': nextAttemptAt.millisecondsSinceEpoch,
  };
}
