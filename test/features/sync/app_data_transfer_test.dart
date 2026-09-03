import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/sync/sync.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  late Directory root;
  late String previousDataPath;
  late String previousCachePath;
  late Directory fallbackRoot;

  setUpAll(() {
    fallbackRoot = Directory.systemTemp.createTempSync(
      'venera-app-data-transfer-fallback-',
    );
    App.dataPath = (Directory('${fallbackRoot.path}/data')..createSync()).path;
    App.cachePath = (Directory(
      '${fallbackRoot.path}/cache',
    )..createSync()).path;
  });

  tearDownAll(() {
    if (fallbackRoot.existsSync()) fallbackRoot.deleteSync(recursive: true);
  });

  setUp(() {
    previousDataPath = App.dataPath;
    previousCachePath = App.cachePath;
    root = Directory.systemTemp.createTempSync('venera-app-data-transfer-');
    final dataDir = Directory('${root.path}/data')..createSync();
    final cacheDir = Directory('${root.path}/cache')..createSync();
    App.dataPath = dataDir.path;
    App.cachePath = cacheDir.path;
    appdata.settings['disableSyncFields'] = '';
    appdata.settings['cacheSize'] = 2048;
    registerAppDataSettingsChangedHandler(null);
    configureAppDataArchiveExtractorForTesting((archive, destination) async {
      await archive.copy('${destination.path}/appdata.json');
    });
  });

  tearDown(() {
    configureAppDataArchiveExtractorForTesting(null);
    registerAppDataSettingsChangedHandler(null);
    appdata.settings['disableSyncFields'] = '';
    appdata.settings['cacheSize'] = 2048;
    App.dataPath = previousDataPath;
    App.cachePath = previousCachePath;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test(
    'notifies settings change only after imported settings are persisted',
    () async {
      final archive = _createArchive(root, {
        'settings': {'cacheSize': 1024},
        'searchHistory': <String>[],
      });
      var callbackCount = 0;
      registerAppDataSettingsChangedHandler(() {
        callbackCount++;
        final persisted =
            jsonDecode(File('${App.dataPath}/appdata.json').readAsStringSync())
                as Map<String, dynamic>;
        expect(persisted['settings']['cacheSize'], 1024);
      });

      await importAppData(archive);

      expect(callbackCount, 1);
      expect(appdata.settings['cacheSize'], 1024);
    },
  );

  test(
    'does not notify settings change when imported appdata is invalid',
    () async {
      final archive = _createArchive(root, {
        'settings': 'invalid',
        'searchHistory': <String>[],
      });
      var callbackCount = 0;
      registerAppDataSettingsChangedHandler(() {
        callbackCount++;
      });

      await expectLater(importAppData(archive), throwsFormatException);

      expect(callbackCount, 0);
    },
  );
}

File _createArchive(Directory root, Map<String, dynamic> appData) {
  return File('${root.path}/remote.venera')
    ..writeAsStringSync(jsonEncode(appData));
}
