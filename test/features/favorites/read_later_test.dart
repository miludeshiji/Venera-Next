import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/translations.dart';

FavoriteItem _comic(String id, {ComicType type = ComicType.local}) =>
    FavoriteItem(
      id: id,
      name: 'Comic $id',
      coverPath: '',
      author: '',
      type: type,
      tags: [],
    );

void main() {
  late Directory root;
  late LocalFavoritesManager manager;
  late Map<String, dynamic> settings;
  setUp(() async {
    settings = Map<String, dynamic>.from(appdata.toJson()['settings'] as Map);
    root = Directory.systemTemp.createTempSync('read-later-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    LocalFavoritesManager.cache = null;
    appdata.settings['readLaterFolder'] = null;
    manager = LocalFavoritesManager();
    await manager.init();
  });
  tearDown(() async {
    await manager.debugWaitForHashedIdsRefresh();
    await appdata.saveData(false);
    manager.close();
    LocalFavoritesManager.cache = null;
    for (final entry in settings.entries) {
      appdata.settings[entry.key] = entry.value;
    }
    root.deleteSync(recursive: true);
  });

  test(
    'read later keeps quick favorites independent and uses comic identity',
    () async {
      final quick = appdata.settings['quickFavorite'];
      await manager.setReadLater(
        _comic('1'),
        included: true,
        folderName: 'Later',
      );
      await manager.setReadLater(
        _comic('1'),
        included: true,
        folderName: 'Later',
      );
      await manager.setReadLater(
        _comic('1', type: const ComicType(17)),
        included: true,
        folderName: 'Later',
      );
      expect(manager.getReadLaterComics(), hasLength(2));
      expect(appdata.settings['quickFavorite'], quick);
      await manager.setReadLater(
        _comic('1'),
        included: false,
        folderName: 'Later',
      );
      expect(manager.isInReadLater('1', ComicType.local), isFalse);
      expect(manager.isInReadLater('1', const ComicType(17)), isTrue);
    },
  );

  test(
    'collisions, rename, deletion and recreation preserve user folders',
    () async {
      manager.createFolder('Later');
      manager.createFolder('Later (2)');
      await manager.setReadLater(
        _comic('1'),
        included: true,
        folderName: 'Later',
      );
      expect(manager.readLaterFolder, 'Later (3)');
      manager.rename('Later (3)', 'My queue');
      expect(manager.readLaterFolder, 'My queue');
      expect(manager.isInReadLater('1', ComicType.local), isTrue);
      manager.deleteFolder('My queue');
      expect(manager.readLaterFolder, isNull);
      expect(manager.getReadLaterComics(), isEmpty);
      await manager.setReadLater(
        _comic('2'),
        included: true,
        folderName: 'Later',
      );
      expect(manager.readLaterFolder, 'Later (3)');
      expect(manager.count('Later'), 0);
    },
  );

  test(
    'reading preserves queue membership and order; binding survives reload',
    () async {
      await manager.setReadLater(
        _comic('1'),
        included: true,
        folderName: 'Later',
      );
      await manager.setReadLater(
        _comic('2'),
        included: true,
        folderName: 'Later',
      );
      appdata.settings['moveFavoriteAfterRead'] = 'start';
      manager.onRead('1', ComicType.local);
      expect(manager.getReadLaterComics().map((c) => c.id), ['2', '1']);
      final saved = {
        'settings': Map<String, dynamic>.from(
          appdata.toJson()['settings'] as Map,
        ),
      };
      await manager.debugWaitForHashedIdsRefresh();
      manager.close();
      LocalFavoritesManager.cache = null;
      appdata.settings['readLaterFolder'] = null;
      manager = LocalFavoritesManager();
      await manager.init();
      appdata.syncData(saved);
      expect(manager.readLaterFolder, 'Later');
      expect(manager.getReadLaterComics(limit: 1).single.id, '2');
    },
  );

  test(
    'read later as follow updates folder skips display_order reorder but clears has_new_update',
    () async {
      await manager.setReadLater(
        _comic('1'),
        included: true,
        folderName: 'Later',
      );
      await manager.setReadLater(
        _comic('2'),
        included: true,
        folderName: 'Later',
      );
      final folder = manager.readLaterFolder!;
      appdata.settings['followUpdatesFolder'] = folder;
      manager.prepareTableForFollowUpdates(folder, false);

      // Mark comic '1' as having a new update in the database
      final db = sqlite3.open('${root.path}/local_favorite.db');
      db.execute('UPDATE "$folder" SET has_new_update = 1 WHERE id = ?', ['1']);
      db.dispose();
      manager.refreshUpdateIds();
      expect(manager.hasNewUpdate('1', ComicType.local), isTrue);

      // Reading comic '1' with moveFavoriteAfterRead = 'start'
      appdata.settings['moveFavoriteAfterRead'] = 'start';
      manager.onRead('1', ComicType.local);

      // Order must NOT be reordered (remains ['2', '1'] instead of moving '1' to start)
      expect(manager.getReadLaterComics().map((c) => c.id), ['2', '1']);
      // But has_new_update MUST be cleared!
      expect(manager.hasNewUpdate('1', ComicType.local), isFalse);

      // Test with moveFavoriteAfterRead = 'end'
      final db2 = sqlite3.open('${root.path}/local_favorite.db');
      db2.execute('UPDATE "$folder" SET has_new_update = 1 WHERE id = ?', [
        '2',
      ]);
      db2.dispose();
      manager.refreshUpdateIds();
      expect(manager.hasNewUpdate('2', ComicType.local), isTrue);
      appdata.settings['moveFavoriteAfterRead'] = 'end';
      manager.onRead('2', ComicType.local);
      expect(manager.getReadLaterComics().map((c) => c.id), ['2', '1']);
      expect(manager.hasNewUpdate('2', ComicType.local), isFalse);
    },
  );
  testWidgets('summary updates and detail action toggles queue membership', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              const ReadLaterSummary(),
              SliverToBoxAdapter(child: ReadLaterButton(comic: _comic('1'))),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Read later · 0'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(TextButton, 'Read later'));
      await appdata.saveData(false);
    });
    await tester.pump();
    expect(find.text('Read later · 1'), findsOneWidget);
    expect(find.text('Remove from read later'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(
        find.widgetWithText(TextButton, 'Remove from read later'),
      );
      await appdata.saveData(false);
      await manager.debugWaitForHashedIdsRefresh();
    });
    await tester.pump();
    expect(find.text('Read later · 0'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  for (final size in [const Size(375, 667), const Size(1024, 768)]) {
    for (final language in ['en-US', 'zh-CN']) {
      testWidgets('read later fits $size in $language with large text', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        appdata.settings['language'] = language;
        await AppTranslation.init();
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              colorSchemeSeed: Colors.indigo,
              useMaterial3: true,
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: RepaintBoundary(
              key: boundaryKey,
              child: Scaffold(
                body: CustomScrollView(
                  slivers: [
                    const ReadLaterSummary(),
                    SliverToBoxAdapter(
                      child: ReadLaterButton(comic: _comic('1')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final output = Platform.environment['VENERA_ISSUE_QA_DIR'];
        if (output != null) {
          final boundary =
              boundaryKey.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            Directory(output).createSync(recursive: true);
            File(
              '$output/read-later-${size.width.toInt()}-$language.png',
            ).writeAsBytesSync(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
