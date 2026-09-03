import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  late Directory fallbackDataDir;

  setUpAll(() {
    fallbackDataDir = Directory.systemTemp.createTempSync(
      'venera-appdata-fallback-',
    );
  });

  setUp(() {
    App.dataPath = fallbackDataDir.path;
  });

  tearDownAll(() {
    if (fallbackDataDir.existsSync()) {
      fallbackDataDir.deleteSync(recursive: true);
    }
  });

  test('does not configure a comic source list by default', () {
    expect(appdata.settings['comicSourceListUrl'], isEmpty);
  });

  test('reader settings resolve from global, device, then comic scope', () {
    final previousDeviceId = appdata.settings['deviceId'];
    final previousDeviceSettings = appdata.settings['deviceSpecificSettings'];
    final previousComicSettings = appdata.settings['comicSpecificSettings'];
    final previousPageNumber = appdata.settings['showPageNumberInReader'];
    final previousClockInfo =
        appdata.settings['enableClockAndBatteryInfoInReader'];

    try {
      appdata.settings['deviceId'] = 'reader-settings-test-device';
      appdata.settings['deviceSpecificSettings'] = <String, dynamic>{};
      appdata.settings['comicSpecificSettings'] = <String, dynamic>{};
      appdata.settings['showPageNumberInReader'] = true;
      appdata.settings['enableClockAndBatteryInfoInReader'] = true;

      appdata.settings.setEnabledDeviceSpecificSettings(true);
      appdata.settings.setDeviceReaderSetting('showPageNumberInReader', false);
      appdata.settings.setDeviceReaderSetting(
        'enableClockAndBatteryInfoInReader',
        false,
      );

      expect(
        appdata.settings.getReaderSetting(
          'comic-id',
          'source-key',
          'showPageNumberInReader',
        ),
        isFalse,
      );
      expect(
        appdata.settings.getReaderSetting(
          'comic-id',
          'source-key',
          'enableClockAndBatteryInfoInReader',
        ),
        isFalse,
      );

      appdata.settings.setEnabledComicSpecificSettings(
        'comic-id',
        'source-key',
        true,
      );
      appdata.settings.setReaderSetting(
        'comic-id',
        'source-key',
        'showPageNumberInReader',
        true,
      );

      expect(
        appdata.settings.getReaderSetting(
          'comic-id',
          'source-key',
          'showPageNumberInReader',
        ),
        isTrue,
      );
      expect(
        appdata.settings.getReaderSetting(
          'comic-id',
          'source-key',
          'enableClockAndBatteryInfoInReader',
        ),
        isFalse,
      );
    } finally {
      appdata.settings['deviceId'] = previousDeviceId;
      appdata.settings['deviceSpecificSettings'] = previousDeviceSettings;
      appdata.settings['comicSpecificSettings'] = previousComicSettings;
      appdata.settings['showPageNumberInReader'] = previousPageNumber;
      appdata.settings['enableClockAndBatteryInfoInReader'] = previousClockInfo;
    }
  });

  test('active reader setting writes to the current settings scope', () {
    final previousDeviceId = appdata.settings['deviceId'];
    final previousDeviceSettings = appdata.settings['deviceSpecificSettings'];
    final previousComicSettings = appdata.settings['comicSpecificSettings'];
    final previousBrightness = appdata.settings['readerBrightness'];

    try {
      appdata.settings['deviceId'] = 'reader-brightness-test-device';
      appdata.settings['deviceSpecificSettings'] = <String, dynamic>{};
      appdata.settings['comicSpecificSettings'] = <String, dynamic>{};
      appdata.settings['readerBrightness'] = 50;

      appdata.settings.setActiveReaderSetting(
        'comic-id',
        'source-key',
        'readerBrightness',
        60,
      );
      expect(appdata.settings['readerBrightness'], 60);

      appdata.settings.setEnabledDeviceSpecificSettings(true);
      appdata.settings.setActiveReaderSetting(
        'comic-id',
        'source-key',
        'readerBrightness',
        40,
      );
      expect(appdata.settings['readerBrightness'], 60);
      expect(appdata.settings.getDeviceReaderSetting('readerBrightness'), 40);

      appdata.settings.setEnabledComicSpecificSettings(
        'comic-id',
        'source-key',
        true,
      );
      appdata.settings.setActiveReaderSetting(
        'comic-id',
        'source-key',
        'readerBrightness',
        30,
      );
      expect(
        appdata.settings.getReaderSetting(
          'comic-id',
          'source-key',
          'readerBrightness',
        ),
        30,
      );
      expect(appdata.settings.getDeviceReaderSetting('readerBrightness'), 40);
    } finally {
      appdata.settings['deviceId'] = previousDeviceId;
      appdata.settings['deviceSpecificSettings'] = previousDeviceSettings;
      appdata.settings['comicSpecificSettings'] = previousComicSettings;
      appdata.settings['readerBrightness'] = previousBrightness;
    }
  });

  test(
    'saveData queues concurrent writes and keeps the latest snapshot',
    () async {
      final dataDir = Directory.systemTemp.createTempSync('venera-appdata-');
      addTearDown(() {
        appdata.settings['disableSyncFields'] = '';
        appdata.settings['proxy'] = 'system';
        appdata.searchHistory = [];
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      appdata.settings['disableSyncFields'] = 'proxy';
      appdata.settings['proxy'] = 'first';
      appdata.searchHistory = ['first'];

      final firstSave = appdata.saveData(false);
      appdata.settings['proxy'] = 'second';
      appdata.searchHistory = ['second'];
      final secondSave = appdata.saveData(false);

      await Future.wait([firstSave, secondSave]);

      final appDataFile = File('${dataDir.path}/appdata.json');
      final syncDataFile = File('${dataDir.path}/syncdata.json');
      final appData = jsonDecode(appDataFile.readAsStringSync());
      final syncData = jsonDecode(syncDataFile.readAsStringSync());

      expect(appData['settings']['proxy'], 'second');
      expect(appData['searchHistory'], ['second']);
      expect(syncData['settings'].containsKey('proxy'), isFalse);
    },
  );

  test('sync snapshot always filters device-local WebDAV settings', () async {
    final dataDir = Directory.systemTemp.createTempSync(
      'venera-appdata-sync-policy-',
    );
    addTearDown(() {
      App.dataPath = fallbackDataDir.path;
      appdata.settings['disableSyncFields'] = '';
      appdata.settings['webdav'] = [];
      appdata.settings['backupWebdav'] = [];
      appdata.settings['backupWebdavPath'] = '/venera_backup/';
      appdata.settings['backupWebdavSyncEnabled'] = false;
      appdata.settings['webdavComicLibrary'] = [];
      appdata.settings['webdavComicLibraryPath'] = '/venera_comics/';
      appdata.settings['webdavComicLibraryAutoSync'] = true;
      appdata.settings['webdavComicLibrarySyncIntervalMinutes'] = 360;
      appdata.settings['webdavComicLibrarySyncEnabled'] = false;
      if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    });

    App.dataPath = dataDir.path;
    appdata.settings['disableSyncFields'] = '';
    appdata.settings['webdav'] = [
      'https://sync.example/dav',
      'sync-user',
      'main-secret',
    ];
    appdata.settings['backupWebdav'] = [
      'https://backup.example/dav',
      'backup-user',
      'backup-secret',
    ];
    appdata.settings['backupWebdavPath'] = '/backup/';
    appdata.settings['backupWebdavSyncEnabled'] = false;
    appdata.settings['webdavComicLibrary'] = [
      'https://library.example/dav',
      'library-user',
      'comic-secret',
    ];
    appdata.settings['webdavComicLibraryPath'] = '/library/';
    appdata.settings['webdavComicLibraryAutoSync'] = false;
    appdata.settings['webdavComicLibrarySyncIntervalMinutes'] = 15;
    appdata.settings['webdavComicLibrarySyncEnabled'] = false;

    await appdata.saveData(false);

    final syncContent = File(
      '${dataDir.path}/syncdata.json',
    ).readAsStringSync();
    final syncSettings =
        (jsonDecode(syncContent) as Map<String, dynamic>)['settings']
            as Map<String, dynamic>;
    expect(syncSettings.containsKey('webdav'), isFalse);
    expect(syncSettings.containsKey('backupWebdav'), isFalse);
    expect(syncSettings.containsKey('backupWebdavPath'), isFalse);
    expect(syncSettings.containsKey('webdavComicLibrary'), isFalse);
    expect(syncSettings.containsKey('webdavComicLibraryPath'), isFalse);
    expect(syncSettings.containsKey('webdavComicLibraryAutoSync'), isFalse);
    expect(
      syncSettings.containsKey('webdavComicLibrarySyncIntervalMinutes'),
      isFalse,
    );
    expect(syncSettings.containsKey('webdavComicLibrarySyncEnabled'), isFalse);
    expect(syncContent, isNot(contains('main-secret')));
    expect(syncContent, isNot(contains('backup-secret')));
    expect(syncContent, isNot(contains('comic-secret')));
  });

  test('sync snapshot includes opted-in comic library config', () async {
    final dataDir = Directory.systemTemp.createTempSync(
      'venera-appdata-library-sync-',
    );
    addTearDown(() {
      App.dataPath = fallbackDataDir.path;
      appdata.settings['disableSyncFields'] = '';
      appdata.settings['webdavComicLibrary'] = [];
      appdata.settings['webdavComicLibraryPath'] = '/venera_comics/';
      appdata.settings['webdavComicLibraryAutoSync'] = true;
      appdata.settings['webdavComicLibrarySyncIntervalMinutes'] = 360;
      appdata.settings['webdavComicLibrarySyncEnabled'] = false;
      if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    });

    App.dataPath = dataDir.path;
    appdata.settings['disableSyncFields'] = '';
    appdata.settings['webdavComicLibrary'] = [
      'https://library.example/dav',
      'library-user',
      'comic-secret',
    ];
    appdata.settings['webdavComicLibraryPath'] = '/library/';
    appdata.settings['webdavComicLibraryAutoSync'] = false;
    appdata.settings['webdavComicLibrarySyncIntervalMinutes'] = 15;
    appdata.settings['webdavComicLibrarySyncEnabled'] = true;

    await appdata.saveData(false);

    final syncSettings =
        (jsonDecode(File('${dataDir.path}/syncdata.json').readAsStringSync())
                as Map<String, dynamic>)['settings']
            as Map<String, dynamic>;
    expect(syncSettings['webdavComicLibrary'], [
      'https://library.example/dav',
      'library-user',
      'comic-secret',
    ]);
    expect(syncSettings['webdavComicLibraryPath'], '/library/');
    expect(syncSettings['webdavComicLibraryAutoSync'], isFalse);
    expect(syncSettings['webdavComicLibrarySyncIntervalMinutes'], 15);
    expect(syncSettings.containsKey('webdavComicLibrarySyncEnabled'), isFalse);
  });

  test(
    'remote data preserves the local sync endpoint and gated library config',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-appdata-import-policy-',
      );
      addTearDown(() {
        App.dataPath = fallbackDataDir.path;
        appdata.settings['disableSyncFields'] = '';
        appdata.settings['webdav'] = [];
        appdata.settings['webdavComicLibrary'] = [];
        appdata.settings['webdavComicLibraryPath'] = '/venera_comics/';
        appdata.settings['webdavComicLibraryAutoSync'] = true;
        appdata.settings['webdavComicLibrarySyncIntervalMinutes'] = 360;
        appdata.settings['webdavComicLibrarySyncEnabled'] = false;
        appdata.implicitData.remove('webdavAutoSync');
        if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
      });

      App.dataPath = dataDir.path;
      appdata.settings['disableSyncFields'] = '';
      appdata.settings['webdav'] = [
        'https://local-sync.example/dav',
        'local-user',
        'local-secret',
      ];
      appdata.implicitData['webdavAutoSync'] = false;
      appdata.settings['webdavComicLibrary'] = [
        'https://local-library.example/dav',
        'local-user',
        'local-secret',
      ];
      appdata.settings['webdavComicLibraryPath'] = '/local/';
      appdata.settings['webdavComicLibraryAutoSync'] = true;
      appdata.settings['webdavComicLibrarySyncIntervalMinutes'] = 360;
      appdata.settings['webdavComicLibrarySyncEnabled'] = false;

      final remoteSettings = <String, dynamic>{
        'webdav': [
          'https://remote-sync.example/dav',
          'remote-user',
          'remote-secret',
        ],
        'webdavAutoSync': true,
        'webdavComicLibrary': [
          'https://remote-library.example/dav',
          'remote-user',
          'remote-secret',
        ],
        'webdavComicLibraryPath': '/remote/',
        'webdavComicLibraryAutoSync': false,
        'webdavComicLibrarySyncIntervalMinutes': 15,
        'webdavComicLibrarySyncEnabled': true,
      };

      await appdata.syncData({
        'settings': remoteSettings,
        'searchHistory': <String>[],
      });

      expect(appdata.settings['webdav'], [
        'https://local-sync.example/dav',
        'local-user',
        'local-secret',
      ]);
      expect(appdata.implicitData['webdavAutoSync'], isFalse);
      expect(appdata.settings['webdavComicLibrary'], [
        'https://local-library.example/dav',
        'local-user',
        'local-secret',
      ]);
      expect(appdata.settings['webdavComicLibraryPath'], '/local/');
      expect(appdata.settings['webdavComicLibrarySyncEnabled'], isFalse);

      appdata.settings['webdavComicLibrarySyncEnabled'] = true;
      await appdata.syncData({
        'settings': remoteSettings,
        'searchHistory': <String>[],
      });

      expect(appdata.settings['webdavComicLibrary'], [
        'https://remote-library.example/dav',
        'remote-user',
        'remote-secret',
      ]);
      expect(appdata.settings['webdavComicLibraryPath'], '/remote/');
      expect(appdata.settings['webdavComicLibraryAutoSync'], isFalse);
      expect(appdata.settings['webdavComicLibrarySyncIntervalMinutes'], 15);
    },
  );

  test(
    'Bangumi connection data syncs while pending progress remains local',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-appdata-bangumi-',
      );
      addTearDown(() {
        App.dataPath = fallbackDataDir.path;
        appdata.settings['disableSyncFields'] = '';
        appdata.settings['bangumiAccessToken'] = '';
        appdata.settings['bangumiUsername'] = '';
        appdata.settings['bangumiAutoSyncEnabled'] = true;
        appdata.settings['bangumiBindings'] = <String, dynamic>{};
        appdata.implicitData.remove('bangumiPendingProgress');
        if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
      });

      App.dataPath = dataDir.path;
      appdata.settings['disableSyncFields'] = 'proxy';
      appdata.settings['bangumiAccessToken'] = 'token';
      appdata.settings['bangumiUsername'] = 'alice';
      appdata.settings['bangumiAutoSyncEnabled'] = false;
      appdata.settings['bangumiBindings'] = {
        'source@comic': {'subjectId': 42},
      };
      appdata.implicitData['bangumiPendingProgress'] = {
        'source@comic': {
          'ep_status': {'value': 12},
        },
      };

      await appdata.saveData(false);
      appdata.writeImplicitData();
      await appdata.saveData(false);

      final syncData = jsonDecode(
        File('${dataDir.path}/syncdata.json').readAsStringSync(),
      );
      final implicitData = jsonDecode(
        File('${dataDir.path}/implicitData.json').readAsStringSync(),
      );
      expect(syncData['settings']['bangumiAccessToken'], 'token');
      expect(syncData['settings']['bangumiUsername'], 'alice');
      expect(syncData['settings']['bangumiAutoSyncEnabled'], isFalse);
      expect(syncData['settings']['bangumiBindings'], isNotEmpty);
      expect(
        syncData['settings'].containsKey('bangumiPendingProgress'),
        isFalse,
      );
      expect(implicitData['bangumiPendingProgress'], isNotEmpty);
    },
  );

  test('saveData keeps the previous appdata snapshot as backup', () async {
    final dataDir = Directory.systemTemp.createTempSync('venera-appdata-');
    addTearDown(() {
      appdata.settings['disableSyncFields'] = '';
      appdata.settings['proxy'] = 'system';
      appdata.searchHistory = [];
      if (dataDir.existsSync()) {
        dataDir.deleteSync(recursive: true);
      }
    });

    App.dataPath = dataDir.path;
    appdata.settings['proxy'] = 'first';
    appdata.searchHistory = ['first'];
    await appdata.saveData(false);

    appdata.settings['proxy'] = 'second';
    appdata.searchHistory = ['second'];
    await appdata.saveData(false);

    final appDataFile = File('${dataDir.path}/appdata.json');
    final appData = jsonDecode(appDataFile.readAsStringSync());
    final backupData = jsonDecode(
      File('${appDataFile.path}.bak').readAsStringSync(),
    );

    expect(appData['settings']['proxy'], 'second');
    expect(appData['searchHistory'], ['second']);
    expect(backupData['settings']['proxy'], 'first');
    expect(backupData['searchHistory'], ['first']);
  });

  test(
    'migrates legacy Windows company directory when the new directory is empty',
    () async {
      final baseDir = Directory.systemTemp.createTempSync(
        'venera-appdata-migration-',
      );
      addTearDown(() {
        if (baseDir.existsSync()) {
          baseDir.deleteSync(recursive: true);
        }
      });

      final legacyDir = Directory(
        p.join(baseDir.path, 'CyrilPeng_venera-next', 'VeneraNext'),
      )..createSync(recursive: true);
      File(p.join(legacyDir.path, 'appdata.json')).writeAsStringSync('legacy');
      final legacySubDir = Directory(p.join(legacyDir.path, 'comic_source'))
        ..createSync();
      File(
        p.join(legacySubDir.path, 'source.json'),
      ).writeAsStringSync('source');

      final currentDir = Directory(
        p.join(baseDir.path, 'com.github.miludeshiji', 'VeneraNext'),
      )..createSync(recursive: true);

      await App.migrateLegacyWindowsPathForTesting(currentDir.path);

      expect(
        File(p.join(currentDir.path, 'appdata.json')).readAsStringSync(),
        'legacy',
      );
      expect(
        File(
          p.join(currentDir.path, 'comic_source', 'source.json'),
        ).readAsStringSync(),
        'source',
      );
    },
  );

  test(
    'does not overwrite current files while completing a partial migration',
    () async {
      final baseDir = Directory.systemTemp.createTempSync(
        'venera-appdata-migration-',
      );
      addTearDown(() {
        if (baseDir.existsSync()) {
          baseDir.deleteSync(recursive: true);
        }
      });

      final legacyDir = Directory(
        p.join(baseDir.path, 'CyrilPeng_venera-next', 'VeneraNext'),
      )..createSync(recursive: true);
      File(p.join(legacyDir.path, 'appdata.json')).writeAsStringSync('legacy');

      final currentDir = Directory(
        p.join(baseDir.path, 'com.github.miludeshiji', 'VeneraNext'),
      )..createSync(recursive: true);
      File(
        p.join(currentDir.path, 'appdata.json'),
      ).writeAsStringSync('current');

      await App.migrateLegacyWindowsPathForTesting(currentDir.path);

      expect(
        File(p.join(currentDir.path, 'appdata.json')).readAsStringSync(),
        'current',
      );
    },
  );

  test(
    'migrates missing data even when the current directory is not empty',
    () async {
      final baseDir = Directory.systemTemp.createTempSync(
        'venera-appdata-migration-',
      );
      addTearDown(() {
        if (baseDir.existsSync()) {
          baseDir.deleteSync(recursive: true);
        }
      });

      final legacyDir = Directory(
        p.join(baseDir.path, 'CyrilPeng_venera-next', 'VeneraNext'),
      )..createSync(recursive: true);
      File(p.join(legacyDir.path, 'appdata.json')).writeAsStringSync('legacy');

      final currentDir = Directory(
        p.join(baseDir.path, 'com.github.miludeshiji', 'VeneraNext'),
      )..createSync(recursive: true);
      File(p.join(currentDir.path, 'logs.txt')).writeAsStringSync('new log');

      await App.migrateLegacyWindowsPathForTesting(currentDir.path);

      expect(
        File(p.join(currentDir.path, 'appdata.json')).readAsStringSync(),
        'legacy',
      );
      expect(
        File(p.join(currentDir.path, 'logs.txt')).readAsStringSync(),
        'new log',
      );
    },
  );

  test(
    'migrates data from the original Windows application identity',
    () async {
      final baseDir = Directory.systemTemp.createTempSync(
        'venera-appdata-migration-',
      );
      addTearDown(() {
        if (baseDir.existsSync()) {
          baseDir.deleteSync(recursive: true);
        }
      });

      final legacyDir = Directory(
        p.join(baseDir.path, 'com.github.wgh136', 'venera'),
      )..createSync(recursive: true);
      File(p.join(legacyDir.path, 'appdata.json')).writeAsStringSync('legacy');

      final currentDir = Directory(
        p.join(baseDir.path, 'com.github.miludeshiji', 'VeneraNext'),
      )..createSync(recursive: true);

      await App.migrateLegacyWindowsPathForTesting(currentDir.path);

      expect(
        File(p.join(currentDir.path, 'appdata.json')).readAsStringSync(),
        'legacy',
      );
    },
  );

  test(
    'recovers appdata from backup without deleting the invalid file',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-appdata-load-',
      );
      addTearDown(() {
        appdata.settings['proxy'] = 'system';
        appdata.searchHistory = [];
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
      });

      final appDataFile = File(p.join(dataDir.path, 'appdata.json'))
        ..writeAsStringSync('{invalid');
      File('${appDataFile.path}.bak').writeAsStringSync(
        jsonEncode({
          'settings': {'proxy': 'http://127.0.0.1:7890'},
          'searchHistory': ['restored'],
        }),
      );

      await appdata.loadDataForTesting(dataDir.path);

      expect(appdata.settings['proxy'], 'http://127.0.0.1:7890');
      expect(appdata.searchHistory, ['restored']);
      expect(jsonDecode(appDataFile.readAsStringSync()), isA<Map>());
      expect(
        dataDir.listSync().whereType<File>().any(
          (file) => p.basename(file.path).startsWith('appdata.json.corrupt-'),
        ),
        isTrue,
      );
    },
  );
}
