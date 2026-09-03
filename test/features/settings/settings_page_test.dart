import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/settings/settings.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/webdav_library/webdav_library.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  testWidgets('settings lists reading statistics as a top-level entry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));

    expect(find.text('Reading statistics'), findsOneWidget);
    expect(find.byIcon(Icons.query_stats), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('comic library settings expose credential sync opt-in', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    appdata.settings['webdavComicLibrarySyncEnabled'] = false;
    addTearDown(
      () => appdata.settings['webdavComicLibrarySyncEnabled'] = false,
    );
    LocalManager().path = 'test-library';
    final root = Directory.systemTemp.createTempSync('venera-settings-page-');
    App.cachePath = (Directory('${root.path}/cache')..createSync()).path;
    App.dataPath = (Directory('${root.path}/data')..createSync()).path;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      WebDavLibrarySource.resetCacheForTesting();
      CacheManager.resetForTesting();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(0.8)),
          child: child!,
        ),
        home: const SettingsPage(),
      ),
    );
    await tester.tap(find.text('APP'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('WebDAV Comic Library'));
    await tester.tap(find.text('WebDAV Comic Library'));
    await tester.pumpAndSettle();

    final switchFinder = find.byKey(
      const Key('webdav-comic-library-config-sync-switch'),
    );
    expect(switchFinder, findsOneWidget);
    expect(
      find.textContaining('Credentials will be stored in remote .venera'),
      findsOneWidget,
    );
    expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);

    await tester.tap(switchFinder);
    await tester.pump();

    expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);
  });
}
