import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/comic_type.dart';

void main() {
  late Directory root;
  late LocalManager local;
  late History history;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('natural-sort-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    LocalManager.resetForTesting();
    LocalManager.debugSkipComicSourceInit = true;
    HistoryManager.cache = null;
    await HistoryManager().init();
    local = LocalManager();
    await local.init();
    final folder = Directory('${local.path}/book')..createSync();
    for (final name in ['图片_1.jpg', '图片_10.jpg', '图片_2.jpg']) {
      File('${folder.path}/$name').writeAsBytesSync([1]);
    }
    final comic = LocalComic(
      id: '1',
      title: 'Book',
      subtitle: '',
      tags: [],
      directory: 'book',
      chapters: null,
      cover: '',
      comicType: ComicType.local,
      downloadedChapters: [],
      createdAt: DateTime(2026),
    );
    await local.add(comic);
    history = History.fromModel(model: comic, ep: 1, page: 2);
    HistoryManager().addHistory(history);
  });
  tearDown(() {
    HistoryManager().close();
    HistoryManager.cache = null;
    LocalManager.resetForTesting();
    root.deleteSync(recursive: true);
  });

  test('new imports retain their natural page number', () async {
    await local.migrateLegacyPageOrder(history);
    expect(history.page, 2);
    final images = await local.getImages('1', ComicType.local, 1);
    expect(images.map((p) => p.split(RegExp(r'[/\\]')).last), [
      '图片_1.jpg',
      '图片_2.jpg',
      '图片_10.jpg',
    ]);
  });

  test(
    'legacy progress preserves the image and migration is repeatable',
    () async {
      final db = sqlite3.open('${root.path}/local.db');
      db.execute('DELETE FROM natural_sort_migration');
      db.dispose();
      await local.migrateLegacyPageOrder(history);
      expect(history.page, 3);
      expect(HistoryManager().find('1', ComicType.local)!.page, 3);
      await local.migrateLegacyPageOrder(history);
      expect(history.page, 3);
      // Recover a mapping recorded before the history write completed.
      history.page = 2;
      await local.migrateLegacyPageOrder(history);
      expect(history.page, 3);
      history.time = history.time.add(const Duration(seconds: 1));
      history.page = 2;
      await local.migrateLegacyPageOrder(history);
      expect(history.page, 2);
    },
  );

  test(
    'page_1, page_10, page_2 history mapping correctly preserves all 3 file identities',
    () async {
      // Create a book with page_1.jpg, page_10.jpg, page_2.jpg
      final folder = Directory('${local.path}/book_numbered')..createSync();
      for (final name in ['page_1.jpg', 'page_10.jpg', 'page_2.jpg']) {
        File('${folder.path}/$name').writeAsBytesSync([1]);
      }
      final comic = LocalComic(
        id: 'numbered_book',
        title: 'Numbered Book',
        subtitle: '',
        tags: [],
        directory: 'book_numbered',
        chapters: null,
        cover: '',
        comicType: ComicType.local,
        downloadedChapters: [],
        createdAt: DateTime(2026),
      );
      await local.add(comic);

      // Verify natural sort order
      final images = await local.getImages('numbered_book', ComicType.local, 1);
      final names = images.map((p) => p.split(RegExp(r'[/\\]')).last).toList();
      expect(names, ['page_1.jpg', 'page_2.jpg', 'page_10.jpg']);

      // Under legacy lexical sort:
      // page 1 -> page_1.jpg
      // page 2 -> page_10.jpg
      // page 3 -> page_2.jpg

      // Test page 1: should stay page 1 (page_1.jpg is at natural index 1)
      final db = sqlite3.open('${root.path}/local.db');
      db.execute(
        'DELETE FROM natural_sort_migration WHERE id = ?',
        ['numbered_book'],
      );
      final h1 = History.fromModel(model: comic, ep: 1, page: 1);
      HistoryManager().addHistory(h1);
      await local.migrateLegacyPageOrder(h1);
      expect(h1.page, 1);

      // Test page 2: legacy page 2 was page_10.jpg -> natural index 3
      db.execute(
        'DELETE FROM natural_sort_migration WHERE id = ?',
        ['numbered_book'],
      );
      final h2 = History.fromModel(model: comic, ep: 1, page: 2);
      HistoryManager().addHistory(h2);
      await local.migrateLegacyPageOrder(h2);
      expect(h2.page, 3);

      // Test page 3: legacy page 3 was page_2.jpg -> natural index 2
      db.execute(
        'DELETE FROM natural_sort_migration WHERE id = ?',
        ['numbered_book'],
      );
      final h3 = History.fromModel(model: comic, ep: 1, page: 3);
      HistoryManager().addHistory(h3);
      await local.migrateLegacyPageOrder(h3);
      expect(h3.page, 2);

      db.dispose();
    },
  );

  test('migrates downloaded comics and direct image lists idempotently', () async {
    // Direct image list (such as WebDAV)
    final webdavImages = [
      'https://example.com/comics/ch1/page_1.jpg',
      'https://example.com/comics/ch1/page_2.jpg',
      'https://example.com/comics/ch1/page_10.jpg',
    ];
    final webdavHistory = History.fromMap({
      'id': 'webdav_1',
      'type': ComicType.fromKey('webdav_library').value,
      'time': 1000,
      'title': 'WebDAV Comic',
      'subtitle': '',
      'cover': '',
      'ep': 1,
      'page': 2,
      'max_page': 20,
    });

    await local.migrateLegacyPageOrder(webdavHistory, webdavImages);
    expect(webdavHistory.page, 3);

    // Repeated call is idempotent
    await local.migrateLegacyPageOrder(webdavHistory, webdavImages);
    expect(webdavHistory.page, 3);
  });
}
