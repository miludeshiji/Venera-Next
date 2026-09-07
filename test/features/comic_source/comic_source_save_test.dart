import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/network/images.dart';

void main() {
  setUp(() {
    configureComicSourceDataSavedHandler(null);
  });

  tearDown(() {
    configureComicSourceDataSavedHandler(null);
  });

  test(
    'saveData coalesces concurrent writes and keeps latest source data',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-comic-source-',
      );
      addTearDown(() {
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
      });
      App.dataPath = dataDir.path;

      var uploadCount = 0;
      configureComicSourceDataSavedHandler(() async {
        uploadCount++;
      });

      final source = _source();
      source.data = {'token': 'first'};
      final firstSave = source.saveData();
      source.data = {'token': 'second'};
      final secondSave = source.saveData();
      source.data = {'token': 'third'};
      final thirdSave = source.saveData();

      await Future.wait([firstSave, secondSave, thirdSave]);
      await pumpEventQueue();

      final savedFile = File('${dataDir.path}/comic_source/test.data');
      final savedData = jsonDecode(savedFile.readAsStringSync());

      expect(savedData['token'], 'third');
      expect(uploadCount, 2);
    },
  );

  test('comic type resolves source data through comic source bridge', () {
    const key = 'comic_type_bridge_test_source';
    final manager = ComicSourceManager();
    manager.remove(key);
    final source = _source(key: key);
    manager.add(source);
    addTearDown(() => manager.remove(key));

    final type = ComicType.fromKey(key);

    expect(type.sourceKey, key);
    expect(type.comicSource, same(source));
  });

  test('check source updates skips when source list url is empty', () async {
    const key = 'comic_source_update_without_repo';
    final manager = ComicSourceManager();
    manager.remove(key);
    final source = _source(key: key);
    manager.add(source);
    final previousListUrl = appdata.settings['comicSourceListUrl'];
    appdata.settings['comicSourceListUrl'] = '';
    addTearDown(() {
      appdata.settings['comicSourceListUrl'] = previousListUrl;
      manager.remove(key);
    });

    final count = await ComicSourcePage.checkComicSourceUpdate();

    expect(count, 0);
    expect(ComicSourceManager().availableUpdates, isEmpty);
  });

  test(
    'ComicSource constructor preserves backwards compatibility and accepts optional progress and reply funcs',
    () async {
      final legacySource = _source(key: 'legacy');
      expect(legacySource.updateReadProgressFunc, isNull);
      expect(legacySource.replyCommentFunc, isNull);

      var progressCalled = false;
      var replyCalled = false;

      final extendedSource = ComicSource(
        'Extended Source',
        'extended',
        null,
        null,
        null,
        null,
        const [],
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        'extended.js',
        '',
        '1.0.0',
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        false,
        false,
        null,
        null,
        updateReadProgressFunc: (comicId, epId, page) async {
          progressCalled = true;
          return const Res(true);
        },
        replyCommentFunc: (id, subId, content, parentId, replyId) async {
          replyCalled = true;
          return const Res(true);
        },
      );

      expect(extendedSource.updateReadProgressFunc, isNotNull);
      expect(extendedSource.replyCommentFunc, isNotNull);

      final progressRes = await extendedSource.updateReadProgressFunc!(
        'comic1',
        'ep1',
        1,
      );
      expect(progressRes.success, isTrue);
      expect(progressCalled, isTrue);

      final replyRes = await extendedSource.replyCommentFunc!(
        'comic1',
        null,
        'reply message',
        'root-1',
        'sub-2',
      );
      expect(replyRes.success, isTrue);
      expect(replyCalled, isTrue);
    },
  );

  test(
    'ComicSourceParser detects comic.updateReadProgress and comic.replyComment and bridges parameters',
    () async {
      final tempDir = Directory.systemTemp.createTempSync(
        'venera-parser-test-',
      );
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });
      App.dataPath = tempDir.path;

      final initScript = await File('assets/init.js').readAsBytes();
      JsEngine.cacheJsInit(initScript);
      await JsEngine().init();
      addTearDown(() async {
        await JsEngine().dispose();
      });

      const legacyJs = '''
class LegacySource extends ComicSource {
  name = "Legacy Source"
  key = "legacy_test_key"
  version = "1.0.0"
  url = "https://example.com"
}
''';

      final legacySource = await ComicSourceParser().parse(
        legacyJs,
        'legacy.js',
      );
      expect(legacySource.updateReadProgressFunc, isNull);
      expect(legacySource.replyCommentFunc, isNull);

      const extendedJs = '''
class ExtendedSource extends ComicSource {
  name = "Extended Source"
  key = "extended_test_key"
  version = "1.0.0"
  url = "https://example.com"
  replyCommentCount = 0

  comic = {
    updateReadProgress: (comicId, epId, page) => {
      this.lastProgress = { comicId, epId, page };
      if (comicId === "error_comic") {
        throw new Error("Progress write failed");
      }
      return true;
    },
    replyComment: (id, subId, content, parentId, replyId) => {
      this.replyCommentCount = (this.replyCommentCount || 0) + 1;
      this.lastReply = { id, subId, content, parentId, replyId };
      if (content === "throw_expired") {
        throw new Error("Login expired");
      }
      return true;
    }
  }
}
''';

      final extendedSource = await ComicSourceParser().parse(
        extendedJs,
        'extended.js',
      );

      expect(extendedSource.updateReadProgressFunc, isNotNull);
      expect(extendedSource.replyCommentFunc, isNotNull);

      // Verify updateReadProgress parameter passing
      final progressRes = await extendedSource.updateReadProgressFunc!(
        'test_comic_123',
        'ch_456',
        18,
      );
      expect(progressRes.success, isTrue);

      final lastProgress =
          JsEngine().runCode(
                'ComicSource.sources.extended_test_key.lastProgress',
              )
              as Map;
      expect(lastProgress['comicId'], 'test_comic_123');
      expect(lastProgress['epId'], 'ch_456');
      expect(lastProgress['page'], 18);

      // Verify updateReadProgress error handling (does not retry)
      final errorProgressRes = await extendedSource.updateReadProgressFunc!(
        'error_comic',
        'ch_456',
        18,
      );
      expect(errorProgressRes.error, isTrue);
      expect(errorProgressRes.errorMessage, contains('Progress write failed'));

      // Verify replyComment parameter passing
      final replyRes = await extendedSource.replyCommentFunc!(
        'comment_target_id',
        'sub_target_id',
        'hello reply content',
        'root_comment_id',
        'sub_reply_id',
      );
      expect(replyRes.success, isTrue);

      final lastReply =
          JsEngine().runCode('ComicSource.sources.extended_test_key.lastReply')
              as Map;
      expect(lastReply['id'], 'comment_target_id');
      expect(lastReply['subId'], 'sub_target_id');
      expect(lastReply['content'], 'hello reply content');
      expect(lastReply['parentId'], 'root_comment_id');
      expect(lastReply['replyId'], 'sub_reply_id');

      // Verify replyComment login expired handling (no automatic replay)
      JsEngine().runCode(
        'ComicSource.sources.extended_test_key.replyCommentCount = 0;',
      );
      final expiredReplyRes = await extendedSource.replyCommentFunc!(
        'comment_target_id',
        null,
        'throw_expired',
        'root_comment_id',
        null,
      );
      expect(expiredReplyRes.error, isTrue);
      expect(expiredReplyRes.errorMessage, contains('Login expired'));
      expect(
        expiredReplyRes.errorMessage,
        isNot(contains('Login expired and re-login failed')),
      );
      expect(
        JsEngine().runCode(
          'ComicSource.sources.extended_test_key.replyCommentCount',
        ),
        1,
      );
      expect(
        JsEngine().runCode('ComicSource.sources.extended_test_key.replyCount'),
        1,
      );
    },
    skip: _qjsAvailable() ? false : 'flutter_qjs native library is unavailable',
  );

  test(
    'ComicSourceParser bridges comic.onImageLoad with legacy 3-arg compatibility, target map fields, and null target',
    () async {
      final tempDir = Directory.systemTemp.createTempSync(
        'venera-parser-test-',
      );
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });
      App.dataPath = tempDir.path;

      final initScript = await File('assets/init.js').readAsBytes();
      JsEngine.cacheJsInit(initScript);
      await JsEngine().init();
      addTearDown(() async {
        await JsEngine().dispose();
      });

      const legacyJs = '''
class LegacyImageSource extends ComicSource {
  name = "Legacy Image Source"
  key = "legacy_image_test_key"
  version = "1.0.0"
  url = "https://example.com"

  comic = {
    onImageLoad: (imageKey, comicId, ep) => {
      this.lastLegacyCall = { imageKey, comicId, ep };
      return {
        url: "https://example.com/legacy/" + comicId + "/" + ep + "/" + imageKey,
        headers: { "Referer": "https://example.com" }
      };
    }
  }
}
''';

      final legacySource = await ComicSourceParser().parse(
        legacyJs,
        'legacy_image.js',
      );
      expect(legacySource.getImageLoadingConfig, isNotNull);

      // Legacy 3-arg call without target
      final legacyRes1 = await legacySource.getImageLoadingConfig!(
        '001.jpg',
        'comic_legacy',
        'ch_1',
      );
      expect(
        legacyRes1['url'],
        'https://example.com/legacy/comic_legacy/ch_1/001.jpg',
      );
      expect(legacyRes1['headers'], {'Referer': 'https://example.com'});

      final legacyCall1 =
          JsEngine().runCode(
                'ComicSource.sources.legacy_image_test_key.lastLegacyCall',
              )
              as Map;
      expect(legacyCall1['imageKey'], '001.jpg');
      expect(legacyCall1['comicId'], 'comic_legacy');
      expect(legacyCall1['ep'], 'ch_1');

      // Legacy source called with target: null
      final legacyResNull = await legacySource.getImageLoadingConfig!(
        '002.jpg',
        'comic_legacy',
        'ch_1',
        target: null,
      );
      expect(
        legacyResNull['url'],
        'https://example.com/legacy/comic_legacy/ch_1/002.jpg',
      );

      // Legacy source called with target object
      final legacyResWithTarget = await legacySource.getImageLoadingConfig!(
        '003.jpg',
        'comic_legacy',
        'ch_1',
        target: ComicImageLoadTarget(
          logicalWidth: 800,
          logicalHeight: 1200,
          devicePixelRatio: 2.0,
          fit: ComicImageTargetFit.contain,
        ),
      );
      expect(
        legacyResWithTarget['url'],
        'https://example.com/legacy/comic_legacy/ch_1/003.jpg',
      );

      const modernJs = '''
class ModernImageSource extends ComicSource {
  name = "Modern Image Source"
  key = "modern_image_test_key"
  version = "1.0.0"
  url = "https://example.com"

  comic = {
    onImageLoad: (imageKey, comicId, ep, target) => {
      this.lastModernCall = { imageKey, comicId, ep, target };
      return {
        url: "https://example.com/modern/" + comicId + "/" + ep + "/" + imageKey,
        fit: target ? target.fit : null,
        dpr: target ? target.devicePixelRatio : null,
        targetReceived: target != null
      };
    }
  }
}
''';

      final modernSource = await ComicSourceParser().parse(
        modernJs,
        'modern_image.js',
      );
      expect(modernSource.getImageLoadingConfig, isNotNull);

      // Modern source with full target fields
      final modernTarget = ComicImageLoadTarget(
        logicalWidth: 600,
        logicalHeight: 900,
        devicePixelRatio: 1.5,
        fit: ComicImageTargetFit.fitWidth,
      );
      final modernResWithTarget = await modernSource.getImageLoadingConfig!(
        '004.jpg',
        'comic_modern',
        'ch_2',
        target: modernTarget,
      );
      expect(modernResWithTarget['fit'], 'fitWidth');
      expect(modernResWithTarget['dpr'], 1.5);
      expect(modernResWithTarget['targetReceived'], isTrue);

      final modernCall1 =
          JsEngine().runCode(
                'ComicSource.sources.modern_image_test_key.lastModernCall',
              )
              as Map;
      expect(modernCall1['imageKey'], '004.jpg');
      expect(modernCall1['comicId'], 'comic_modern');
      expect(modernCall1['ep'], 'ch_2');

      final targetMap = modernCall1['target'] as Map;
      expect((targetMap['logicalWidth'] as num).toDouble(), 600.0);
      expect((targetMap['logicalHeight'] as num).toDouble(), 900.0);
      expect((targetMap['devicePixelRatio'] as num).toDouble(), 1.5);
      expect(targetMap['fit'], 'fitWidth');

      // Modern source with explicit null target
      final modernResNull = await modernSource.getImageLoadingConfig!(
        '005.jpg',
        'comic_modern',
        'ch_2',
        target: null,
      );
      expect(modernResNull['targetReceived'], isFalse);
      expect(modernResNull['fit'], isNull);

      final modernCallNull =
          JsEngine().runCode(
                'ComicSource.sources.modern_image_test_key.lastModernCall',
              )
              as Map;
      expect(modernCallNull['target'], isNull);

      // Modern source with omitted target (defaults to null)
      final modernResOmitted = await modernSource.getImageLoadingConfig!(
        '006.jpg',
        'comic_modern',
        'ch_2',
      );
      expect(modernResOmitted['targetReceived'], isFalse);
      expect(modernResOmitted['fit'], isNull);

      final modernCallOmitted =
          JsEngine().runCode(
                'ComicSource.sources.modern_image_test_key.lastModernCall',
              )
              as Map;
      expect(modernCallOmitted['target'], isNull);
    },
    skip: _qjsAvailable() ? false : 'flutter_qjs native library is unavailable',
  );
}

ComicSource _source({String key = 'test'}) {
  return ComicSource(
    'Test Source',
    key,
    null,
    null,
    null,
    null,
    const [],
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    '$key.js',
    '',
    '1.0.0',
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    false,
    false,
    null,
    null,
  );
}

bool _qjsAvailable() {
  try {
    final engine = FlutterQjs();
    engine.evaluate('1 + 1');
    engine.close();
    return true;
  } catch (_) {
    return false;
  }
}
