import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/bangumi/bangumi.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  group('BangumiTitleProgressParser', () {
    test('parses a Chinese episode title in auto mode', () {
      expect(
        BangumiTitleProgressParser.parse('第 12 话', BangumiProgressMode.auto),
        const BangumiTitleParseResult.success(
          BangumiProgress(BangumiProgressField.episode, 12),
        ),
      );
    });

    test('parses full-width volume digits in auto mode', () {
      expect(
        BangumiTitleProgressParser.parse('第３卷', BangumiProgressMode.auto),
        const BangumiTitleParseResult.success(
          BangumiProgress(BangumiProgressField.volume, 3),
        ),
      );
    });

    test('uses volume mode for Vol. titles', () {
      expect(
        BangumiTitleProgressParser.parse('Vol. 8', BangumiProgressMode.volume),
        const BangumiTitleParseResult.success(
          BangumiProgress(BangumiProgressField.volume, 8),
        ),
      );
    });

    test('rejects multiple fallback numbers in Vol. titles', () {
      expect(
        BangumiTitleProgressParser.parse(
          'Vol. 8 extra 9',
          BangumiProgressMode.volume,
        ),
        const BangumiTitleParseResult.failure(
          BangumiTitleParseFailure.ambiguous,
        ),
      );
    });

    test('uses the requested field when a title contains both units', () {
      expect(
        BangumiTitleProgressParser.parse(
          '第 12 卷 第 63 话',
          BangumiProgressMode.episode,
        ),
        const BangumiTitleParseResult.success(
          BangumiProgress(BangumiProgressField.episode, 63),
        ),
      );
      expect(
        BangumiTitleProgressParser.parse(
          '第 12 卷 第 63 话',
          BangumiProgressMode.volume,
        ),
        const BangumiTitleParseResult.success(
          BangumiProgress(BangumiProgressField.volume, 12),
        ),
      );
    });

    test('rejects ambiguous auto titles', () {
      expect(
        BangumiTitleProgressParser.parse(
          '第 12 卷 第 63 话',
          BangumiProgressMode.auto,
        ),
        const BangumiTitleParseResult.failure(
          BangumiTitleParseFailure.ambiguous,
        ),
      );
    });

    test('rejects decimal and negative progress', () {
      expect(
        BangumiTitleProgressParser.parse('第 12.5 话', BangumiProgressMode.auto),
        const BangumiTitleParseResult.failure(BangumiTitleParseFailure.decimal),
      );
      expect(
        BangumiTitleProgressParser.parse('-3 话', BangumiProgressMode.auto),
        const BangumiTitleParseResult.failure(
          BangumiTitleParseFailure.negative,
        ),
      );
    });

    test('parses common Chinese numerals adjacent to units', () {
      expect(
        BangumiTitleProgressParser.parse('第十二话', BangumiProgressMode.auto),
        const BangumiTitleParseResult.success(
          BangumiProgress(BangumiProgressField.episode, 12),
        ),
      );
      expect(
        BangumiTitleProgressParser.parse('第一百零三話', BangumiProgressMode.auto),
        const BangumiTitleParseResult.success(
          BangumiProgress(BangumiProgressField.episode, 103),
        ),
      );
      expect(
        BangumiTitleProgressParser.parse('第兩百卷', BangumiProgressMode.auto),
        const BangumiTitleParseResult.success(
          BangumiProgress(BangumiProgressField.volume, 200),
        ),
      );
      expect(
        BangumiTitleProgressParser.parse('卷二〇四', BangumiProgressMode.auto),
        const BangumiTitleParseResult.success(
          BangumiProgress(BangumiProgressField.volume, 204),
        ),
      );
      expect(
        BangumiTitleProgressParser.parse('第一萬零三话', BangumiProgressMode.auto),
        const BangumiTitleParseResult.success(
          BangumiProgress(BangumiProgressField.episode, 10003),
        ),
      );
    });

    test('requires Chinese numerals to be adjacent to a progress unit', () {
      expect(
        BangumiTitleProgressParser.parse('番外三', BangumiProgressMode.episode),
        const BangumiTitleParseResult.failure(
          BangumiTitleParseFailure.noNumber,
        ),
      );
      expect(
        BangumiTitleProgressParser.parse(
          'Chapter 十二',
          BangumiProgressMode.volume,
        ),
        const BangumiTitleParseResult.failure(
          BangumiTitleParseFailure.noNumber,
        ),
      );
    });

    test('rejects unsupported Chinese numeric expressions', () {
      expect(
        BangumiTitleProgressParser.parse('第十2话', BangumiProgressMode.auto),
        const BangumiTitleParseResult.failure(
          BangumiTitleParseFailure.noNumber,
        ),
      );
      expect(
        BangumiTitleProgressParser.parse('第十二点五话', BangumiProgressMode.auto),
        const BangumiTitleParseResult.failure(BangumiTitleParseFailure.decimal),
      );
      expect(
        BangumiTitleProgressParser.parse('负三话', BangumiProgressMode.auto),
        const BangumiTitleParseResult.failure(
          BangumiTitleParseFailure.negative,
        ),
      );
    });

    test('rejects multiple Chinese values for the same unit', () {
      expect(
        BangumiTitleProgressParser.parse('第十二话 第十三話', BangumiProgressMode.auto),
        const BangumiTitleParseResult.failure(
          BangumiTitleParseFailure.ambiguous,
        ),
      );
    });

    test('rejects multiple values associated with the same unit', () {
      expect(
        BangumiTitleProgressParser.parse('12卷13', BangumiProgressMode.volume),
        const BangumiTitleParseResult.failure(
          BangumiTitleParseFailure.ambiguous,
        ),
      );
    });
  });

  test('BangumiTitleParseResult exposes its failure', () {
    const result = BangumiTitleParseResult.failure(
      BangumiTitleParseFailure.noNumber,
    );

    expect(result.failure, BangumiTitleParseFailure.noNumber);
  });

  test('Bangumi collection statuses map their API values', () {
    expect(
      BangumiCollectionStatus.values.map((status) => status.apiValue).toList(),
      [1, 3, 2, 4, 5],
    );
    for (final status in BangumiCollectionStatus.values) {
      expect(BangumiCollectionStatus.fromApiValue(status.apiValue), status);
    }
    expect(BangumiCollectionStatus.fromApiValue(0), isNull);
    expect(
      const BangumiCollection(
        type: 3,
        rate: 0,
        epStatus: 0,
        volStatus: 0,
      ).status,
      BangumiCollectionStatus.reading,
    );
    expect(BangumiCollection.fromJson({}).status, isNull);
  });

  test(
    'BangumiBinding round-trips through JSON and creates an escaped key',
    () {
      const binding = BangumiBinding(
        sourceKey: 'source',
        comicId: 'comic/1',
        subjectId: 42,
        subjectTitle: '标题',
        subjectOriginalTitle: 'Original',
        coverUrl: 'https://example.com/cover.jpg',
        progressMode: BangumiProgressMode.volume,
        collectionStatus: BangumiCollectionStatus.onHold,
        totalEpisodes: 12,
        totalVolumes: 3,
        lastRemoteEpisode: 10,
        lastRemoteVolume: 2,
        rating: 8,
      );

      expect(BangumiBinding.fromJson(binding.toJson()), binding);
      expect(
        bangumiBindingKey(binding.sourceKey, binding.comicId),
        'source@comic%2F1',
      );
      expect(
        BangumiBinding.fromJson({
          ...binding.toJson(),
          'progressMode': 'future-mode',
        }).progressMode,
        BangumiProgressMode.auto,
      );
      expect(
        BangumiBinding.fromJson({
          ...binding.toJson(),
          'progressMode': 1,
        }).progressMode,
        BangumiProgressMode.auto,
      );
      expect(binding.toJson()['collectionType'], 4);
      final legacyJson = binding.toJson()..remove('collectionType');
      expect(BangumiBinding.fromJson(legacyJson).collectionStatus, isNull);
      expect(
        () =>
            BangumiBinding.fromJson({...binding.toJson(), 'collectionType': 9}),
        throwsFormatException,
      );
    },
  );

  test('Bangumi model JSON mappings use expected values and defaults', () {
    const user = BangumiUser('user', '昵称');
    expect(BangumiUser.fromJson(user.toJson()), user);

    final subject = BangumiSubject.fromJson({
      'id': 1,
      'name': 'Original',
      'name_cn': '中文',
      'summary': '作品简介',
      'images': {'common': 'cover'},
      'eps': 24,
      'volumes': 4,
      'platform': 'TV',
    });
    expect(subject.toJson(), {
      'id': 1,
      'title': '中文',
      'originalTitle': 'Original',
      'nameCn': '中文',
      'summary': '作品简介',
      'coverUrl': 'cover',
      'totalEpisodes': 24,
      'totalVolumes': 4,
      'platform': 'TV',
      'authors': <String>[],
      'tags': <String>[],
    });
    expect(BangumiCollection.fromJson({}).toJson(), {
      'type': 0,
      'rate': 0,
      'epStatus': 0,
      'volStatus': 0,
    });
    expect(
      BangumiSubject.fromJson({'id': 2, 'name': 'No platform'}).platform,
      isNull,
    );

    const localSubject = BangumiSubject(
      id: 3,
      title: '中文标题',
      originalTitle: 'Original title',
      nameCn: '中文标题',
      summary: '本地简介',
      coverUrl: 'https://example.com/cover.jpg',
      totalEpisodes: 24,
      totalVolumes: 4,
      platform: 'TV',
    );
    final restoredSubject = BangumiSubject.fromJson(localSubject.toJson());
    expect(restoredSubject.id, localSubject.id);
    expect(restoredSubject.title, localSubject.title);
    expect(restoredSubject.originalTitle, localSubject.originalTitle);
    expect(restoredSubject.nameCn, localSubject.nameCn);
    expect(restoredSubject.summary, localSubject.summary);
    expect(restoredSubject.coverUrl, localSubject.coverUrl);
    expect(restoredSubject.totalEpisodes, localSubject.totalEpisodes);
    expect(restoredSubject.totalVolumes, localSubject.totalVolumes);
    expect(restoredSubject.platform, localSubject.platform);

    const localCollection = BangumiCollection(
      type: 2,
      rate: 8,
      epStatus: 12,
      volStatus: 3,
    );
    final restoredCollection = BangumiCollection.fromJson(
      localCollection.toJson(),
    );
    expect(restoredCollection.type, localCollection.type);
    expect(restoredCollection.rate, localCollection.rate);
    expect(restoredCollection.epStatus, localCollection.epStatus);
    expect(restoredCollection.volStatus, localCollection.volStatus);
  });

  test('Bangumi subject extracts ranked metadata and author fields', () {
    final subject = BangumiSubject.fromJson({
      'id': 42,
      'name': 'Original',
      'name_cn': '中文',
      'summary': '详情简介',
      'infobox': [
        {
          'key': '原作',
          'value': [
            {'v': '原作者'},
          ],
        },
        {'key': '作画', 'value': '漫画家'},
        {'key': '出版社', 'value': '出版社名称'},
      ],
      'meta_tags': ['漫画', '青年', 'Action'],
      'tags': [
        {'name': 'action', 'count': 100},
        {'name': '青年', 'count': 90},
        {'name': '用户1', 'count': 80},
        {'name': '用户2', 'count': 80},
        {'name': '用户3', 'count': 70},
        {'name': '用户4', 'count': 60},
        {'name': '用户5', 'count': 50},
        {'name': '用户6', 'count': 40},
        {'name': '用户7', 'count': 30},
        {'name': '用户8', 'count': 20},
        {'name': '用户9', 'count': 10},
        {'name': '用户10', 'count': 0},
        {'name': '损坏标签'},
      ],
    });

    expect(subject.metadataTitle, '中文');
    expect(subject.summary, '详情简介');
    expect(subject.authors, ['原作者', '漫画家']);
    expect(subject.tags, [
      '漫画',
      '青年',
      'Action',
      '用户1',
      '用户2',
      '用户3',
      '用户4',
      '用户5',
      '用户6',
      '用户7',
      '用户8',
    ]);
    final restored = BangumiSubject.fromJson(subject.toJson());
    expect(restored.authors, subject.authors);
    expect(restored.tags, subject.tags);
    expect(restored.summary, subject.summary);
  });

  test('Bangumi metadata title falls back to the original name', () {
    final subject = BangumiSubject.fromJson({
      'id': 43,
      'name': ' Original title ',
      'name_cn': '',
    });

    expect(subject.title, ' Original title ');
    expect(subject.metadataTitle, 'Original title');
  });

  test('Bangumi settings have defaults', () {
    expect(appdata.settings['bangumiAccessToken'], '');
    expect(appdata.settings['bangumiUsername'], '');
    expect(appdata.settings['bangumiAutoSyncEnabled'], isTrue);
    expect(
      appdata.settings['bangumiBindings'],
      isA<Map<String, Map<String, dynamic>>>(),
    );
  });
}
