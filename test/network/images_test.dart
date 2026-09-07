import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/network/images.dart';

bool _sqliteAvailable() {
  try {
    final db = sqlite3.openInMemory();
    db.dispose();
    return true;
  } catch (_) {
    return false;
  }
}

class _FakeJSInvokable extends JSInvokable {
  _FakeJSInvokable(this.callback);

  final dynamic Function(List args) callback;

  int destroyCount = 0;

  @override
  dynamic invoke(List args, [dynamic thisVal]) {
    return callback(args);
  }

  @override
  void destroy() {
    destroyCount++;
  }
}

void main() {
  tearDown(() {
    ImageDownloader.debugLoadComicImageUnwrapped = null;
    ImageDownloader.debugResetSourceImageLoading();
    ImageDownloader.cancelAllLoadingImages();
  });

  test('loadComicImage stops retrying when retry budget is exhausted', () {
    expect(
      ImageDownloader.debugShouldRetryImageLoad(
        retriesRemaining: 1,
        hasOnLoadFailed: true,
      ),
      isTrue,
    );
    expect(
      ImageDownloader.debugShouldRetryImageLoad(
        retriesRemaining: 0,
        hasOnLoadFailed: true,
      ),
      isFalse,
    );
    expect(
      ImageDownloader.debugShouldRetryImageLoad(
        retriesRemaining: 5,
        hasOnLoadFailed: false,
      ),
      isFalse,
    );
  });

  test('image onResponse callback is freed after valid result', () async {
    final callback = _FakeJSInvokable((args) {
      expect(args.single, isA<Uint8List>());
      return <int>[3, 2, 1];
    });

    final result = await ImageDownloader.debugApplyImageResponseCallback(
      callback,
      <int>[1, 2, 3],
    );

    expect(result, <int>[3, 2, 1]);
    expect(callback.destroyCount, 1);
  });

  test('image onResponse callback is freed after future result', () async {
    final callback = _FakeJSInvokable((args) async => <int>[4, 5, 6]);

    final result = await ImageDownloader.debugApplyImageResponseCallback(
      callback,
      <int>[1, 2, 3],
    );

    expect(result, <int>[4, 5, 6]);
    expect(callback.destroyCount, 1);
  });

  test('image onResponse callback is freed after invalid result', () async {
    final callback = _FakeJSInvokable((args) => 'bad-result');

    await expectLater(
      ImageDownloader.debugApplyImageResponseCallback(callback, <int>[1]),
      throwsA('Error: Invalid onResponse result.'),
    );
    expect(callback.destroyCount, 1);
  });

  test('image onResponse callback is freed after callback error', () async {
    final error = StateError('boom');
    final callback = _FakeJSInvokable((args) => throw error);

    await expectLater(
      ImageDownloader.debugApplyImageResponseCallback(callback, <int>[1]),
      throwsA(same(error)),
    );
    expect(callback.destroyCount, 1);
  });

  test('image onLoadFailed callback is freed after valid config', () async {
    final callback = _FakeJSInvokable(
      (args) => <String, dynamic>{'url': 'next-url'},
    );

    final result = await ImageDownloader.debugResolveImageLoadFailure(callback);

    expect(result, {'url': 'next-url'});
    expect(callback.destroyCount, 1);
  });

  test('image onLoadFailed callback is freed after future config', () async {
    final callback = _FakeJSInvokable(
      (args) async => <String, dynamic>{'url': 'async-url'},
    );

    final result = await ImageDownloader.debugResolveImageLoadFailure(callback);

    expect(result, {'url': 'async-url'});
    expect(callback.destroyCount, 1);
  });

  test(
    'image onLoadFailed callback accepts dynamically typed config',
    () async {
      final callback = _FakeJSInvokable(
        (args) => <dynamic, dynamic>{'url': 'dynamic-url'},
      );

      final result = await ImageDownloader.debugResolveImageLoadFailure(
        callback,
      );

      expect(result, {'url': 'dynamic-url'});
      expect(callback.destroyCount, 1);
    },
  );

  test('image onLoadFailed callback is freed after invalid config', () async {
    final callback = _FakeJSInvokable((args) => 'bad-config');

    final result = await ImageDownloader.debugResolveImageLoadFailure(callback);

    expect(result, isNull);
    expect(callback.destroyCount, 1);
  });

  test('image onLoadFailed callback rejects non-string config keys', () async {
    final callback = _FakeJSInvokable(
      (args) => <dynamic, dynamic>{1: 'bad-key'},
    );

    final result = await ImageDownloader.debugResolveImageLoadFailure(callback);

    expect(result, isNull);
    expect(callback.destroyCount, 1);
  });

  test('image onLoadFailed callback is freed after callback error', () async {
    final error = StateError('boom');
    final callback = _FakeJSInvokable((args) => throw error);

    await expectLater(
      ImageDownloader.debugResolveImageLoadFailure(callback),
      throwsA(same(error)),
    );
    expect(callback.destroyCount, 1);
  });

  test(
    'loadComicImage cancels source stream after last listener cancels',
    () async {
      final sourceCanceled = Completer<void>();
      final source = StreamController<ImageDownloadProgress>(
        onCancel: () {
          if (!sourceCanceled.isCompleted) {
            sourceCanceled.complete();
          }
        },
      );
      addTearDown(() async {
        if (!source.isClosed) {
          await source.close();
        }
      });

      ImageDownloader.debugLoadComicImageUnwrapped =
          (imageKey, sourceKey, cid, eid, {target}) => source.stream;
      final subscription = ImageDownloader.loadComicImage(
        'image-1',
        'source',
        'comic',
        'chapter',
      ).listen((_) {});
      await pumpEventQueue();

      await subscription.cancel();

      await sourceCanceled.future.timeout(const Duration(seconds: 1));
    },
  );

  test(
    'loadComicImage recreates stream immediately after listener cancels',
    () async {
      final firstCancelGate = Completer<void>();
      final firstCanceled = Completer<void>();
      final firstSource = StreamController<ImageDownloadProgress>(
        onCancel: () {
          if (!firstCanceled.isCompleted) {
            firstCanceled.complete();
          }
          return firstCancelGate.future;
        },
      );
      final secondSource = StreamController<ImageDownloadProgress>();
      addTearDown(() async {
        if (!firstCancelGate.isCompleted) {
          firstCancelGate.complete();
        }
        if (!firstSource.isClosed) {
          await firstSource.close();
        }
        if (!secondSource.isClosed) {
          await secondSource.close();
        }
      });

      var loadCount = 0;
      ImageDownloader.debugLoadComicImageUnwrapped =
          (imageKey, sourceKey, cid, eid, {target}) {
            loadCount++;
            return loadCount == 1 ? firstSource.stream : secondSource.stream;
          };
      final firstSubscription = ImageDownloader.loadComicImage(
        'image-reload',
        'source',
        'comic',
        'chapter',
      ).listen((_) {});
      await pumpEventQueue();

      final firstCancel = firstSubscription.cancel();
      await firstCanceled.future.timeout(const Duration(seconds: 1));

      final events = <ImageDownloadProgress>[];
      final secondSubscription = ImageDownloader.loadComicImage(
        'image-reload',
        'source',
        'comic',
        'chapter',
      ).listen(events.add);
      await pumpEventQueue();

      expect(loadCount, 2);

      secondSource.add(
        ImageDownloadProgress(
          currentBytes: 1,
          totalBytes: 1,
          imageBytes: Uint8List(1),
        ),
      );
      await pumpEventQueue();

      expect(events, hasLength(1));

      await secondSubscription.cancel();
      firstCancelGate.complete();
      await firstCancel.timeout(const Duration(seconds: 1));
    },
  );

  test('cancelAllLoadingImages cancels active source streams', () async {
    final sourceCanceled = Completer<void>();
    final source = StreamController<ImageDownloadProgress>(
      onCancel: () {
        if (!sourceCanceled.isCompleted) {
          sourceCanceled.complete();
        }
      },
    );
    addTearDown(() async {
      if (!source.isClosed) {
        await source.close();
      }
    });

    ImageDownloader.debugLoadComicImageUnwrapped =
        (imageKey, sourceKey, cid, eid, {target}) => source.stream;
    final subscription = ImageDownloader.loadComicImage(
      'image-2',
      'source',
      'comic',
      'chapter',
    ).listen((_) {});
    await pumpEventQueue();

    ImageDownloader.cancelAllLoadingImages();

    await sourceCanceled.future.timeout(const Duration(seconds: 1));
    await subscription.cancel();
  });

  group('ComicImageLoadTarget & ImageDownloader target behavior', () {
    tearDown(() {
      ImageDownloader.debugLoadComicImageUnwrapped = null;
      ImageDownloader.cancelAllLoadingImages();
    });

    test('ComicImageLoadTarget normalization and cache identity', () {
      final normalizedTarget = ComicImageLoadTarget(
        logicalWidth: -100,
        logicalHeight: 0,
        devicePixelRatio: -2.0,
      );
      expect(normalizedTarget.logicalWidth, isNull);
      expect(normalizedTarget.logicalHeight, isNull);
      expect(normalizedTarget.devicePixelRatio, 1.0);
      expect(normalizedTarget.physicalWidth, isNull);
      expect(normalizedTarget.physicalHeight, isNull);
      expect(normalizedTarget.cacheIdentity, 'wnull-hnull-contain');

      final validTarget = ComicImageLoadTarget(
        logicalWidth: 360.4,
        logicalHeight: 640.0,
        devicePixelRatio: 2.0,
        fit: ComicImageTargetFit.fitWidth,
      );
      expect(validTarget.logicalWidth, 360.4);
      expect(validTarget.logicalHeight, 640.0);
      expect(validTarget.devicePixelRatio, 2.0);
      expect(validTarget.physicalWidth, 721);
      expect(validTarget.physicalHeight, 1280);
      expect(validTarget.cacheIdentity, 'w721-h1280-fitWidth');

      expect(
        ComicImageTargetFit.fromString('fitWidth'),
        ComicImageTargetFit.fitWidth,
      );
      expect(
        ComicImageTargetFit.fromString('fitHeight'),
        ComicImageTargetFit.fitHeight,
      );
      expect(
        ComicImageTargetFit.fromString('contain'),
        ComicImageTargetFit.contain,
      );
      expect(ComicImageTargetFit.fromString(null), ComicImageTargetFit.contain);
      expect(
        ComicImageTargetFit.fromString('other'),
        ComicImageTargetFit.contain,
      );

      final targetA1 = ComicImageLoadTarget(
        logicalWidth: 100,
        logicalHeight: 200,
        devicePixelRatio: 2.0,
        fit: ComicImageTargetFit.contain,
      );
      final targetA2 = ComicImageLoadTarget(
        logicalWidth: 100,
        logicalHeight: 200,
        devicePixelRatio: 2.0,
        fit: ComicImageTargetFit.contain,
      );
      final targetB = ComicImageLoadTarget(
        logicalWidth: 100,
        logicalHeight: 200,
        devicePixelRatio: 2.0,
        fit: ComicImageTargetFit.fitHeight,
      );

      expect(targetA1, equals(targetA2));
      expect(targetA1.hashCode, equals(targetA2.hashCode));
      expect(targetA1.cacheIdentity, equals(targetA2.cacheIdentity));
      expect(targetA1, isNot(equals(targetB)));

      final keyA1 = ImageDownloader.getComicImageCacheKey(
        'img',
        'src',
        'cid',
        'eid',
        target: targetA1,
      );
      final keyA2 = ImageDownloader.getComicImageCacheKey(
        'img',
        'src',
        'cid',
        'eid',
        target: targetA2,
      );
      final keyB = ImageDownloader.getComicImageCacheKey(
        'img',
        'src',
        'cid',
        'eid',
        target: targetB,
      );
      final keyNull = ImageDownloader.getComicImageCacheKey(
        'img',
        'src',
        'cid',
        'eid',
      );

      expect(keyA1, equals(keyA2));
      expect(keyA1, isNot(equals(keyB)));
      expect(keyA1, isNot(equals(keyNull)));
      expect(keyNull, 'img@src@cid@eid');
      expect(keyA1, 'img@src@cid@eid@${targetA1.cacheIdentity}');
    });

    test(
      'loadComicImage forwards target and shares stream for identical target',
      () async {
        final source = StreamController<ImageDownloadProgress>();
        addTearDown(() async {
          if (!source.isClosed) {
            await source.close();
          }
        });

        var loaderCalls = 0;
        ComicImageLoadTarget? receivedTarget;

        ImageDownloader.debugLoadComicImageUnwrapped =
            (imageKey, sourceKey, cid, eid, {target}) {
              loaderCalls++;
              receivedTarget = target;
              return source.stream;
            };

        final target = ComicImageLoadTarget(
          logicalWidth: 200,
          logicalHeight: 300,
          devicePixelRatio: 2.0,
          fit: ComicImageTargetFit.contain,
        );

        final events1 = <ImageDownloadProgress>[];
        final events2 = <ImageDownloadProgress>[];

        final sub1 = ImageDownloader.loadComicImage(
          'shared-image',
          'source',
          'comic',
          'ep',
          target: target,
        ).listen(events1.add);
        final sub2 = ImageDownloader.loadComicImage(
          'shared-image',
          'source',
          'comic',
          'ep',
          target: target,
        ).listen(events2.add);

        await pumpEventQueue();

        expect(loaderCalls, 1);
        expect(receivedTarget, equals(target));

        final progress = ImageDownloadProgress(
          currentBytes: 50,
          totalBytes: 100,
          imageBytes: Uint8List.fromList([1, 2, 3]),
        );
        source.add(progress);
        await pumpEventQueue();

        expect(events1, hasLength(1));
        expect(events2, hasLength(1));
        expect(events1.first.currentBytes, 50);
        expect(events2.first.currentBytes, 50);

        await sub1.cancel();
        await sub2.cancel();
      },
    );

    test(
      'loadComicImage isolates streams and cancellation across different targets',
      () async {
        final sourceCanceledA = Completer<void>();
        final sourceA = StreamController<ImageDownloadProgress>(
          onCancel: () {
            if (!sourceCanceledA.isCompleted) {
              sourceCanceledA.complete();
            }
          },
        );
        final sourceB = StreamController<ImageDownloadProgress>();
        final sourceNone = StreamController<ImageDownloadProgress>();
        addTearDown(() async {
          if (!sourceA.isClosed) await sourceA.close();
          if (!sourceB.isClosed) await sourceB.close();
          if (!sourceNone.isClosed) await sourceNone.close();
        });

        final targetsReceived = <ComicImageLoadTarget?>[];
        final targetA = ComicImageLoadTarget(
          logicalWidth: 100,
          fit: ComicImageTargetFit.fitWidth,
        );
        final targetB = ComicImageLoadTarget(
          logicalHeight: 200,
          fit: ComicImageTargetFit.fitHeight,
        );

        ImageDownloader.debugLoadComicImageUnwrapped =
            (imageKey, sourceKey, cid, eid, {target}) {
              targetsReceived.add(target);
              if (target == targetA) return sourceA.stream;
              if (target == targetB) return sourceB.stream;
              return sourceNone.stream;
            };

        final eventsA = <ImageDownloadProgress>[];
        final eventsB = <ImageDownloadProgress>[];
        final eventsNone = <ImageDownloadProgress>[];

        final subA = ImageDownloader.loadComicImage(
          'iso-image',
          'src',
          'cid',
          'eid',
          target: targetA,
        ).listen(eventsA.add);
        final subB = ImageDownloader.loadComicImage(
          'iso-image',
          'src',
          'cid',
          'eid',
          target: targetB,
        ).listen(eventsB.add);
        final subNone = ImageDownloader.loadComicImage(
          'iso-image',
          'src',
          'cid',
          'eid',
        ).listen(eventsNone.add);

        await pumpEventQueue();

        expect(targetsReceived, hasLength(3));
        expect(targetsReceived, containsAllInOrder([targetA, targetB, isNull]));

        sourceA.add(ImageDownloadProgress(currentBytes: 10, totalBytes: 10));
        await pumpEventQueue();

        expect(eventsA, hasLength(1));
        expect(eventsB, isEmpty);
        expect(eventsNone, isEmpty);

        await subA.cancel();
        await sourceCanceledA.future.timeout(const Duration(seconds: 1));
        expect(sourceB.hasListener, isTrue);
        expect(sourceNone.hasListener, isTrue);

        await subB.cancel();
        await subNone.cancel();
      },
    );

    test(
      'loadComicImage preserves shared stream when UI listener cancels while preload is active',
      () async {
        final sourceCanceled = Completer<void>();
        final source = StreamController<ImageDownloadProgress>(
          onCancel: () {
            if (!sourceCanceled.isCompleted) {
              sourceCanceled.complete();
            }
          },
        );
        addTearDown(() async {
          if (!source.isClosed) {
            await source.close();
          }
        });

        final target = ComicImageLoadTarget(
          logicalWidth: 150,
          devicePixelRatio: 2.0,
        );

        ImageDownloader.debugLoadComicImageUnwrapped =
            (imageKey, sourceKey, cid, eid, {target}) => source.stream;

        final preloadFuture = ImageDownloader.preloadComicImage(
          'preload-active-image',
          'src',
          'cid',
          'eid',
          target: target,
        );
        await pumpEventQueue();

        final uiSub = ImageDownloader.loadComicImage(
          'preload-active-image',
          'src',
          'cid',
          'eid',
          target: target,
        ).listen((_) {});
        await pumpEventQueue();

        await uiSub.cancel();
        await pumpEventQueue();

        expect(sourceCanceled.isCompleted, isFalse);

        source.add(
          ImageDownloadProgress(
            currentBytes: 100,
            totalBytes: 100,
            imageBytes: Uint8List.fromList([4, 5, 6]),
          ),
        );
        await source.close();
        await preloadFuture.timeout(const Duration(seconds: 1));
      },
    );

    test(
      'loadComicImage preserves shared stream until last of multiple UI listeners cancels',
      () async {
        final sourceCanceled = Completer<void>();
        final source = StreamController<ImageDownloadProgress>(
          onCancel: () {
            if (!sourceCanceled.isCompleted) {
              sourceCanceled.complete();
            }
          },
        );
        addTearDown(() async {
          if (!source.isClosed) {
            await source.close();
          }
        });

        final target = ComicImageLoadTarget(logicalWidth: 120);

        ImageDownloader.debugLoadComicImageUnwrapped =
            (imageKey, sourceKey, cid, eid, {target}) => source.stream;

        final events2 = <ImageDownloadProgress>[];
        final sub1 = ImageDownloader.loadComicImage(
          'multi-ui-image',
          'src',
          'cid',
          'eid',
          target: target,
        ).listen((_) {});
        final sub2 = ImageDownloader.loadComicImage(
          'multi-ui-image',
          'src',
          'cid',
          'eid',
          target: target,
        ).listen(events2.add);
        await pumpEventQueue();

        await sub1.cancel();
        await pumpEventQueue();

        expect(sourceCanceled.isCompleted, isFalse);

        source.add(ImageDownloadProgress(currentBytes: 25, totalBytes: 50));
        await pumpEventQueue();

        expect(events2, hasLength(1));
        expect(events2.first.currentBytes, 25);

        await sub2.cancel();
        await sourceCanceled.future.timeout(const Duration(seconds: 1));
      },
    );

    test(
      'cancelAllLoadingImages ends in-flight preloadComicImage and cancels source stream',
      () async {
        final sourceCanceled = Completer<void>();
        final source = StreamController<ImageDownloadProgress>(
          onCancel: () {
            if (!sourceCanceled.isCompleted) {
              sourceCanceled.complete();
            }
          },
        );
        addTearDown(() async {
          if (!source.isClosed) {
            await source.close();
          }
        });

        final target = ComicImageLoadTarget(logicalHeight: 400);

        ImageDownloader.debugLoadComicImageUnwrapped =
            (imageKey, sourceKey, cid, eid, {target}) => source.stream;

        final preloadFuture = ImageDownloader.preloadComicImage(
          'preload-cancel-all-image',
          'src',
          'cid',
          'eid',
          target: target,
        );
        await pumpEventQueue();

        ImageDownloader.cancelAllLoadingImages();

        await sourceCanceled.future.timeout(const Duration(seconds: 1));
        await preloadFuture.timeout(const Duration(seconds: 1));
      },
    );

    test(
      'loadComicImageUnwrapped forwards target parameter to debug loader',
      () async {
        ComicImageLoadTarget? receivedTarget;
        final expectedEvent = ImageDownloadProgress(
          currentBytes: 1,
          totalBytes: 1,
        );

        ImageDownloader.debugLoadComicImageUnwrapped =
            (imageKey, sourceKey, cid, eid, {target}) {
              receivedTarget = target;
              return Stream<ImageDownloadProgress>.value(expectedEvent);
            };
        addTearDown(() {
          ImageDownloader.debugLoadComicImageUnwrapped = null;
        });

        final target = ComicImageLoadTarget(
          logicalWidth: 160,
          logicalHeight: 240,
          fit: ComicImageTargetFit.fitHeight,
        );

        final stream = ImageDownloader.loadComicImageUnwrapped(
          'unwrapped-target-image',
          'src',
          'cid',
          'eid',
          target: target,
        );

        final events = await stream.toList();

        expect(receivedTarget, equals(target));
        expect(events, equals([expectedEvent]));

        ImageDownloader.debugLoadComicImageUnwrapped = null;
      },
    );
  });

  test(
    'loadComicImageUnwrapped returns cached image without network request',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-image-cache-data-',
      );

      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-image-cache-cache-',
      );

      addTearDown(() {
        CacheManager.resetForTesting();

        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }

        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;

      CacheManager.debugDisableInitialScan = true;

      const imageKey = 'http://127.0.0.1:9/cached-image.jpg';
      const String? sourceKey = null;
      const cid = 'test-comic';
      const eid = 'test-episode';

      final cacheKey = '$imageKey@$sourceKey@$cid@$eid';

      final imageBytes = Uint8List.fromList([1, 2, 3, 4]);

      await CacheManager().writeCache(cacheKey, imageBytes);

      final events = await ImageDownloader.loadComicImageUnwrapped(
        imageKey,
        sourceKey,
        cid,
        eid,
      ).toList();

      expect(events, hasLength(1));

      expect(events.single.imageBytes, orderedEquals(imageBytes));
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );
}
