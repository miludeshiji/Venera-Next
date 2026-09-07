import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/image_provider/reader_image.dart';
import 'package:flutter/painting.dart';
import 'package:venera_next/network/images.dart';

void main() {
  test('reader image processing waits for future result', () async {
    final cancelSignal = Completer<void>();
    final bytes = Uint8List.fromList([1, 2, 3]);
    var canceled = false;

    final result = await debugWaitForReaderImageProcessingResult(
      Future<Uint8List>.value(bytes),
      () {
        canceled = true;
      },
      () {},
      cancelSignal: cancelSignal.future,
    );

    expect(result, same(bytes));
    expect(canceled, isFalse);
  });

  test('reader image processing cancels through stop signal', () async {
    final image = Completer<Uint8List>();
    final cancelSignal = Completer<void>();
    var canceled = false;
    var checkedStop = false;

    final result = debugWaitForReaderImageProcessingResult(
      image.future,
      () {
        canceled = true;
      },
      () {
        checkedStop = true;
        throw StateError('stopped');
      },
      cancelSignal: cancelSignal.future,
    );

    cancelSignal.complete();

    await expectLater(result, throwsA(isA<StateError>()));
    expect(canceled, isTrue);
    expect(checkedStop, isTrue);
  });

  test('reader image processing keeps null result as empty bytes', () async {
    final cancelSignal = Completer<void>();

    final result = await debugWaitForReaderImageProcessingResult(
      Future<void>.value(),
      () {},
      () {},
      cancelSignal: cancelSignal.future,
    );

    expect(result, isA<Uint8List>());
    expect(result, isEmpty);
  });

  test('reader image processing propagates future errors', () async {
    final cancelSignal = Completer<void>();
    var canceled = false;

    final result = debugWaitForReaderImageProcessingResult(
      Future<Uint8List>.error(StateError('failed')),
      () {
        canceled = true;
      },
      () {},
      cancelSignal: cancelSignal.future,
    );

    await expectLater(result, throwsA(isA<StateError>()));
    expect(canceled, isFalse);
  });

  group('ReaderImageProvider identity & target contract', () {
    tearDown(() {
      ImageDownloader.debugLoadComicImageUnwrapped = null;
      ImageDownloader.cancelAllLoadingImages();
    });

    test(
      'ReaderImageProvider equality, hashCode, key, and diskCacheKey reflect target',
      () {
        final target1 = ComicImageLoadTarget(
          logicalWidth: 200,
          logicalHeight: 300,
          devicePixelRatio: 2.0,
          fit: ComicImageTargetFit.contain,
        );
        final target2 = ComicImageLoadTarget(
          logicalWidth: 200,
          logicalHeight: 300,
          devicePixelRatio: 2.0,
          fit: ComicImageTargetFit.contain,
        );
        final target3 = ComicImageLoadTarget(
          logicalWidth: 200,
          logicalHeight: 300,
          devicePixelRatio: 2.0,
          fit: ComicImageTargetFit.fitWidth,
        );

        final provider1 = ReaderImageProvider(
          'img-1',
          'source-1',
          'comic-1',
          'chapter-1',
          1,
          target: target1,
        );
        final provider2 = ReaderImageProvider(
          'img-1',
          'source-1',
          'comic-1',
          'chapter-1',
          1,
          target: target2,
        );
        final provider3 = ReaderImageProvider(
          'img-1',
          'source-1',
          'comic-1',
          'chapter-1',
          1,
          target: target3,
        );
        const providerNull = ReaderImageProvider(
          'img-1',
          'source-1',
          'comic-1',
          'chapter-1',
          1,
        );

        expect(provider1, equals(provider2));
        expect(provider1.hashCode, equals(provider2.hashCode));
        expect(provider1.key, equals(provider2.key));
        expect(provider1.diskCacheKey, equals(provider2.diskCacheKey));

        expect(provider1, isNot(equals(provider3)));
        expect(provider1.key, isNot(equals(provider3.key)));
        expect(provider1.diskCacheKey, isNot(equals(provider3.diskCacheKey)));

        expect(provider1, isNot(equals(providerNull)));
        expect(provider1.key, isNot(equals(providerNull.key)));
        expect(
          provider1.diskCacheKey,
          isNot(equals(providerNull.diskCacheKey)),
        );

        expect(
          provider1.key,
          'img-1@source-1@comic-1@chapter-1@false@${target1.cacheIdentity}',
        );
        expect(providerNull.key, 'img-1@source-1@comic-1@chapter-1@false');
        expect(
          provider1.diskCacheKey,
          'img-1@source-1@comic-1@chapter-1@${target1.cacheIdentity}',
        );
        expect(providerNull.diskCacheKey, 'img-1@source-1@comic-1@chapter-1');
      },
    );

    test(
      'ReaderImageProvider load forwards target to ImageDownloader and receives bytes',
      () async {
        final source = StreamController<ImageDownloadProgress>();
        addTearDown(() async {
          if (!source.isClosed) {
            await source.close();
          }
        });

        ComicImageLoadTarget? forwardedTarget;
        ImageDownloader.debugLoadComicImageUnwrapped =
            (imageKey, sourceKey, cid, eid, {target}) {
              forwardedTarget = target;
              return source.stream;
            };

        final target = ComicImageLoadTarget(
          logicalWidth: 150,
          logicalHeight: 250,
          fit: ComicImageTargetFit.fitHeight,
        );
        final provider = ReaderImageProvider(
          'http://example.com/test.jpg',
          'src',
          'cid',
          'eid',
          1,
          target: target,
        );

        final chunkEvents = StreamController<ImageChunkEvent>();
        final chunks = <ImageChunkEvent>[];
        chunkEvents.stream.listen(chunks.add);
        addTearDown(() async {
          if (!chunkEvents.isClosed) {
            await chunkEvents.close();
          }
        });

        final expectedBytes = Uint8List.fromList([10, 20, 30, 40]);
        final loadFuture = provider.load(chunkEvents, () {});

        await pumpEventQueue();

        expect(forwardedTarget, equals(target));

        source.add(
          ImageDownloadProgress(
            currentBytes: 4,
            totalBytes: 4,
            imageBytes: expectedBytes,
          ),
        );
        await source.close();

        final resultBytes = await loadFuture;
        expect(resultBytes, orderedEquals(expectedBytes));
        expect(chunks, hasLength(1));
        expect(chunks.first.cumulativeBytesLoaded, 4);
        expect(chunks.first.expectedTotalBytes, 4);
      },
    );
  });
}
