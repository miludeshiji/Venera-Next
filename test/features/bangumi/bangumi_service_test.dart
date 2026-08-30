import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/bangumi/bangumi.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  late FakeBangumiGateway gateway;
  late BangumiService service;
  var saveCount = 0;

  setUp(() {
    appdata.settings['bangumiAccessToken'] = '';
    appdata.settings['bangumiUsername'] = '';
    appdata.settings['bangumiAutoSyncEnabled'] = true;
    appdata.settings['bangumiBindings'] = <String, dynamic>{};
    gateway = FakeBangumiGateway();
    service = BangumiService.forTesting(
      gatewayFactory: (_) => gateway,
      saveSettings: () async => saveCount++,
    );
    saveCount = 0;
  });

  test('connect verifies then saves token and username', () async {
    gateway.user = const BangumiUser('alice', 'Alice');

    final user = await service.connect('  token  ');

    expect(user, const BangumiUser('alice', 'Alice'));
    expect(appdata.settings['bangumiAccessToken'], 'token');
    expect(appdata.settings['bangumiUsername'], 'alice');
    expect(gateway.currentUserCalls, 1);
    expect(saveCount, 1);
    expect(service.isConnected, isTrue);
  });

  test('failed connect does not replace an existing connection', () async {
    appdata.settings['bangumiAccessToken'] = 'old-token';
    appdata.settings['bangumiUsername'] = 'old-user';
    gateway.currentUserError = StateError('invalid token');

    await expectLater(service.connect('new-token'), throwsStateError);

    expect(appdata.settings['bangumiAccessToken'], 'old-token');
    expect(appdata.settings['bangumiUsername'], 'old-user');
    expect(saveCount, 0);
  });

  test('disconnect clears connection but retains bindings', () async {
    appdata.settings['bangumiAccessToken'] = 'token';
    appdata.settings['bangumiUsername'] = 'alice';
    final key = bangumiBindingKey('source', 'comic');
    appdata.settings['bangumiBindings'] = {key: binding().toJson()};

    await service.disconnect();

    expect(appdata.settings['bangumiAccessToken'], '');
    expect(appdata.settings['bangumiUsername'], '');
    expect(service.bindingFor('source', 'comic'), isNotNull);
    expect(saveCount, 1);
  });

  test(
    'search and subject lookup delegate through the current connection',
    () async {
      appdata.settings['bangumiAccessToken'] = 'token';
      appdata.settings['bangumiUsername'] = 'alice';
      gateway.searchResults = [subject()];
      gateway.subjects[42] = subject();

      final results = await service.searchSubjects('keyword');
      final result = await service.getSubject(42);

      expect(results, hasLength(1));
      expect(results.single.id, 42);
      expect(result.id, 42);
      expect(gateway.searchKeywords, ['keyword']);
      expect(gateway.subjectCalls, [42]);
    },
  );

  test('bind patches only higher reliable episode progress', () async {
    connectSettings();
    gateway.collection = collection(epStatus: 10, rate: 7);

    final result = await service.bind(
      sourceKey: 'source',
      comicId: 'comic',
      subject: subject(),
      mode: BangumiProgressMode.episode,
      reliableLocalProgress: const BangumiProgress(
        BangumiProgressField.episode,
        12,
      ),
    );

    expect(gateway.patchFields, [
      {'ep_status': 12},
    ]);
    expect(result.lastRemoteEpisode, 12);
    expect(result.lastRemoteVolume, 3);
    expect(result.rating, 7);
    expect(service.bindingFor('source', 'comic'), result);
  });

  test('bind retains a higher remote episode progress', () async {
    connectSettings();
    gateway.collection = collection(epStatus: 20);

    final result = await service.bind(
      sourceKey: 'source',
      comicId: 'comic',
      subject: subject(),
      mode: BangumiProgressMode.episode,
      reliableLocalProgress: const BangumiProgress(
        BangumiProgressField.episode,
        12,
      ),
    );

    expect(gateway.patchFields, isEmpty);
    expect(result.lastRemoteEpisode, 20);
  });

  test('bind ignores mismatched and non-positive local progress', () async {
    connectSettings();
    gateway.collection = collection(epStatus: 10, volStatus: 3);

    final mismatched = await service.bind(
      sourceKey: 'source',
      comicId: 'mismatched',
      subject: subject(),
      mode: BangumiProgressMode.volume,
      reliableLocalProgress: const BangumiProgress(
        BangumiProgressField.episode,
        20,
      ),
    );
    final nonPositive = await service.bind(
      sourceKey: 'source',
      comicId: 'non-positive',
      subject: subject(),
      mode: BangumiProgressMode.episode,
      reliableLocalProgress: const BangumiProgress(
        BangumiProgressField.episode,
        0,
      ),
    );

    expect(gateway.patchFields, isEmpty);
    expect(mismatched.lastRemoteVolume, 3);
    expect(nonPositive.lastRemoteEpisode, 10);
  });

  test(
    'bind creates a collection with reliable progress when absent',
    () async {
      connectSettings();

      final result = await service.bind(
        sourceKey: 'source',
        comicId: 'comic',
        subject: subject(),
        mode: BangumiProgressMode.episode,
        reliableLocalProgress: const BangumiProgress(
          BangumiProgressField.episode,
          12,
        ),
      );

      expect(gateway.createFields, hasLength(1));
      expect(gateway.createFields.single.$1, 42);
      expect(gateway.createFields.single.$2, <String, dynamic>{
        'type': 3,
        'ep_status': 12,
      });
      expect(result.lastRemoteEpisode, 12);
    },
  );

  test('bind creates a default collection without reliable progress', () async {
    connectSettings();

    await service.bind(
      sourceKey: 'source',
      comicId: 'comic',
      subject: subject(),
      mode: BangumiProgressMode.episode,
    );

    expect(gateway.createFields, hasLength(1));
    expect(gateway.createFields.single.$1, 42);
    expect(gateway.createFields.single.$2, <String, dynamic>{'type': 1});
  });

  test('bind does not persist when the remote operation fails', () async {
    connectSettings();
    gateway.collection = collection(epStatus: 10);
    gateway.patchError = StateError('remote failed');

    await expectLater(
      service.bind(
        sourceKey: 'source',
        comicId: 'comic',
        subject: subject(),
        mode: BangumiProgressMode.episode,
        reliableLocalProgress: const BangumiProgress(
          BangumiProgressField.episode,
          12,
        ),
      ),
      throwsStateError,
    );

    expect(service.bindingFor('source', 'comic'), isNull);
  });

  test('refresh updates all remote fields in its local binding', () async {
    connectSettings();
    setBinding(binding(lastRemoteEpisode: 1, lastRemoteVolume: 1, rating: 1));
    gateway.collection = collection(epStatus: 12, volStatus: 4, rate: 9);

    final result = await service.refresh('source', 'comic');

    expect(result, isNotNull);
    expect(result!.epStatus, 12);
    expect(result.volStatus, 4);
    expect(result.rate, 9);
    final updated = service.bindingFor('source', 'comic')!;
    expect(updated.lastRemoteEpisode, 12);
    expect(updated.lastRemoteVolume, 4);
    expect(updated.rating, 9);
    expect(saveCount, 1);
  });

  test(
    'manual progress decrease requires confirmation before patching',
    () async {
      connectSettings();
      setBinding(binding());
      gateway.collection = collection(epStatus: 12, rate: 6);

      await expectLater(
        service.updateManual(
          sourceKey: 'source',
          comicId: 'comic',
          field: BangumiProgressField.episode,
          progress: 10,
          rating: 8,
          allowDecrease: false,
        ),
        throwsA(
          isA<BangumiProgressDecreaseRequired>()
              .having((error) => error.remote, 'remote', 12)
              .having((error) => error.proposed, 'proposed', 10),
        ),
      );

      expect(gateway.patchFields, isEmpty);
    },
  );

  test('manual confirmed decrease patches progress and rating', () async {
    connectSettings();
    setBinding(binding());
    gateway.collection = collection(epStatus: 12, rate: 6);

    await service.updateManual(
      sourceKey: 'source',
      comicId: 'comic',
      field: BangumiProgressField.episode,
      progress: 10,
      rating: 8,
      allowDecrease: true,
    );

    expect(gateway.patchFields, [
      {'ep_status': 10, 'rate': 8},
    ]);
    final updated = service.bindingFor('source', 'comic')!;
    expect(updated.lastRemoteEpisode, 10);
    expect(updated.rating, 8);
  });

  test('manual rating-only updates only its changed field', () async {
    connectSettings();
    setBinding(binding());
    gateway.collection = collection(epStatus: 12, rate: 6);

    await service.updateManual(
      sourceKey: 'source',
      comicId: 'comic',
      field: BangumiProgressField.episode,
      progress: 12,
      rating: 8,
      allowDecrease: false,
    );

    expect(gateway.patchFields, [
      {'rate': 8},
    ]);
  });

  test(
    'manual update omits unchanged fields and validates input ranges',
    () async {
      connectSettings();
      setBinding(binding());
      gateway.collection = collection(epStatus: 12, rate: 8);

      await service.updateManual(
        sourceKey: 'source',
        comicId: 'comic',
        field: BangumiProgressField.episode,
        progress: 12,
        rating: 8,
        allowDecrease: false,
      );
      await expectLater(
        service.updateManual(
          sourceKey: 'source',
          comicId: 'comic',
          field: BangumiProgressField.episode,
          progress: -1,
          rating: 8,
          allowDecrease: false,
        ),
        throwsArgumentError,
      );
      await expectLater(
        service.updateManual(
          sourceKey: 'source',
          comicId: 'comic',
          field: BangumiProgressField.episode,
          progress: 12,
          rating: 11,
          allowDecrease: false,
        ),
        throwsArgumentError,
      );

      expect(gateway.patchFields, isEmpty);
    },
  );

  test(
    'updateMode replaces the outer bindings map and unbind stays local',
    () async {
      setBinding(binding());
      final previousBindings = appdata.settings['bangumiBindings'];

      await service.updateMode('source', 'comic', BangumiProgressMode.volume);

      expect(
        appdata.settings['bangumiBindings'],
        isNot(same(previousBindings)),
      );
      expect(
        service.bindingFor('source', 'comic')!.progressMode,
        BangumiProgressMode.volume,
      );
      await service.unbind('source', 'comic');
      expect(service.bindingFor('source', 'comic'), isNull);
      expect(gateway.createFields, isEmpty);
      expect(gateway.patchFields, isEmpty);
    },
  );

  test('updateMode rejects an unbound comic', () async {
    await expectLater(
      service.updateMode('source', 'comic', BangumiProgressMode.volume),
      throwsStateError,
    );
  });

  test('a corrupted binding returns null instead of throwing', () {
    appdata.settings['bangumiBindings'] = {
      bangumiBindingKey('source', 'comic'): 'not a binding',
    };

    expect(() => service.bindingFor('source', 'comic'), returnsNormally);
    expect(service.bindingFor('source', 'comic'), isNull);
  });
}

void connectSettings() {
  appdata.settings['bangumiAccessToken'] = 'token';
  appdata.settings['bangumiUsername'] = 'alice';
}

void setBinding(BangumiBinding binding) {
  appdata.settings['bangumiBindings'] = {
    bangumiBindingKey(binding.sourceKey, binding.comicId): binding.toJson(),
  };
}

BangumiSubject subject() => const BangumiSubject(
  id: 42,
  title: 'Title',
  originalTitle: 'Original',
  coverUrl: 'cover',
  totalEpisodes: 24,
  totalVolumes: 4,
);

BangumiCollection collection({
  int epStatus = 0,
  int volStatus = 3,
  int rate = 0,
}) => BangumiCollection(
  type: 3,
  rate: rate,
  epStatus: epStatus,
  volStatus: volStatus,
);

BangumiBinding binding({
  int lastRemoteEpisode = 12,
  int lastRemoteVolume = 3,
  int rating = 6,
}) => BangumiBinding(
  sourceKey: 'source',
  comicId: 'comic',
  subjectId: 42,
  subjectTitle: 'Title',
  subjectOriginalTitle: 'Original',
  coverUrl: 'cover',
  progressMode: BangumiProgressMode.episode,
  totalEpisodes: 24,
  totalVolumes: 4,
  lastRemoteEpisode: lastRemoteEpisode,
  lastRemoteVolume: lastRemoteVolume,
  rating: rating,
);

class FakeBangumiGateway implements BangumiGateway {
  BangumiUser user = const BangumiUser('alice', 'Alice');
  List<BangumiSubject> searchResults = [];
  final Map<int, BangumiSubject> subjects = {};
  BangumiCollection? collection;
  Object? currentUserError;
  Object? createError;
  Object? patchError;
  var currentUserCalls = 0;
  final searchKeywords = <String>[];
  final subjectCalls = <int>[];
  final collectionCalls = <(String, int)>[];
  final createFields = <(int, Map<String, dynamic>)>[];
  final patchFields = <Map<String, dynamic>>[];

  @override
  Future<BangumiUser> currentUser() async {
    currentUserCalls++;
    if (currentUserError != null) throw currentUserError!;
    return user;
  }

  @override
  Future<List<BangumiSubject>> searchSubjects(String keyword) async {
    searchKeywords.add(keyword);
    return searchResults;
  }

  @override
  Future<BangumiSubject> getSubject(int subjectId) async {
    subjectCalls.add(subjectId);
    return subjects[subjectId]!;
  }

  @override
  Future<BangumiCollection?> getCollection(
    String username,
    int subjectId,
  ) async {
    collectionCalls.add((username, subjectId));
    return collection;
  }

  @override
  Future<void> createCollection(
    int subjectId,
    Map<String, dynamic> fields,
  ) async {
    createFields.add((subjectId, Map.of(fields)));
    if (createError != null) throw createError!;
    collection = BangumiCollection(
      type: fields['type'] as int,
      rate: 0,
      epStatus: fields['ep_status'] as int? ?? 0,
      volStatus: fields['vol_status'] as int? ?? 0,
    );
  }

  @override
  Future<void> patchCollection(
    int subjectId,
    Map<String, dynamic> fields,
  ) async {
    patchFields.add(Map.of(fields));
    if (patchError != null) throw patchError!;
    final current = collection!;
    collection = BangumiCollection(
      type: current.type,
      rate: fields['rate'] as int? ?? current.rate,
      epStatus: fields['ep_status'] as int? ?? current.epStatus,
      volStatus: fields['vol_status'] as int? ?? current.volStatus,
    );
  }
}
