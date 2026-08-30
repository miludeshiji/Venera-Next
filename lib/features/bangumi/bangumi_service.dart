import 'package:flutter/foundation.dart';
import 'package:venera_next/features/bangumi/bangumi_api.dart';
import 'package:venera_next/features/bangumi/bangumi_models.dart';
import 'package:venera_next/foundation/appdata.dart';

typedef BangumiGatewayFactory = BangumiGateway Function(String token);
typedef BangumiSettingsSaver = Future<void> Function();

class BangumiProgressDecreaseRequired implements Exception {
  const BangumiProgressDecreaseRequired({
    required this.remote,
    required this.proposed,
  });

  final int remote;
  final int proposed;
}

class BangumiService {
  BangumiService._({
    required BangumiGatewayFactory gatewayFactory,
    required BangumiSettingsSaver saveSettings,
  }) : _gatewayFactory = gatewayFactory,
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

  final BangumiGatewayFactory _gatewayFactory;
  final BangumiSettingsSaver _saveSettings;

  bool get isConnected =>
      _settingString('bangumiAccessToken').isNotEmpty &&
      _settingString('bangumiUsername').isNotEmpty;

  Future<BangumiUser> connect(String token) async {
    final trimmedToken = token.trim();
    if (trimmedToken.isEmpty) {
      throw ArgumentError.value(token, 'token', 'Token must not be empty');
    }

    final user = await _gatewayFactory(trimmedToken).currentUser();
    final oldToken = appdata.settings['bangumiAccessToken'];
    final oldUsername = appdata.settings['bangumiUsername'];
    appdata.settings['bangumiAccessToken'] = trimmedToken;
    appdata.settings['bangumiUsername'] = user.username;
    try {
      await _saveSettings();
    } catch (_) {
      appdata.settings['bangumiAccessToken'] = oldToken;
      appdata.settings['bangumiUsername'] = oldUsername;
      rethrow;
    }
    return user;
  }

  Future<void> disconnect() async {
    appdata.settings['bangumiAccessToken'] = '';
    appdata.settings['bangumiUsername'] = '';
    await _saveSettings();
  }

  Future<List<BangumiSubject>> searchSubjects(String keyword) =>
      _gateway().searchSubjects(keyword);

  Future<BangumiSubject> getSubject(int subjectId) =>
      _gateway().getSubject(subjectId);

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
      if (binding.sourceKey != sourceKey ||
          binding.comicId != comicId ||
          binding.subjectId <= 0) {
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
  }) async {
    final gateway = _gateway();
    final collection = await gateway.getCollection(_username(), subject.id);
    final localProgress = _reliableProgress(mode, reliableLocalProgress);
    BangumiCollection finalCollection;

    if (collection == null) {
      final fields = <String, dynamic>{'type': localProgress == null ? 1 : 3};
      if (localProgress != null) {
        fields[localProgress.apiField] = localProgress.value;
      }
      await gateway.createCollection(subject.id, fields);
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
      finalCollection = collection;
      if (localProgress != null &&
          localProgress.value >
              _progressValue(collection, localProgress.field)) {
        await gateway.patchCollection(subject.id, {
          localProgress.apiField: localProgress.value,
        });
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
    await _saveBinding(binding);
    return binding;
  }

  Future<BangumiCollection?> refresh(String sourceKey, String comicId) async {
    final binding = _requiredBinding(sourceKey, comicId);
    final collection = await _gateway().getCollection(
      _username(),
      binding.subjectId,
    );
    if (collection == null) {
      return null;
    }
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
  ) async {
    final binding = _requiredBinding(sourceKey, comicId);
    await _saveBinding(binding.copyWith(progressMode: mode));
  }

  Future<void> updateManual({
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
      await _saveBinding(freshBinding);
      return;
    }

    await gateway.patchCollection(binding.subjectId, fields);
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
    );
  }

  Future<void> unbind(String sourceKey, String comicId) async {
    final key = bangumiBindingKey(sourceKey, comicId);
    final bindings = _copiedBindings();
    bindings.remove(key);
    appdata.settings['bangumiBindings'] = bindings;
    await _saveSettings();
  }

  BangumiGateway _gateway() {
    if (!isConnected) {
      throw StateError('Bangumi is not connected');
    }
    return _gatewayFactory(_settingString('bangumiAccessToken'));
  }

  String _username() => _settingString('bangumiUsername');

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

  Future<void> _saveBinding(BangumiBinding binding) async {
    final bindings = _copiedBindings();
    bindings[bangumiBindingKey(binding.sourceKey, binding.comicId)] = binding
        .toJson();
    appdata.settings['bangumiBindings'] = bindings;
    await _saveSettings();
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
}
