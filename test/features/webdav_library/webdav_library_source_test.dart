import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/webdav_library/webdav_library.dart';
import 'package:venera_next/features/comic_storage/comic_storage.dart';
import 'package:venera_next/features/webdav_library/webdav_library_cache.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  late _FakeWebDavLibraryOps ops;
  late Directory dataDir;

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('venera-webdav-library-');
    App.dataPath = dataDir.path;
    WebDavLibrarySource.resetCacheForTesting();
    WebDavLibrarySource.configureMetadataScraper(null);
    ops = _FakeWebDavLibraryOps();
    WebDavLibrarySource.ops = ops;
    appdata.settings['webdavComicLibrary'] = [
      'https://example.com/dav',
      'user',
      'pass',
    ];
    appdata.settings['webdavComicLibraryPath'] = '/manga/';
    appdata.settings['webdavComicLibraryAutoSync'] = false;
  });

  tearDown(() async {
    if (WebDavLibrarySource.syncStatus.value.isSyncing) {
      await WebDavLibrarySource.synchronize();
    }
    WebDavLibrarySource.resetOps();
    WebDavLibrarySource.resetCacheForTesting();
    WebDavLibrarySource.configureMetadataScraper(null);
    appdata.settings['webdavComicLibrary'] = [];
    appdata.settings['webdavComicLibraryPath'] = '/venera_comics/';
    appdata.settings['webdavComicLibraryAutoSync'] = true;
    dataDir.deleteSync(recursive: true);
  });

  test('library identity excludes password but includes location and user', () {
    final first = WebDavLibraryConfig(
      url: ' HTTPS://EXAMPLE.COM:443/dav/ ',
      user: ' user ',
      pass: 'old password',
      remotePath: 'manga',
    );
    final passwordChanged = WebDavLibraryConfig(
      url: 'https://example.com/dav',
      user: 'user',
      pass: 'new password',
      remotePath: '/manga/',
    );
    final pathChanged = WebDavLibraryConfig(
      url: 'https://example.com/dav',
      user: 'user',
      pass: 'new password',
      remotePath: '/other/',
    );

    expect(passwordChanged.libraryId, first.libraryId);
    expect(pathChanged.libraryId, isNot(first.libraryId));
  });

  test('malformed synchronized connection tuples are rejected', () {
    appdata.settings['webdavComicLibrary'] = [
      'https://example.com/dav',
      'user',
      7,
      'password',
    ];

    expect(WebDavLibraryConfig.fromSettings().isValid, isFalse);
  });

  test('malformed synchronized remote paths fail closed', () {
    appdata.settings['webdavComicLibraryPath'] = '../other-library';

    final config = WebDavLibraryConfig.fromSettings();

    expect(config.isValid, isFalse);
    expect(config.remotePath, '/venera_comics/');
  });

  test('loadComics lists directories and ignores archives', () async {
    ops.dirs['/manga/'] = const [
      WebDavLibraryEntry(name: 'Cat Eye', isDirectory: true),
      WebDavLibraryEntry(name: 'archive.cbz', isDirectory: false),
      WebDavLibraryEntry(name: '.DS_Store', isDirectory: false),
    ];
    ops.dirs['/manga/Cat Eye/'] = const [
      WebDavLibraryEntry(name: 'cover.jpg', isDirectory: false),
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
    ];

    await WebDavLibrarySource.loadComics(1);
    await WebDavLibrarySource.synchronize();
    final result = await WebDavLibrarySource.loadComics(1);

    expect(result.success, isTrue);
    expect(result.data.single.cover, '/manga/Cat Eye/cover.jpg');
    expect(result.subData, 1);
    expect(result.data.map((comic) => comic.title), ['Cat Eye']);
    expect(result.data.single.sourceKey, WebDavLibrarySource.sourceKey);
  });

  test(
    'loadComics keeps folder title and finds chapter cover from unmodifiable lists',
    () async {
      ops.dirs['/manga/'] = List.unmodifiable([
        const WebDavLibraryEntry(name: '猫之眼[北条司]', isDirectory: true),
      ]);
      ops.dirs['/manga/猫之眼[北条司]/'] = List.unmodifiable([
        const WebDavLibraryEntry(name: '第01卷', isDirectory: true),
        const WebDavLibraryEntry(name: '第02卷', isDirectory: true),
      ]);
      ops.dirs['/manga/猫之眼[北条司]/第01卷/'] = List.unmodifiable([
        const WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
        const WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ]);

      await WebDavLibrarySource.loadComics(1);
      await WebDavLibrarySource.synchronize();
      final result = await WebDavLibrarySource.loadComics(1);

      expect(result.success, isTrue);
      expect(result.data.single.title, '猫之眼[北条司]');
      expect(result.data.single.cover, '/manga/猫之眼[北条司]/第01卷/001.jpg');
    },
  );

  test(
    'loadComics keeps folder title when metadata inspection fails',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Cat Eye', isDirectory: true),
      ];
      ops.errors['/manga/Cat Eye/'] = UnsupportedError(
        'Cannot remove from an unmodifiable list',
      );

      final result = await WebDavLibrarySource.loadComics(1);

      expect(result.success, isTrue);
      expect(result.data.single.title, 'Cat Eye');
      expect(result.data.single.cover, '');
    },
  );

  test(
    'initial list returns before comic metadata inspection finishes',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Slow Book', isDirectory: true),
      ];
      ops.dirs['/manga/Slow Book/'] = const [
        WebDavLibraryEntry(name: 'cover.jpg', isDirectory: false),
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      final blocker = Completer<void>();
      ops.blockers['/manga/Slow Book/'] = blocker;

      final initial = await WebDavLibrarySource.loadComics(1);

      expect(initial.success, isTrue);
      expect(initial.data.single.title, 'Slow Book');
      expect(initial.data.single.cover, isEmpty);
      expect(WebDavLibrarySource.syncStatus.value.isSyncing, isTrue);

      blocker.complete();
      await WebDavLibrarySource.synchronize();
      final updated = await WebDavLibrarySource.loadComics(1);

      expect(updated.data.single.cover, '/manga/Slow Book/cover.jpg');
    },
  );

  test('cached comic list is paged without additional WebDAV reads', () async {
    ops.dirs['/manga/'] = [
      for (var index = 1; index <= 45; index++)
        WebDavLibraryEntry(
          name: 'Book ${index.toString().padLeft(2, '0')}',
          isDirectory: true,
          eTag: 'v1',
        ),
    ];
    for (var index = 1; index <= 45; index++) {
      final name = 'Book ${index.toString().padLeft(2, '0')}';
      ops.dirs['/manga/$name/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
    }

    await WebDavLibrarySource.synchronize();
    ops.readPaths.clear();

    final first = await WebDavLibrarySource.loadComics(1);
    final second = await WebDavLibrarySource.loadComics(2);
    final third = await WebDavLibrarySource.loadComics(3);

    expect(first.data, hasLength(20));
    expect(second.data, hasLength(20));
    expect(third.data, hasLength(5));
    expect(first.subData, 3);
    expect(second.subData, 3);
    expect(third.subData, 3);
    expect(ops.readPaths, isEmpty);
  });

  test(
    'incremental sync fingerprints child entries before refreshing',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Book A', isDirectory: true, eTag: 'v1'),
        WebDavLibraryEntry(name: 'Book B', isDirectory: true, eTag: 'v1'),
      ];
      ops.dirs['/manga/Book A/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false, eTag: 'a1'),
      ];
      ops.dirs['/manga/Book B/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false, eTag: 'b1'),
      ];
      await WebDavLibrarySource.synchronize();
      ops.readPaths.clear();

      await WebDavLibrarySource.synchronize();
      expect(ops.readPaths, ['/manga/', '/manga/Book A/', '/manga/Book B/']);
      expect(WebDavLibrarySource.syncStatus.value.total, 0);

      ops.readPaths.clear();
      ops.dirs['/manga/Book A/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false, eTag: 'a2'),
      ];
      await WebDavLibrarySource.synchronize();

      expect(ops.readPaths, ['/manga/', '/manga/Book A/', '/manga/Book B/']);
      expect(WebDavLibrarySource.syncStatus.value.total, 1);
    },
  );

  test('failed refresh keeps the last successful cached list', () async {
    ops.dirs['/manga/'] = const [
      WebDavLibraryEntry(name: 'Cached Book', isDirectory: true),
    ];
    ops.dirs['/manga/Cached Book/'] = const [
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    await WebDavLibrarySource.synchronize();
    ops.errors['/manga/'] = StateError('WebDAV unavailable');

    final refresh = await WebDavLibrarySource.synchronize(force: true);
    final cached = await WebDavLibrarySource.loadComics(1);

    expect(refresh.error, isTrue);
    expect(cached.success, isTrue);
    expect(cached.data.single.title, 'Cached Book');
  });

  test(
    'configuration change starts a new sync and invalidates old side effects',
    () async {
      final previous = WebDavLibraryConfig.fromSettings();
      final oldReadStarted = Completer<void>();
      final oldReadBlocker = Completer<void>();
      ops.readStarted['/manga/'] = oldReadStarted;
      ops.blockers['/manga/'] = oldReadBlocker;
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Book A', isDirectory: true),
      ];
      ops.dirs['/manga/Book A/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/other/'] = const [
        WebDavLibraryEntry(name: 'Book B', isDirectory: true),
      ];
      ops.dirs['/other/Book B/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      WebDavLibrarySource.configureMetadataScraper(
        (_) async =>
            const ComicMetaData(title: 'Scraped', author: '', tags: []),
      );

      final oldSync = WebDavLibrarySource.synchronize();
      await oldReadStarted.future;

      appdata.settings['webdavComicLibraryPath'] = '/other/';
      WebDavLibrarySource.onConfigurationChanged(previous);
      WebDavLibrarySource.ops = ops;
      final newSync = await WebDavLibrarySource.synchronize().timeout(
        const Duration(seconds: 1),
      );

      expect(newSync.success, isTrue);
      expect(
        WebDavLibraryCache.instance.count(
          WebDavLibraryConfig.fromSettings().cacheKey,
        ),
        1,
      );
      expect(ops.writtenTexts, contains('/other/Book B/metadata.json'));
      final currentStatus = WebDavLibrarySource.syncStatus.value;
      final currentContentVersion = WebDavLibrarySource.contentVersion.value;

      oldReadBlocker.complete();
      final oldResult = await oldSync;

      expect(oldResult.success, isTrue);
      expect(WebDavLibraryCache.instance.count(previous.cacheKey), 0);
      expect(
        ops.writtenTexts.keys.where((path) => path.startsWith('/manga/')),
        isEmpty,
      );
      expect(
        WebDavLibrarySource.syncStatus.value.lastSuccessfulSync,
        currentStatus.lastSuccessfulSync,
      );
      expect(WebDavLibrarySource.syncStatus.value.isSyncing, isFalse);
      expect(WebDavLibrarySource.contentVersion.value, currentContentVersion);
    },
  );

  test('concurrent detail loads share one snapshot request', () async {
    ops.dirs['/manga/Book/'] = const [
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
    ];

    final results = await Future.wait([
      WebDavLibrarySource.loadComicInfo('Book'),
      WebDavLibrarySource.loadComicInfo('Book'),
    ]);

    expect(results.every((result) => result.success), isTrue);
    expect(ops.readPaths, ['/manga/Book/']);
  });

  test(
    'a detail-only cache entry does not replace the full library index',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Book A', isDirectory: true),
        WebDavLibraryEntry(name: 'Book B', isDirectory: true),
      ];
      ops.dirs['/manga/Book A/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Book B/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];

      await WebDavLibrarySource.loadComicInfo('Book A');
      await WebDavLibrarySource.loadComics(1);
      await WebDavLibrarySource.synchronize();
      final comics = await WebDavLibrarySource.loadComics(1);

      expect(comics.data.map((comic) => comic.id), ['Book A', 'Book B']);
    },
  );

  test(
    'loadComicInfo lists every chapter directory and uses the first page as cover',
    () async {
      ops.dirs['/manga/Cat Eye/'] = const [
        WebDavLibraryEntry(name: '第01卷', isDirectory: true),
        WebDavLibraryEntry(name: '第02卷', isDirectory: true),
        WebDavLibraryEntry(name: '第03卷', isDirectory: true),
        WebDavLibraryEntry(name: '第04卷', isDirectory: true),
        WebDavLibraryEntry(name: '第05卷', isDirectory: true),
        WebDavLibraryEntry(name: 'book.cbz', isDirectory: false),
      ];
      ops.dirs['/manga/Cat Eye/第01卷/'] = const [
        WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Cat Eye/第02卷/'] = const [
        WebDavLibraryEntry(name: '001.webp', isDirectory: false),
      ];
      for (var index = 3; index <= 5; index++) {
        ops.dirs['/manga/Cat Eye/第0$index卷/'] = const [
          WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
        ];
      }

      final result = await WebDavLibrarySource.loadComicInfo('Cat Eye');

      expect(result.success, isTrue);
      expect(result.data.cover, '/manga/Cat Eye/第01卷/001.jpg');
      expect(result.data.chapters!.allChapters, {
        '第01卷': '第01卷',
        '第02卷': '第02卷',
        '第03卷': '第03卷',
        '第04卷': '第04卷',
        '第05卷': '第05卷',
      });
      expect(ops.readPaths, [
        '/manga/Cat Eye/',
        '/manga/Cat Eye/第01卷/',
        '/manga/Cat Eye/第02卷/',
        '/manga/Cat Eye/第03卷/',
        '/manga/Cat Eye/第04卷/',
        '/manga/Cat Eye/第05卷/',
      ]);
    },
  );

  test(
    'nested metadata directory is indexed as one comic with child chapters',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: '分类', isDirectory: true),
      ];
      ops.dirs['/manga/分类/'] = const [
        WebDavLibraryEntry(name: '作者', isDirectory: true),
      ];
      ops.dirs['/manga/分类/作者/'] = const [
        WebDavLibraryEntry(name: '猫之眼', isDirectory: true),
      ];
      ops.dirs['/manga/分类/作者/猫之眼/'] = const [
        WebDavLibraryEntry(name: 'metadata.json', isDirectory: false),
        WebDavLibraryEntry(name: 'cover.jpg', isDirectory: false),
        WebDavLibraryEntry(name: '第01章', isDirectory: true),
        WebDavLibraryEntry(name: '第02章', isDirectory: true),
      ];
      ops.dirs['/manga/分类/作者/猫之眼/第01章/'] = const [
        WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/分类/作者/猫之眼/第02章/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.textFiles['/manga/分类/作者/猫之眼/metadata.json'] = jsonEncode({
        'title': '猫之眼',
        'author': '北条司',
        'tags': ['动作'],
        'chapters': [
          {'title': '错误的扁平章节', 'start': 1, 'end': 2},
        ],
      });

      final sync = await WebDavLibrarySource.synchronize();
      final comics = await WebDavLibrarySource.loadComics(1);
      final details = await WebDavLibrarySource.loadComicInfo('分类/作者/猫之眼');
      final pages = await WebDavLibrarySource.loadComicPages(
        '分类/作者/猫之眼',
        '第01章',
      );

      expect(sync.success, isTrue);
      expect(comics.success, isTrue);
      expect(comics.data.single.id, '分类/作者/猫之眼');
      expect(comics.data.single.title, '猫之眼');
      expect(comics.data.single.cover, '/manga/分类/作者/猫之眼/cover.jpg');
      expect(details.success, isTrue);
      expect(details.data.chapters!.allChapters, {
        '第01章': '第01章',
        '第02章': '第02章',
      });
      expect(pages.success, isTrue);
      expect(pages.data, [
        '/manga/分类/作者/猫之眼/第01章/001.jpg',
        '/manga/分类/作者/猫之眼/第01章/002.jpg',
      ]);
    },
  );

  test(
    'nested metadata directories keep distinct relative ids for duplicate names',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: '分类A', isDirectory: true),
        WebDavLibraryEntry(name: '分类B', isDirectory: true),
      ];
      for (final category in ['分类A', '分类B']) {
        ops.dirs['/manga/$category/'] = const [
          WebDavLibraryEntry(name: '猫之眼', isDirectory: true),
        ];
        ops.dirs['/manga/$category/猫之眼/'] = const [
          WebDavLibraryEntry(name: 'metadata.json', isDirectory: false),
          WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
        ];
        ops.textFiles['/manga/$category/猫之眼/metadata.json'] = jsonEncode({
          'title': category,
          'author': '',
          'tags': <String>[],
          'chapters': null,
        });
      }

      final sync = await WebDavLibrarySource.synchronize();
      final comics = await WebDavLibrarySource.loadComics(1);

      expect(sync.success, isTrue);
      expect(comics.data, hasLength(2));
      expect(comics.data.map((comic) => comic.id), ['分类A/猫之眼', '分类B/猫之眼']);
    },
  );

  test('metadata directory wins over nested metadata directories', () async {
    ops.dirs['/manga/'] = const [
      WebDavLibraryEntry(name: '猫之眼', isDirectory: true),
    ];
    ops.dirs['/manga/猫之眼/'] = const [
      WebDavLibraryEntry(name: 'metadata.json', isDirectory: false),
      WebDavLibraryEntry(name: '第01章', isDirectory: true),
    ];
    ops.dirs['/manga/猫之眼/第01章/'] = const [
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    ops.dirs['/manga/猫之眼/第01章/嵌套漫画/'] = const [
      WebDavLibraryEntry(name: 'metadata.json', isDirectory: false),
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    ops.textFiles['/manga/猫之眼/metadata.json'] = jsonEncode({
      'title': '猫之眼',
      'author': '',
      'tags': <String>[],
      'chapters': null,
    });

    final sync = await WebDavLibrarySource.synchronize();
    final comics = await WebDavLibrarySource.loadComics(1);

    expect(sync.success, isTrue);
    expect(comics.data, hasLength(1));
    expect(comics.data.single.id, '猫之眼');
    expect(ops.readPaths, contains('/manga/猫之眼/'));
    expect(ops.readPaths, isNot(contains('/manga/猫之眼/第01章/嵌套漫画/')));
  });

  test(
    'incremental sync rebuilds snapshots from the old cache format',
    () async {
      const comicId = 'Cached Book';
      final config = WebDavLibraryConfig.fromSettings();
      final cache = WebDavLibraryCache.instance;
      cache.replaceDirectoryIndex(config.cacheKey, const [
        WebDavLibraryRemoteDirectory(id: comicId, sortIndex: 0, eTag: 'v1'),
      ]);
      cache.upsertSnapshot(
        config.cacheKey,
        const WebDavLibraryCachedComic(
          id: comicId,
          sortIndex: 0,
          title: comicId,
          author: '',
          tags: [],
          cover: '/manga/Cached Book/cover.jpg',
          snapshot: {
            'title': comicId,
            'author': '',
            'tags': [],
            'cover': '/manga/Cached Book/cover.jpg',
            'chapters': {
              'Chapter 01': 'Chapter 01',
              'Chapter 02': 'Chapter 02',
              'Chapter 03': 'Chapter 03',
            },
            'metadataChapters': {},
            'rootImages': [],
          },
          remoteETag: 'v1',
          remoteModifiedAt: null,
        ),
      );
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: comicId, isDirectory: true, eTag: 'v1'),
      ];
      ops.dirs['/manga/Cached Book/'] = const [
        WebDavLibraryEntry(name: 'cover.jpg', isDirectory: false),
        WebDavLibraryEntry(name: 'Chapter 01', isDirectory: true),
        WebDavLibraryEntry(name: 'Chapter 02', isDirectory: true),
        WebDavLibraryEntry(name: 'Chapter 03', isDirectory: true),
        WebDavLibraryEntry(name: 'Chapter 04', isDirectory: true),
        WebDavLibraryEntry(name: 'Chapter 05', isDirectory: true),
      ];
      for (var i = 1; i <= 5; i++) {
        ops.dirs['/manga/Cached Book/Chapter 0$i/'] = const [
          WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
        ];
      }

      final sync = await WebDavLibrarySource.synchronize();
      final details = await WebDavLibrarySource.loadComicInfo(comicId);

      expect(sync.success, isTrue);
      expect(details.success, isTrue);
      expect(details.data.chapters!.allChapters, hasLength(5));
      expect(ops.readPaths, [
        '/manga/',
        '/manga/Cached Book/',
        '/manga/Cached Book/Chapter 01/',
        '/manga/Cached Book/Chapter 02/',
        '/manga/Cached Book/Chapter 03/',
        '/manga/Cached Book/Chapter 04/',
        '/manga/Cached Book/Chapter 05/',
      ]);
    },
  );

  test(
    'loadComicInfo handles Chinese comic and chapter directories from unmodifiable lists',
    () async {
      ops.dirs['/manga/猫之眼[北条司]/'] = List.unmodifiable([
        const WebDavLibraryEntry(name: '第01卷', isDirectory: true),
        const WebDavLibraryEntry(name: '第02卷', isDirectory: true),
      ]);
      ops.dirs['/manga/猫之眼[北条司]/第01卷/'] = List.unmodifiable([
        const WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
        const WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ]);
      ops.dirs['/manga/猫之眼[北条司]/第02卷/'] = List.unmodifiable([
        const WebDavLibraryEntry(name: '001.webp', isDirectory: false),
      ]);

      final result = await WebDavLibrarySource.loadComicInfo('猫之眼[北条司]');

      expect(result.success, isTrue);
      expect(result.data.cover, '/manga/猫之眼[北条司]/第01卷/001.jpg');
      expect(result.data.chapters!.allChapters, {
        '第01卷': '第01卷',
        '第02卷': '第02卷',
      });
      expect(ops.readPaths, [
        '/manga/猫之眼[北条司]/',
        '/manga/猫之眼[北条司]/第01卷/',
        '/manga/猫之眼[北条司]/第02卷/',
      ]);
    },
  );

  test('loadComicInfo uses root cover and root images when present', () async {
    ops.dirs['/manga/Cat Eye/'] = const [
      WebDavLibraryEntry(name: 'cover.jpg', isDirectory: false),
      WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
    ];

    final result = await WebDavLibrarySource.loadComicInfo('Cat Eye');

    expect(result.success, isTrue);
    expect(result.data.cover, '/manga/Cat Eye/cover.jpg');
    expect(result.data.chapters, isNull);
  });

  test('loadComicPages returns chapter image paths in reading order', () async {
    ops.dirs['/manga/Cat Eye/第01卷/'] = const [
      WebDavLibraryEntry(name: 'cover.jpg', isDirectory: false),
      WebDavLibraryEntry(name: '010.jpg', isDirectory: false),
      WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
    ];

    final result = await WebDavLibrarySource.loadComicPages('Cat Eye', '第01卷');

    expect(result.success, isTrue);
    expect(result.data, [
      '/manga/Cat Eye/第01卷/002.jpg',
      '/manga/Cat Eye/第01卷/010.jpg',
    ]);
  });

  test('loadComicPages handles Chinese directory paths', () async {
    ops.dirs['/manga/猫之眼[北条司]/第01卷/'] = List.unmodifiable([
      const WebDavLibraryEntry(name: '010.jpg', isDirectory: false),
      const WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
    ]);

    final result = await WebDavLibrarySource.loadComicPages('猫之眼[北条司]', '第01卷');

    expect(result.success, isTrue);
    expect(result.data, [
      '/manga/猫之眼[北条司]/第01卷/002.jpg',
      '/manga/猫之眼[北条司]/第01卷/010.jpg',
    ]);
  });

  test(
    'CBZ metadata enriches list and details and maps virtual chapter pages',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: '猫之眼[北条司]', isDirectory: true),
      ];
      ops.dirs['/manga/猫之眼[北条司]/'] = const [
        WebDavLibraryEntry(name: 'metadata.JSON', isDirectory: false),
        WebDavLibraryEntry(name: 'ComicInfo.xml', isDirectory: false),
        WebDavLibraryEntry(name: 'cover.jpg', isDirectory: false),
        WebDavLibraryEntry(name: '0004.jpg', isDirectory: false),
        WebDavLibraryEntry(name: '0002.jpg', isDirectory: false),
        WebDavLibraryEntry(name: '0001.jpg', isDirectory: false),
        WebDavLibraryEntry(name: '0003.jpg', isDirectory: false),
      ];
      ops.textFiles['/manga/猫之眼[北条司]/metadata.JSON'] = jsonEncode({
        'title': '猫之眼',
        'author': '北条司',
        'tags': ['动作', '漫画'],
        'description': '一位怪盗与刑警之间的故事。',
        'chapters': [
          {'title': '第01卷', 'start': 1, 'end': 2},
          {'title': '第02卷', 'start': 3, 'end': 4},
        ],
      });

      await WebDavLibrarySource.loadComics(1);
      await WebDavLibrarySource.synchronize();
      final comics = await WebDavLibrarySource.loadComics(1);
      final details = await WebDavLibrarySource.loadComicInfo('猫之眼[北条司]');
      final pages = await WebDavLibrarySource.loadComicPages(
        '猫之眼[北条司]',
        '__cbz_range_1',
      );

      expect(comics.success, isTrue);
      expect(comics.data.single.title, '猫之眼');
      expect(comics.data.single.subtitle, isNull);
      expect(comics.data.single.tags, ['动作', '漫画']);
      expect(comics.data.single.cover, '/manga/猫之眼[北条司]/cover.jpg');
      expect(details.success, isTrue);
      expect(details.data.title, '猫之眼');
      expect(details.data.subTitle, isNull);
      expect(details.data.description, '一位怪盗与刑警之间的故事。');
      expect(details.data.tags, {
        '作者': ['北条司'],
        '标签': ['动作', '漫画'],
      });
      expect(details.data.chapters!.allChapters, {
        '__cbz_range_0': '第01卷',
        '__cbz_range_1': '第02卷',
      });
      expect(pages.success, isTrue);
      expect(pages.data, [
        '/manga/猫之眼[北条司]/0003.jpg',
        '/manga/猫之眼[北条司]/0004.jpg',
      ]);
      expect(ops.textReadPaths, ['/manga/猫之眼[北条司]/metadata.JSON']);
    },
  );

  test(
    'CBZ metadata without chapters keeps root pages as one chapter',
    () async {
      ops.dirs['/manga/Flat Book/'] = const [
        WebDavLibraryEntry(name: 'metadata.json', isDirectory: false),
        WebDavLibraryEntry(name: '0002.webp', isDirectory: false),
        WebDavLibraryEntry(name: '0001.webp', isDirectory: false),
      ];
      ops.textFiles['/manga/Flat Book/metadata.json'] = jsonEncode({
        'title': 'Flat Export',
        'author': '',
        'tags': <String>[],
        'chapters': null,
      });

      final details = await WebDavLibrarySource.loadComicInfo('Flat Book');
      final pages = await WebDavLibrarySource.loadComicPages('Flat Book', null);

      expect(details.success, isTrue);
      expect(details.data.title, 'Flat Export');
      expect(details.data.chapters, isNull);
      expect(pages.success, isTrue);
      expect(pages.data, [
        '/manga/Flat Book/0001.webp',
        '/manga/Flat Book/0002.webp',
      ]);
    },
  );

  test('malformed CBZ metadata falls back to folder inference', () async {
    ops.dirs['/manga/Broken Book/'] = const [
      WebDavLibraryEntry(name: 'metadata.json', isDirectory: false),
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    ops.textFiles['/manga/Broken Book/metadata.json'] = '{broken';

    final details = await WebDavLibrarySource.loadComicInfo('Broken Book');
    final pages = await WebDavLibrarySource.loadComicPages(
      'Broken Book',
      WebDavLibrarySource.rootChapterId,
    );

    expect(details.success, isTrue);
    expect(details.data.title, 'Broken Book');
    expect(details.data.chapters, isNull);
    expect(pages.success, isTrue);
    expect(pages.data, ['/manga/Broken Book/001.jpg']);
  });

  for (final invalidCase in <String, List<Map<String, Object>>>{
    'out-of-range': [
      {'title': 'Chapter 1', 'start': 1, 'end': 3},
    ],
    'overlapping': [
      {'title': 'Chapter 1', 'start': 1, 'end': 2},
      {'title': 'Chapter 2', 'start': 2, 'end': 2},
    ],
    'reversed': [
      {'title': 'Chapter 1', 'start': 2, 'end': 1},
    ],
  }.entries) {
    test(
      '${invalidCase.key} CBZ chapter ranges fall back to root pages',
      () async {
        ops.dirs['/manga/Invalid Book/'] = const [
          WebDavLibraryEntry(name: 'metadata.json', isDirectory: false),
          WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
          WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
        ];
        ops.textFiles['/manga/Invalid Book/metadata.json'] = jsonEncode({
          'title': 'Must Not Replace Folder Name',
          'author': 'Author',
          'tags': ['tag'],
          'chapters': invalidCase.value,
        });

        final details = await WebDavLibrarySource.loadComicInfo('Invalid Book');
        final pages = await WebDavLibrarySource.loadComicPages(
          'Invalid Book',
          null,
        );

        expect(details.success, isTrue);
        expect(details.data.title, 'Invalid Book');
        expect(details.data.chapters, isNull);
        expect(pages.success, isTrue);
        expect(pages.data, [
          '/manga/Invalid Book/001.jpg',
          '/manga/Invalid Book/002.jpg',
        ]);
      },
    );
  }

  test(
    'getImageLoadingConfig builds encoded URL and basic auth header',
    () async {
      final config = await WebDavLibrarySource.getImageLoadingConfig(
        '/manga/Cat Eye/第01卷/001.jpg',
        'Cat Eye',
        '第01卷',
      );

      expect(
        config['url'],
        'https://example.com/dav/manga/Cat%20Eye/%E7%AC%AC01%E5%8D%B7/001.jpg',
      );
      expect(config['headers'], {'authorization': 'Basic dXNlcjpwYXNz'});
    },
  );
  test('missing metadata is scraped and written back to WebDAV', () async {
    ops.dirs['/manga/'] = const [
      WebDavLibraryEntry(name: 'Cat Eye[Tsukasa Hojo]', isDirectory: true),
    ];
    ops.dirs['/manga/Cat Eye[Tsukasa Hojo]/'] = const [
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    final scrapedTitles = <String>[];
    WebDavLibrarySource.configureMetadataScraper((directoryTitle) async {
      scrapedTitles.add(directoryTitle);
      return const ComicMetaData(
        title: 'Cat Eye',
        author: 'Tsukasa Hojo',
        tags: ['Action'],
        description: 'A trio of sisters run a café by day.',
        bangumiSubjectId: 123,
      );
    });

    final sync = await WebDavLibrarySource.synchronize();
    final comics = await WebDavLibrarySource.loadComics(1);
    final written = jsonDecode(
      ops.writtenTexts['/manga/Cat Eye[Tsukasa Hojo]/metadata.json']!,
    );

    expect(sync.success, isTrue);
    expect(scrapedTitles, ['Cat Eye[Tsukasa Hojo]']);
    expect(written, {
      'title': 'Cat Eye',
      'author': 'Tsukasa Hojo',
      'tags': ['Action'],
      'description': 'A trio of sisters run a café by day.',
      'chapters': null,
      'bangumiSubjectId': 123,
    });
    expect(ops.writeRequests.single.createOnly, isTrue);
    expect(comics.data.single.title, 'Cat Eye');
    expect(comics.data.single.subtitle, isNull);
  });

  test(
    'a later Bangumi connection scrapes an unchanged cached comic',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Book', isDirectory: true, eTag: 'v1'),
      ];
      ops.dirs['/manga/Book/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      var enabled = false;
      var scrapeCalls = 0;
      WebDavLibrarySource.configureMetadataScraper((_) async {
        scrapeCalls++;
        return const ComicMetaData(
          title: 'Matched book',
          author: 'Author',
          tags: [],
          bangumiSubjectId: 321,
        );
      }, isEnabled: () => enabled);
      await WebDavLibrarySource.synchronize();
      enabled = true;

      final sync = await WebDavLibrarySource.synchronize();

      expect(sync.success, isTrue);
      expect(scrapeCalls, 1);
      expect(ops.writtenTexts, contains('/manga/Book/metadata.json'));
    },
  );

  test('existing metadata is never replaced by automatic scraping', () async {
    ops.dirs['/manga/Book/'] = const [
      WebDavLibraryEntry(name: 'metadata.json', isDirectory: false),
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    ops.textFiles['/manga/Book/metadata.json'] = jsonEncode({
      'title': 'Existing title',
      'author': 'Existing author',
      'tags': ['Existing tag'],
      'chapters': null,
    });
    var scrapeCalls = 0;
    WebDavLibrarySource.configureMetadataScraper((_) async {
      scrapeCalls++;
      return const ComicMetaData(
        title: 'Replacement',
        author: 'Replacement',
        tags: [],
        bangumiSubjectId: 456,
      );
    });

    final details = await WebDavLibrarySource.loadComicInfo('Book');

    expect(details.success, isTrue);
    expect(details.data.title, 'Existing title');
    expect(scrapeCalls, 0);
    expect(ops.writtenTexts, isEmpty);
  });

  test('manual metadata writes preserve existing chapter ranges', () async {
    ops.dirs['/manga/Flat Book/'] = const [
      WebDavLibraryEntry(name: 'metadata.JSON', isDirectory: false),
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
    ];
    ops.textFiles['/manga/Flat Book/metadata.JSON'] = jsonEncode({
      'title': 'Old title',
      'author': 'Old author',
      'tags': ['Old tag'],
      'description': 'Existing description',
      'chapters': [
        {'title': 'Volume 1', 'start': 1, 'end': 2},
      ],
    });

    await WebDavLibrarySource.writeMetadata(
      'Flat Book',
      const ComicMetaData(
        title: 'Bangumi title',
        author: 'Bangumi author',
        tags: ['Bangumi tag'],
        bangumiSubjectId: 789,
      ),
    );
    final written = jsonDecode(
      ops.writtenTexts['/manga/Flat Book/metadata.JSON']!,
    );

    expect(written, {
      'title': 'Bangumi title',
      'author': 'Bangumi author',
      'tags': ['Bangumi tag'],
      'description': '',
      'chapters': [
        {'title': 'Volume 1', 'start': 1, 'end': 2},
      ],
      'bangumiSubjectId': 789,
    });
    final details = await WebDavLibrarySource.loadComicInfo('Flat Book');
    expect(details.data.title, 'Bangumi title');
    expect(details.data.subTitle, isNull);
    expect(details.data.description, '');
    expect(details.data.externalIds, {'bangumi': '789'});
    expect(details.data.tags, {
      '作者': ['Bangumi author'],
      '标签': ['Bangumi tag'],
    });
  });

  test('manual metadata merge retries an ETag conflict', () async {
    const path = '/manga/Flat Book/metadata.json';
    ops.dirs['/manga/Flat Book/'] = const [
      WebDavLibraryEntry(name: 'metadata.json', isDirectory: false),
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
    ];
    ops.textFiles[path] = jsonEncode({
      'title': 'Old',
      'author': 'Old',
      'tags': ['Old'],
      'chapters': [
        {'title': 'Old chapter', 'start': 1, 'end': 1},
      ],
      'extension': {'preserve': true},
    });
    ops.textETags[path] = '"1"';
    ops.beforeWrite = (writtenPath, writeNumber) {
      if (writtenPath != path || writeNumber != 1) return;
      ops.textFiles[path] = jsonEncode({
        'title': 'Concurrent',
        'author': 'Concurrent',
        'tags': ['Concurrent'],
        'chapters': [
          {'title': 'Concurrent chapter', 'start': 1, 'end': 2},
        ],
        'extension': {'preserve': true},
      });
      ops.textETags[path] = '"2"';
    };

    await WebDavLibrarySource.writeMetadata(
      'Flat Book',
      const ComicMetaData(
        title: 'Selected subject',
        author: '',
        tags: [],
        description: '',
        bangumiSubjectId: 42,
      ),
    );

    final written = jsonDecode(ops.writtenTexts[path]!) as Map;
    expect(ops.writeRequests.map((request) => request.ifMatch), ['"1"', '"2"']);
    expect(written['title'], 'Selected subject');
    expect(written['author'], '');
    expect(written['tags'], isEmpty);
    expect(written['description'], '');
    expect(written['chapters'], [
      {'title': 'Concurrent chapter', 'start': 1, 'end': 2},
    ]);
    expect(written['extension'], {'preserve': true});
  });

  test('weak ETag falls back to Last-Modified for metadata updates', () async {
    const path = '/manga/Book/metadata.json';
    const modifiedAt = 1700000000000;
    ops.dirs['/manga/Book/'] = const [
      WebDavLibraryEntry(name: 'metadata.json', isDirectory: false),
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    ops.textFiles[path] = jsonEncode({
      'title': 'Existing',
      'author': '',
      'tags': <String>[],
      'chapters': null,
    });
    ops.textETags[path] = 'w/"1"';
    ops.textModifiedAt[path] = modifiedAt;

    await WebDavLibrarySource.writeMetadata(
      'Book',
      const ComicMetaData(
        title: 'Replacement',
        author: '',
        tags: [],
        bangumiSubjectId: 43,
      ),
    );

    expect(ops.writeRequests.single.ifMatch, isNull);
    expect(ops.writeRequests.single.ifUnmodifiedSince, modifiedAt);
  });

  test(
    'weak ETag without Last-Modified safely rejects metadata update',
    () async {
      const path = '/manga/Book/metadata.json';
      ops.dirs['/manga/Book/'] = const [
        WebDavLibraryEntry(name: 'metadata.json', isDirectory: false),
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.textFiles[path] = jsonEncode({
        'title': 'Existing',
        'author': '',
        'tags': <String>[],
        'chapters': null,
      });
      ops.textETags[path] = 'W/"1"';

      await expectLater(
        WebDavLibrarySource.writeMetadata(
          'Book',
          const ComicMetaData(
            title: 'Replacement',
            author: '',
            tags: [],
            bangumiSubjectId: 44,
          ),
        ),
        throwsA(isA<WebDavUnsupportedException>()),
      );

      expect(ops.writeRequests, isEmpty);
    },
  );

  test('metadata merge salvages valid chapters from invalid fields', () async {
    const path = '/manga/Broken Book/metadata.json';
    ops.dirs['/manga/Broken Book/'] = const [
      WebDavLibraryEntry(name: 'metadata.json', isDirectory: false),
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
    ];
    ops.textFiles[path] = jsonEncode({
      'title': 7,
      'author': false,
      'tags': 'invalid',
      'chapters': [
        {'title': 'Volume 1', 'start': 1, 'end': 2},
      ],
    });

    await WebDavLibrarySource.writeMetadata(
      'Broken Book',
      const ComicMetaData(
        title: 'Recovered',
        author: 'Author',
        tags: ['Tag'],
        bangumiSubjectId: 43,
      ),
    );

    final written = jsonDecode(ops.writtenTexts[path]!) as Map;
    expect(written['chapters'], [
      {'title': 'Volume 1', 'start': 1, 'end': 2},
    ]);
    expect(written['title'], 'Recovered');
    expect(written['bangumiSubjectId'], 43);
  });

  test('unsafe validatorless updates are retained as pending', () async {
    const path = '/manga/Book/metadata.json';
    ops.dirs['/manga/Book/'] = const [
      WebDavLibraryEntry(name: 'metadata.json', isDirectory: false),
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    ops.textFiles[path] = jsonEncode({
      'title': 'Existing',
      'author': '',
      'tags': <String>[],
      'chapters': null,
    });
    ops.validatorlessPaths.add(path);

    await expectLater(
      WebDavLibrarySource.writeMetadata(
        'Book',
        const ComicMetaData(
          title: 'Replacement',
          author: '',
          tags: [],
          bangumiSubjectId: 44,
        ),
      ),
      throwsA(isA<WebDavUnsupportedException>()),
    );

    final pending = WebDavLibrarySource.metadataPendingStatuses.single;
    expect(pending.comicId, 'Book');
    expect(pending.subjectId, 44);
    expect(pending.attempts, 1);
    expect(pending.failure, WebDavMetadataPendingFailure.unsupported);
    expect(ops.writtenTexts, isEmpty);
  });

  test(
    'transient metadata failures can be retried from the local queue',
    () async {
      const path = '/manga/Book/metadata.json';
      ops.dirs['/manga/Book/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.beforeWrite = (writtenPath, writeNumber) {
        if (writtenPath == path && writeNumber == 1) {
          throw WebDavTransientException(path);
        }
      };

      await expectLater(
        WebDavLibrarySource.writeMetadata(
          'Book',
          const ComicMetaData(
            title: 'Book',
            author: '',
            tags: [],
            bangumiSubjectId: 45,
          ),
        ),
        throwsA(isA<WebDavTransientException>()),
      );
      expect(
        WebDavLibrarySource.metadataPendingStatuses.single.failure,
        WebDavMetadataPendingFailure.transient,
      );

      ops.beforeWrite = null;
      await WebDavLibrarySource.retryPendingMetadata(force: true);

      expect(WebDavLibrarySource.metadataPendingStatuses, isEmpty);
      expect(ops.writtenTexts, contains(path));
    },
  );

  test(
    'metadata write guard rejects a stale binding without queuing it',
    () async {
      ops.dirs['/manga/Book/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      WebDavLibrarySource.configureMetadataWriteGuard((_, _, _) => false);

      await expectLater(
        WebDavLibrarySource.writeMetadata(
          'Book',
          const ComicMetaData(
            title: 'Book',
            author: '',
            tags: [],
            bangumiSubjectId: 46,
          ),
        ),
        throwsA(isA<WebDavMetadataWriteRejectedException>()),
      );

      expect(WebDavLibrarySource.metadataPendingStatuses, isEmpty);
      expect(ops.writeRequests, isEmpty);
    },
  );

  test(
    'nested unmarked comic directories are discovered conservatively',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Category', isDirectory: true),
      ];
      ops.dirs['/manga/Category/'] = const [
        WebDavLibraryEntry(name: 'Author', isDirectory: true),
      ];
      ops.dirs['/manga/Category/Author/'] = const [
        WebDavLibraryEntry(name: 'Book', isDirectory: true),
      ];
      ops.dirs['/manga/Category/Author/Book/'] = const [
        WebDavLibraryEntry(name: '第01卷', isDirectory: true),
        WebDavLibraryEntry(name: '第02卷', isDirectory: true),
      ];
      ops.dirs['/manga/Category/Author/Book/第01卷/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Category/Author/Book/第02卷/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];

      await WebDavLibrarySource.synchronize();
      final comics = await WebDavLibrarySource.loadComics(1);

      expect(comics.data.map((comic) => comic.id), ['Category/Author/Book']);
    },
  );

  test(
    'chapters with non-standard or Chinese volume names are treated as chapters instead of individual comics',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: '猫之眼', isDirectory: true),
      ];
      ops.dirs['/manga/猫之眼/'] = const [
        WebDavLibraryEntry(name: '第一卷', isDirectory: true),
        WebDavLibraryEntry(name: '第二卷', isDirectory: true),
        WebDavLibraryEntry(name: '番外合集', isDirectory: true),
      ];
      ops.dirs['/manga/猫之眼/第一卷/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
        WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/猫之眼/第二卷/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/猫之眼/番外合集/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];

      await WebDavLibrarySource.synchronize();
      final comics = await WebDavLibrarySource.loadComics(1);
      final details = await WebDavLibrarySource.loadComicInfo('猫之眼');

      expect(comics.data.map((comic) => comic.id), ['猫之眼']);
      expect(details.data.chapters!.allChapters, {
        '第一卷': '第一卷',
        '第二卷': '第二卷',
        '番外合集': '番外合集',
      });
    },
  );

  test(
    'multi-level category directory discovers child comics without classifying category as comic',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: '少年漫画', isDirectory: true),
      ];
      ops.dirs['/manga/少年漫画/'] = const [
        WebDavLibraryEntry(name: '猫之眼', isDirectory: true),
        WebDavLibraryEntry(name: '城市猎人', isDirectory: true),
      ];
      ops.dirs['/manga/少年漫画/猫之眼/'] = const [
        WebDavLibraryEntry(name: '第一卷', isDirectory: true),
        WebDavLibraryEntry(name: '第二卷', isDirectory: true),
      ];
      ops.dirs['/manga/少年漫画/猫之眼/第一卷/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/少年漫画/猫之眼/第二卷/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/少年漫画/城市猎人/'] = const [
        WebDavLibraryEntry(name: '第一卷', isDirectory: true),
        WebDavLibraryEntry(name: '第二卷', isDirectory: true),
      ];
      ops.dirs['/manga/少年漫画/城市猎人/第一卷/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/少年漫画/城市猎人/第二卷/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];

      await WebDavLibrarySource.synchronize();
      final comics = await WebDavLibrarySource.loadComics(1);
      expect(comics.data.map((comic) => comic.id), ['少年漫画/城市猎人', '少年漫画/猫之眼']);
    },
  );

  test(
    'empty child directories do not prevent parent comic from being discovered',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: '猫之眼', isDirectory: true),
      ];
      ops.dirs['/manga/猫之眼/'] = const [
        WebDavLibraryEntry(name: '第一卷', isDirectory: true),
        WebDavLibraryEntry(name: '第二卷', isDirectory: true),
        WebDavLibraryEntry(name: '临时文件', isDirectory: true),
      ];
      ops.dirs['/manga/猫之眼/第一卷/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/猫之眼/第二卷/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/猫之眼/临时文件/'] = const [];

      await WebDavLibrarySource.synchronize();
      final comics = await WebDavLibrarySource.loadComics(1);
      expect(comics.data.map((comic) => comic.id), ['猫之眼']);
    },
  );

  test(
    'flat category containing multiple leaf comic books is not merged into one comic',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: '少年漫画', isDirectory: true),
      ];
      ops.dirs['/manga/少年漫画/'] = const [
        WebDavLibraryEntry(name: '猫之眼', isDirectory: true),
        WebDavLibraryEntry(name: '城市猎人', isDirectory: true),
      ];
      ops.dirs['/manga/少年漫画/猫之眼/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
        WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/少年漫画/城市猎人/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
        WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
      ];

      await WebDavLibrarySource.synchronize();
      final comics = await WebDavLibrarySource.loadComics(1);
      expect(comics.data.map((comic) => comic.id), ['少年漫画/城市猎人', '少年漫画/猫之眼']);
    },
  );

  test(
    'child metadata takes precedence over chapter-like directory names',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Category', isDirectory: true),
      ];
      ops.dirs['/manga/Category/'] = const [
        WebDavLibraryEntry(name: '01', isDirectory: true),
        WebDavLibraryEntry(name: '02', isDirectory: true),
      ];
      ops.dirs['/manga/Category/01/'] = const [
        WebDavLibraryEntry(name: 'metadata.json', isDirectory: false),
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Category/02/'] = const [
        WebDavLibraryEntry(name: 'metadata.json', isDirectory: false),
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];

      await WebDavLibrarySource.synchronize();
      final comics = await WebDavLibrarySource.loadComics(1);
      expect(comics.data.map((comic) => comic.id), [
        'Category/01',
        'Category/02',
      ]);
    },
  );

  test(
    'empty child directory is excluded from chapter list and details',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: '猫之眼', isDirectory: true),
      ];
      ops.dirs['/manga/猫之眼/'] = const [
        WebDavLibraryEntry(name: '第一卷', isDirectory: true),
        WebDavLibraryEntry(name: '第二卷', isDirectory: true),
        WebDavLibraryEntry(name: '临时文件', isDirectory: true),
      ];
      ops.dirs['/manga/猫之眼/第一卷/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/猫之眼/第二卷/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/猫之眼/临时文件/'] = const [];

      await WebDavLibrarySource.synchronize();
      final details = await WebDavLibrarySource.loadComicInfo('猫之眼');
      expect(details.data.chapters!.allChapters.keys, ['第一卷', '第二卷']);
    },
  );

  test(
    'transient child directory read failure does not guess category as comic',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Category', isDirectory: true),
      ];
      ops.dirs['/manga/Category/'] = const [
        WebDavLibraryEntry(name: 'Book A', isDirectory: true),
        WebDavLibraryEntry(name: 'Book B', isDirectory: true),
      ];
      ops.dirs['/manga/Category/Book A/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.errors['/manga/Category/Book B/'] = StateError(
        'transient network failure',
      );

      final sync = await WebDavLibrarySource.synchronize();
      expect(sync.success, isFalse);
    },
  );

  test(
    'discovery depth limit fails closed without classifying ancestor as comic',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'L1', isDirectory: true),
      ];
      var current = '/manga/L1/';
      for (var index = 2; index <= 9; index++) {
        ops.dirs[current] = [
          WebDavLibraryEntry(name: 'L$index', isDirectory: true),
        ];
        current = '${current}L$index/';
      }
      ops.dirs[current] = const [
        WebDavLibraryEntry(name: 'Book', isDirectory: true),
      ];
      ops.dirs['${current}Book/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];

      final sync = await WebDavLibrarySource.synchronize();
      expect(sync.success, isFalse);

      final comics = await WebDavLibrarySource.loadComics(1);
      expect(comics.data.map((c) => c.id), isNot(contains('L1')));
    },
  );

  test(
    'discovery directory limit fails without committing a partial index',
    () async {
      WebDavLibrarySource.discoveryDirectoryLimitOverride = 3;
      addTearDown(() {
        WebDavLibrarySource.discoveryDirectoryLimitOverride = null;
      });

      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'A', isDirectory: true),
        WebDavLibraryEntry(name: 'B', isDirectory: true),
        WebDavLibraryEntry(name: 'C', isDirectory: true),
        WebDavLibraryEntry(name: 'D', isDirectory: true),
      ];
      ops.dirs['/manga/A/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/B/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/C/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/D/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];

      final sync = await WebDavLibrarySource.synchronize();
      expect(sync.success, isFalse);

      final comics = await WebDavLibrarySource.loadComics(1);
      expect(comics.data, isEmpty);
    },
  );

  test(
    'top-level directory read failure preserves the previous successful index',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Category', isDirectory: true),
      ];
      ops.dirs['/manga/Category/'] = const [
        WebDavLibraryEntry(name: 'Book A', isDirectory: true),
        WebDavLibraryEntry(name: 'Book B', isDirectory: true),
      ];
      ops.dirs['/manga/Category/Book A/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Category/Book B/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];

      final firstSync = await WebDavLibrarySource.synchronize();
      expect(firstSync.success, isTrue);
      final firstComics = await WebDavLibrarySource.loadComics(1);
      expect(firstComics.data.map((c) => c.id), [
        'Category/Book A',
        'Category/Book B',
      ]);

      ops.errors['/manga/Category/'] = StateError('temporary connection error');
      final secondSync = await WebDavLibrarySource.synchronize(force: true);
      expect(secondSync.success, isFalse);

      final secondComics = await WebDavLibrarySource.loadComics(1);
      expect(secondComics.data.map((c) => c.id), [
        'Category/Book A',
        'Category/Book B',
      ]);
    },
  );

  test(
    'metadata comic excludes empty child directories from chapters',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Comic', isDirectory: true),
      ];
      ops.dirs['/manga/Comic/'] = const [
        WebDavLibraryEntry(name: 'metadata.json', isDirectory: false),
        WebDavLibraryEntry(name: '第一卷', isDirectory: true),
        WebDavLibraryEntry(name: '临时文件', isDirectory: true),
      ];
      ops.dirs['/manga/Comic/第一卷/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Comic/临时文件/'] = const [];
      ops.textFiles['/manga/Comic/metadata.json'] = jsonEncode({
        'title': 'Comic',
      });

      final sync = await WebDavLibrarySource.synchronize();
      expect(sync.success, isTrue);

      final details = await WebDavLibrarySource.loadComicInfo('Comic');
      expect(details.data.chapters!.allChapters.keys, ['第一卷']);
    },
  );

  test(
    'root-image comic excludes empty child directories from chapters',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Comic', isDirectory: true),
      ];
      ops.dirs['/manga/Comic/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
        WebDavLibraryEntry(name: 'Chapter 1', isDirectory: true),
        WebDavLibraryEntry(name: 'temp', isDirectory: true),
      ];
      ops.dirs['/manga/Comic/Chapter 1/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Comic/temp/'] = const [];

      final sync = await WebDavLibrarySource.synchronize();
      expect(sync.success, isTrue);

      final details = await WebDavLibrarySource.loadComicInfo('Comic');
      expect(details.data.chapters!.allChapters.keys, [
        'Chapter 1',
        '__root__',
      ]);
    },
  );

  test('empty child cover is not used as comic cover', () async {
    ops.dirs['/manga/'] = const [
      WebDavLibraryEntry(name: 'Comic', isDirectory: true),
    ];
    ops.dirs['/manga/Comic/'] = const [
      WebDavLibraryEntry(name: '第一卷', isDirectory: true),
      WebDavLibraryEntry(name: '临时文件', isDirectory: true),
    ];
    ops.dirs['/manga/Comic/第一卷/'] = const [
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    ops.dirs['/manga/Comic/临时文件/'] = const [
      WebDavLibraryEntry(name: 'cover.jpg', isDirectory: false),
    ];

    final sync = await WebDavLibrarySource.synchronize();
    expect(sync.success, isTrue);

    final details = await WebDavLibrarySource.loadComicInfo('Comic');
    expect(details.data.cover, '/manga/Comic/第一卷/001.jpg');
    expect(details.data.chapters!.allChapters.keys, ['第一卷']);
  });

  test(
    'flat category scraping targets leaf comics instead of category',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Category', isDirectory: true),
      ];
      ops.dirs['/manga/Category/'] = const [
        WebDavLibraryEntry(name: 'Book A', isDirectory: true),
        WebDavLibraryEntry(name: 'Book B', isDirectory: true),
      ];
      ops.dirs['/manga/Category/Book A/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Category/Book B/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];

      final scrapedTitles = <String>[];
      WebDavLibrarySource.configureMetadataScraper((directoryTitle) async {
        scrapedTitles.add(directoryTitle);
        return ComicMetaData(
          title: directoryTitle,
          author: 'Author',
          tags: const ['Action'],
          description: '',
        );
      });

      final sync = await WebDavLibrarySource.synchronize();
      expect(sync.success, isTrue);
      expect(scrapedTitles, ['Book A', 'Book B']);
      expect(scrapedTitles, isNot(contains('Category')));
    },
  );

  test(
    'automatic scraping targets only comic root and does not scrape or write to chapter folders',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Cat Eye[Tsukasa Hojo]', isDirectory: true),
      ];
      ops.dirs['/manga/Cat Eye[Tsukasa Hojo]/'] = const [
        WebDavLibraryEntry(name: '第一卷', isDirectory: true),
        WebDavLibraryEntry(name: '第二卷', isDirectory: true),
      ];
      ops.dirs['/manga/Cat Eye[Tsukasa Hojo]/第一卷/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Cat Eye[Tsukasa Hojo]/第二卷/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      final scrapedTitles = <String>[];
      WebDavLibrarySource.configureMetadataScraper((directoryTitle) async {
        scrapedTitles.add(directoryTitle);
        return const ComicMetaData(
          title: 'Cat Eye',
          author: 'Tsukasa Hojo',
          tags: ['Action'],
          description: 'A trio of sisters run a café by day.',
          bangumiSubjectId: 123,
        );
      });

      final sync = await WebDavLibrarySource.synchronize();
      final comics = await WebDavLibrarySource.loadComics(1);

      expect(sync.success, isTrue);
      expect(scrapedTitles, ['Cat Eye[Tsukasa Hojo]']);
      expect(ops.writtenTexts.keys, [
        '/manga/Cat Eye[Tsukasa Hojo]/metadata.json',
      ]);
      expect(comics.data.single.title, 'Cat Eye');
    },
  );

  test(
    'synchronization evicts stale chapter comics cached by previous buggy versions',
    () async {
      final config = WebDavLibraryConfig.fromSettings();
      final cache = WebDavLibraryCache.instance;
      cache.replaceDirectoryIndex(config.cacheKey, const [
        WebDavLibraryRemoteDirectory(id: 'Cat Eye/第一卷', sortIndex: 0),
        WebDavLibraryRemoteDirectory(id: 'Cat Eye/第二卷', sortIndex: 1),
      ]);
      cache.upsertSnapshot(
        config.cacheKey,
        const WebDavLibraryCachedComic(
          id: 'Cat Eye/第一卷',
          sortIndex: 0,
          title: '第一卷',
          author: '',
          tags: [],
          cover: '',
          snapshot: {
            'title': '第一卷',
            'author': '',
            'tags': [],
            'cover': '',
            'chapters': {'root': 'root'},
            'metadataChapters': {},
            'rootImages': ['001.jpg'],
          },
          remoteETag: 'v1',
          remoteModifiedAt: null,
        ),
      );

      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Cat Eye', isDirectory: true),
      ];
      ops.dirs['/manga/Cat Eye/'] = const [
        WebDavLibraryEntry(name: '第一卷', isDirectory: true),
        WebDavLibraryEntry(name: '第二卷', isDirectory: true),
      ];
      ops.dirs['/manga/Cat Eye/第一卷/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Cat Eye/第二卷/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];

      final sync = await WebDavLibrarySource.synchronize();
      final comics = await WebDavLibrarySource.loadComics(1);

      expect(sync.success, isTrue);
      expect(comics.data.map((c) => c.id), ['Cat Eye']);
      expect(cache.find(config.cacheKey, 'Cat Eye/第一卷'), isNull);
      expect(cache.find(config.cacheKey, 'Cat Eye/第二卷'), isNull);
    },
  );

  test(
    'single volume directory such as 全1卷 is recognized as chapter instead of comic',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Cat Eye', isDirectory: true),
      ];
      ops.dirs['/manga/Cat Eye/'] = const [
        WebDavLibraryEntry(name: '全1卷', isDirectory: true),
      ];
      ops.dirs['/manga/Cat Eye/全1卷/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      final scrapedTitles = <String>[];
      WebDavLibrarySource.configureMetadataScraper((directoryTitle) async {
        scrapedTitles.add(directoryTitle);
        return const ComicMetaData(
          title: 'Cat Eye',
          author: 'Tsukasa Hojo',
          tags: ['Action'],
          description: '',
        );
      });

      final sync = await WebDavLibrarySource.synchronize();
      final comics = await WebDavLibrarySource.loadComics(1);
      final details = await WebDavLibrarySource.loadComicInfo('Cat Eye');

      expect(sync.success, isTrue);
      expect(comics.data.map((c) => c.id), ['Cat Eye']);
      expect(details.data.chapters!.allChapters.keys, ['全1卷']);
      expect(scrapedTitles, ['Cat Eye']);
      expect(scrapedTitles, isNot(contains('全1卷')));
      expect(ops.writtenTexts.keys, ['/manga/Cat Eye/metadata.json']);
      expect(
        ops.writtenTexts.keys,
        isNot(contains('/manga/Cat Eye/全1卷/metadata.json')),
      );
    },
  );

  test(
    'metadata comic excludes empty chapter-named directory from chapters',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Comic', isDirectory: true),
      ];
      ops.dirs['/manga/Comic/'] = const [
        WebDavLibraryEntry(name: 'metadata.json', isDirectory: false),
        WebDavLibraryEntry(name: '第01卷', isDirectory: true),
        WebDavLibraryEntry(name: '第02卷', isDirectory: true),
      ];
      ops.dirs['/manga/Comic/第01卷/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Comic/第02卷/'] = const [];
      ops.textFiles['/manga/Comic/metadata.json'] = jsonEncode({
        'title': 'Comic',
        'author': '',
      });

      final sync = await WebDavLibrarySource.synchronize();
      expect(sync.success, isTrue);

      final details = await WebDavLibrarySource.loadComicInfo('Comic');
      expect(details.data.chapters!.allChapters.keys, ['第01卷']);
    },
  );

  test(
    'chapter with only named cover is excluded from chapters and comic cover',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Comic', isDirectory: true),
      ];
      ops.dirs['/manga/Comic/'] = const [
        WebDavLibraryEntry(name: '第01卷', isDirectory: true),
        WebDavLibraryEntry(name: '第02卷', isDirectory: true),
      ];
      ops.dirs['/manga/Comic/第01卷/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Comic/第02卷/'] = const [
        WebDavLibraryEntry(name: 'cover.jpg', isDirectory: false),
      ];

      final sync = await WebDavLibrarySource.synchronize();
      expect(sync.success, isTrue);

      final details = await WebDavLibrarySource.loadComicInfo('Comic');
      expect(details.data.chapters!.allChapters.keys, ['第01卷']);
      expect(details.data.cover, '/manga/Comic/第01卷/001.jpg');
    },
  );

  test(
    'noMatch negative scrape cache is preserved across forced sync',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Unmatched Book', isDirectory: true),
      ];
      ops.dirs['/manga/Unmatched Book/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      var scraperCalls = 0;
      WebDavLibrarySource.configureMetadataScraper((directoryTitle) async {
        scraperCalls++;
        return null;
      });

      final firstSync = await WebDavLibrarySource.synchronize();
      expect(firstSync.success, isTrue);
      expect(scraperCalls, 1);

      final secondSync = await WebDavLibrarySource.synchronize(force: true);
      expect(secondSync.success, isTrue);
      expect(scraperCalls, 1);
    },
  );

  test(
    'noMatch negative scrape cache is preserved when comic pages change',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Unmatched Book', isDirectory: true),
      ];
      ops.dirs['/manga/Unmatched Book/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false, eTag: 'p1'),
      ];
      var scraperCalls = 0;
      WebDavLibrarySource.configureMetadataScraper((directoryTitle) async {
        scraperCalls++;
        return null;
      });

      await WebDavLibrarySource.synchronize();
      expect(scraperCalls, 1);

      ops.dirs['/manga/Unmatched Book/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false, eTag: 'p1'),
        WebDavLibraryEntry(name: '002.jpg', isDirectory: false, eTag: 'p2'),
      ];

      await WebDavLibrarySource.synchronize();
      expect(scraperCalls, 1);
    },
  );

  test(
    'validatorless WebDAV comic does not loop scraper queries on subsequent syncs',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Unmatched Book', isDirectory: true),
      ];
      ops.dirs['/manga/Unmatched Book/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      var scraperCalls = 0;
      WebDavLibrarySource.configureMetadataScraper((directoryTitle) async {
        scraperCalls++;
        return null;
      });

      await WebDavLibrarySource.synchronize();
      expect(scraperCalls, 1);

      await WebDavLibrarySource.synchronize();
      expect(scraperCalls, 1);
    },
  );

  test('scraperVersion change retries an existing noMatch comic', () async {
    ops.dirs['/manga/'] = const [
      WebDavLibraryEntry(name: 'Unmatched Book', isDirectory: true),
    ];
    ops.dirs['/manga/Unmatched Book/'] = const [
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    var scraperCalls = 0;
    WebDavLibrarySource.configureMetadataScraper((directoryTitle) async {
      scraperCalls++;
      return null;
    }, scraperVersion: '1');

    await WebDavLibrarySource.synchronize();
    expect(scraperCalls, 1);

    WebDavLibrarySource.configureMetadataScraper((directoryTitle) async {
      scraperCalls++;
      return null;
    }, scraperVersion: '2');

    await WebDavLibrarySource.synchronize();
    expect(scraperCalls, 2);
  });

  test(
    'automatic scraping is skipped when scraper is disabled in settings',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Cat Eye[Tsukasa Hojo]', isDirectory: true),
      ];
      ops.dirs['/manga/Cat Eye[Tsukasa Hojo]/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      var scraperCalls = 0;
      WebDavLibrarySource.configureMetadataScraper((directoryTitle) async {
        scraperCalls++;
        return const ComicMetaData(
          title: 'Cat Eye',
          author: 'Tsukasa Hojo',
          tags: ['Action'],
          description: '',
        );
      }, isEnabled: () => false);

      final sync = await WebDavLibrarySource.synchronize();
      expect(sync.success, isTrue);
      expect(scraperCalls, 0);
      expect(ops.writtenTexts, isEmpty);
    },
  );

  test(
    'disconnected scraper records failed status instead of noMatch',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Cat Eye[Tsukasa Hojo]', isDirectory: true),
      ];
      ops.dirs['/manga/Cat Eye[Tsukasa Hojo]/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      WebDavLibrarySource.configureMetadataScraper((directoryTitle) async {
        throw StateError('Bangumi is not connected');
      });

      final sync = await WebDavLibrarySource.synchronize();
      expect(sync.success, isTrue);

      final config = WebDavLibraryConfig.fromSettings();
      final cached = WebDavLibraryCache.instance.find(
        config.cacheKey,
        'Cat Eye[Tsukasa Hojo]',
      );
      expect(cached, isNotNull);
      final snapshot = cached!.snapshot!;
      expect(snapshot['metadataScrapeStatus'], 'failed');
      expect(snapshot['metadataScrapeRetryAt'], isNotNull);
      expect(
        snapshot['metadataScrapeError'],
        contains('Bangumi is not connected'),
      );
    },
  );

  test('normal unmatching scraper records noMatch without retryAt', () async {
    ops.dirs['/manga/'] = const [
      WebDavLibraryEntry(name: 'Cat Eye[Tsukasa Hojo]', isDirectory: true),
    ];
    ops.dirs['/manga/Cat Eye[Tsukasa Hojo]/'] = const [
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    WebDavLibrarySource.configureMetadataScraper((directoryTitle) async {
      return null;
    });

    final sync = await WebDavLibrarySource.synchronize();
    expect(sync.success, isTrue);

    final config = WebDavLibraryConfig.fromSettings();
    final cached = WebDavLibraryCache.instance.find(
      config.cacheKey,
      'Cat Eye[Tsukasa Hojo]',
    );
    expect(cached, isNotNull);
    final snapshot = cached!.snapshot!;
    expect(snapshot['metadataScrapeStatus'], 'noMatch');
    expect(snapshot['metadataScrapeRetryAt'], isNull);
    expect(snapshot['metadataScrapeError'], isNull);
  });

  test(
    'secondary gate skips scraper and sets pending if disabled before execution',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Cat Eye[Tsukasa Hojo]', isDirectory: true),
      ];
      ops.dirs['/manga/Cat Eye[Tsukasa Hojo]/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      var calls = 0;
      var enabled = true;
      WebDavLibrarySource.configureMetadataScraper(
        (directoryTitle) async {
          calls++;
          return null;
        },
        isEnabled: () {
          final current = enabled;
          enabled = false;
          return current;
        },
      );

      final sync = await WebDavLibrarySource.synchronize();
      expect(sync.success, isTrue);
      expect(calls, 0);

      final config = WebDavLibraryConfig.fromSettings();
      final cached = WebDavLibraryCache.instance.find(
        config.cacheKey,
        'Cat Eye[Tsukasa Hojo]',
      );
      expect(cached, isNotNull);
      expect(cached!.snapshot!['metadataScrapeStatus'], 'pending');
    },
  );

  test('failed scraper does not retry before retryAt arrives', () async {
    var simulatedTime = 1000000000000;
    WebDavLibrarySource.metadataNowProvider = () => simulatedTime;

    ops.dirs['/manga/'] = const [
      WebDavLibraryEntry(name: 'Cat Eye[Tsukasa Hojo]', isDirectory: true),
    ];
    ops.dirs['/manga/Cat Eye[Tsukasa Hojo]/'] = const [
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    var scraperCalls = 0;
    WebDavLibrarySource.configureMetadataScraper((directoryTitle) async {
      scraperCalls++;
      throw StateError('Bangumi is not connected');
    });

    final firstSync = await WebDavLibrarySource.synchronize();
    expect(firstSync.success, isTrue);
    expect(scraperCalls, 1);

    // Advance time by 14 minutes (< 15 minutes retryAt)
    simulatedTime += const Duration(minutes: 14).inMilliseconds;

    final secondSync = await WebDavLibrarySource.synchronize();
    expect(secondSync.success, isTrue);
    expect(scraperCalls, 1);
  });

  test('failed scraper retries after retryAt has elapsed', () async {
    var simulatedTime = 1000000000000;
    WebDavLibrarySource.metadataNowProvider = () => simulatedTime;

    ops.dirs['/manga/'] = const [
      WebDavLibraryEntry(name: 'Cat Eye[Tsukasa Hojo]', isDirectory: true),
    ];
    ops.dirs['/manga/Cat Eye[Tsukasa Hojo]/'] = const [
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    var scraperCalls = 0;
    WebDavLibrarySource.configureMetadataScraper((directoryTitle) async {
      scraperCalls++;
      throw StateError('Bangumi is not connected');
    });

    final firstSync = await WebDavLibrarySource.synchronize();
    expect(firstSync.success, isTrue);
    expect(scraperCalls, 1);

    // Advance time by 15 minutes (>= 15 minutes retryAt)
    simulatedTime += const Duration(minutes: 15).inMilliseconds;

    final secondSync = await WebDavLibrarySource.synchronize();
    expect(secondSync.success, isTrue);
    expect(scraperCalls, 2);
  });

  test(
    'child metadata validators invalidate an unchanged parent snapshot',
    () async {
      const path = '/manga/Book/metadata.json';
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Book', isDirectory: true, eTag: 'parent'),
      ];
      ops.dirs['/manga/Book/'] = const [
        WebDavLibraryEntry(
          name: 'metadata.json',
          isDirectory: false,
          eTag: 'metadata-1',
        ),
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false, eTag: 'page-1'),
      ];
      ops.textFiles[path] = jsonEncode({
        'title': 'Before',
        'author': '',
        'tags': <String>[],
        'chapters': null,
      });
      await WebDavLibrarySource.synchronize();

      ops.dirs['/manga/Book/'] = const [
        WebDavLibraryEntry(
          name: 'metadata.json',
          isDirectory: false,
          eTag: 'metadata-2',
        ),
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false, eTag: 'page-1'),
      ];
      ops.textFiles[path] = jsonEncode({
        'title': 'After',
        'author': '',
        'tags': <String>[],
        'chapters': null,
      });
      await WebDavLibrarySource.synchronize();
      final comics = await WebDavLibrarySource.loadComics(1);

      expect(comics.data.single.title, 'After');
    },
  );

  test('a child without validators keeps its snapshot refreshable', () async {
    const path = '/manga/Book/metadata.json';
    ops.dirs['/manga/'] = const [
      WebDavLibraryEntry(name: 'Book', isDirectory: true, eTag: 'parent'),
    ];
    ops.dirs['/manga/Book/'] = const [
      WebDavLibraryEntry(
        name: 'metadata.json',
        isDirectory: false,
        eTag: 'metadata',
      ),
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    ops.textFiles[path] = jsonEncode({
      'title': 'Book',
      'author': '',
      'tags': <String>[],
      'chapters': null,
    });
    await WebDavLibrarySource.synchronize();

    await WebDavLibrarySource.synchronize();

    expect(WebDavLibrarySource.syncStatus.value.total, 1);
  });

  test(
    'structured scrape state retries only after scraper version changes',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Book', isDirectory: true),
      ];
      ops.dirs['/manga/Book/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false, eTag: 'page-1'),
      ];
      var calls = 0;
      WebDavLibrarySource.configureMetadataScraper((_) async {
        calls++;
        return null;
      }, scraperVersion: '1');
      await WebDavLibrarySource.synchronize();
      final config = WebDavLibraryConfig.fromSettings();
      final firstSnapshot = WebDavLibraryCache.instance
          .find(config.cacheKey, 'Book')!
          .snapshot!;
      expect(firstSnapshot['metadataScrapeStatus'], 'noMatch');
      expect(firstSnapshot['metadataScraperVersion'], '1');

      WebDavLibrarySource.configureMetadataScraper((_) async {
        calls++;
        return const ComicMetaData(
          title: 'Matched',
          author: '',
          tags: [],
          bangumiSubjectId: 47,
        );
      }, scraperVersion: '1');
      await WebDavLibrarySource.synchronize();
      expect(calls, 1);

      WebDavLibrarySource.configureMetadataScraper((_) async {
        calls++;
        return const ComicMetaData(
          title: 'Matched',
          author: '',
          tags: [],
          bangumiSubjectId: 47,
        );
      }, scraperVersion: '2');
      await WebDavLibrarySource.synchronize();

      expect(calls, 2);
      expect(ops.writtenTexts, contains('/manga/Book/metadata.json'));
    },
  );

  test('failed scrape stores attempt, retry, version, and error', () async {
    ops.dirs['/manga/'] = const [
      WebDavLibraryEntry(name: 'Book', isDirectory: true),
    ];
    ops.dirs['/manga/Book/'] = const [
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false, eTag: 'page-1'),
    ];
    WebDavLibrarySource.configureMetadataScraper(
      (_) => throw StateError('scraper unavailable'),
      scraperVersion: 'rules-2',
    );

    await WebDavLibrarySource.synchronize();

    final config = WebDavLibraryConfig.fromSettings();
    final snapshot = WebDavLibraryCache.instance
        .find(config.cacheKey, 'Book')!
        .snapshot!;
    final attemptedAt = snapshot['metadataScrapeAttemptedAt'];
    final retryAt = snapshot['metadataScrapeRetryAt'];
    expect(snapshot['metadataScrapeStatus'], 'failed');
    expect(snapshot['metadataScraperVersion'], 'rules-2');
    expect(attemptedAt, isA<int>());
    expect(retryAt, isA<int>());
    expect(retryAt as int, greaterThan(attemptedAt as int));
    expect(snapshot['metadataScrapeError'], contains('scraper unavailable'));
    expect(ops.writeRequests, isEmpty);
  });
}

class _FakeWebDavLibraryOps implements WebDavLibraryOps {
  final dirs = <String, List<WebDavLibraryEntry>>{};
  final errors = <String, Object>{};
  final textFiles = <String, String>{};
  final textETags = <String, String>{};
  final textModifiedAt = <String, int>{};
  final validatorlessPaths = <String>{};
  final readPaths = <String>[];
  final textReadPaths = <String>[];
  final writtenTexts = <String, String>{};
  final writeRequests =
      <
        ({
          String path,
          bool createOnly,
          String? ifMatch,
          int? ifUnmodifiedSince,
        })
      >[];
  void Function(String path, int writeNumber)? beforeWrite;
  final blockers = <String, Completer<void>>{};
  final readStarted = <String, Completer<void>>{};

  @override
  Future<List<WebDavLibraryEntry>> readDir(
    WebDavLibraryConfig config,
    String remotePath,
  ) async {
    readPaths.add(remotePath);
    final started = readStarted[remotePath];
    if (started != null && !started.isCompleted) started.complete();
    await blockers[remotePath]?.future;
    final error = errors[remotePath];
    if (error != null) throw error;
    return dirs[remotePath] ?? const [];
  }

  @override
  Future<WebDavTextFile> readText(
    WebDavLibraryConfig config,
    String remotePath,
  ) async {
    textReadPaths.add(remotePath);
    final value = textFiles[remotePath];
    if (value == null) throw StateError('Missing text file: $remotePath');
    return WebDavTextFile(
      content: value,
      eTag: validatorlessPaths.contains(remotePath)
          ? null
          : textETags[remotePath] ?? '"1"',
      modifiedAt: validatorlessPaths.contains(remotePath)
          ? null
          : textModifiedAt[remotePath],
    );
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
    writeRequests.add((
      path: remotePath,
      createOnly: createOnly,
      ifMatch: ifMatch,
      ifUnmodifiedSince: ifUnmodifiedSince,
    ));
    beforeWrite?.call(remotePath, writeRequests.length);
    if (createOnly && textFiles.containsKey(remotePath)) {
      throw WebDavPreconditionFailedException(remotePath);
    }
    if (ifMatch != null && ifMatch != (textETags[remotePath] ?? '"1"')) {
      throw WebDavPreconditionFailedException(remotePath);
    }
    if (ifUnmodifiedSince != null &&
        ifUnmodifiedSince != textModifiedAt[remotePath]) {
      throw WebDavPreconditionFailedException(remotePath);
    }
    writtenTexts[remotePath] = content;
    textFiles[remotePath] = content;
    final currentTag = textETags[remotePath] ?? '"1"';
    final version = int.tryParse(currentTag.replaceAll('"', '')) ?? 1;
    final nextTag = '"${version + 1}"';
    textETags[remotePath] = nextTag;
    final separator = remotePath.lastIndexOf('/');
    final directoryPath = remotePath.substring(0, separator + 1);
    final fileName = remotePath.substring(separator + 1);
    final entries = List<WebDavLibraryEntry>.from(
      dirs[directoryPath] ?? const [],
    );
    if (!entries.any(
      (entry) =>
          !entry.isDirectory &&
          entry.name.toLowerCase() == fileName.toLowerCase(),
    )) {
      entries.add(
        WebDavLibraryEntry(name: fileName, isDirectory: false, eTag: nextTag),
      );
      dirs[directoryPath] = entries;
    }
    return WebDavWriteResult(eTag: nextTag);
  }

  @override
  Future<void> test(WebDavLibraryConfig config) async {}
}
