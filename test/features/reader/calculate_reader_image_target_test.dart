import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/comic_image.dart';
import 'package:venera_next/features/reader/images.dart';
import 'package:venera_next/features/reader/reader.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/network/images.dart';

void main() {
  const viewport = Size(1000, 1600);

  group('calculateReaderImageTarget - Gallery single image', () {
    test(
      'imagesPerPage == 1 uses full viewport and contain fit across gallery modes',
      () {
        const modes = [
          ReaderMode.galleryLeftToRight,
          ReaderMode.galleryRightToLeft,
          ReaderMode.galleryTopToBottom,
        ];

        for (final mode in modes) {
          final target = calculateReaderImageTarget(
            mode: mode,
            viewportSize: viewport,
            devicePixelRatio: 2.0,
            page: 1,
            totalImages: 10,
            imagesPerPage: 1,
          );

          expect(target.logicalWidth, 1000.0);
          expect(target.logicalHeight, 1600.0);
          expect(target.fit, ComicImageTargetFit.contain);
          expect(target.devicePixelRatio, 2.0);
          expect(target.physicalWidth, 2000);
          expect(target.physicalHeight, 3200);
          expect(target.cacheIdentity, 'w2000-h3200-dpr2.0-contain-splitfalse');
        }
      },
    );

    test('page <= 0 falls back to full viewport contain target', () {
      final targetZero = calculateReaderImageTarget(
        mode: ReaderMode.galleryLeftToRight,
        viewportSize: viewport,
        devicePixelRatio: 1.5,
        page: 0,
        totalImages: 10,
        imagesPerPage: 2,
      );
      expect(targetZero.logicalWidth, 1000.0);
      expect(targetZero.logicalHeight, 1600.0);
      expect(targetZero.fit, ComicImageTargetFit.contain);

      final targetNegative = calculateReaderImageTarget(
        mode: ReaderMode.galleryTopToBottom,
        viewportSize: viewport,
        devicePixelRatio: 1.0,
        page: -1,
        totalImages: 10,
        imagesPerPage: 2,
      );
      expect(targetNegative.logicalWidth, 1000.0);
      expect(targetNegative.logicalHeight, 1600.0);
      expect(targetNegative.fit, ComicImageTargetFit.contain);
    });
  });

  group('calculateReaderImageTarget - Gallery horizontal dual page', () {
    test('dual page splits width in half and preserves full height', () {
      const modes = [
        ReaderMode.galleryLeftToRight,
        ReaderMode.galleryRightToLeft,
      ];

      for (final mode in modes) {
        final target = calculateReaderImageTarget(
          mode: mode,
          viewportSize: viewport,
          devicePixelRatio: 2.0,
          page: 3,
          totalImages: 10,
          imagesPerPage: 2,
          showSingleImageOnFirstPage: false,
        );

        expect(target.logicalWidth, 500.0);
        expect(target.logicalHeight, 1600.0);
        expect(target.fit, ComicImageTargetFit.contain);
        expect(target.physicalWidth, 1000);
        expect(target.physicalHeight, 3200);
        expect(target.cacheIdentity, 'w1000-h3200-dpr2.0-contain-splitfalse');
      }
    });
  });

  group('calculateReaderImageTarget - Gallery vertical dual page', () {
    test(
      'vertical dual page preserves full width and splits height in half',
      () {
        final target = calculateReaderImageTarget(
          mode: ReaderMode.galleryTopToBottom,
          viewportSize: viewport,
          devicePixelRatio: 2.0,
          page: 3,
          totalImages: 10,
          imagesPerPage: 2,
          showSingleImageOnFirstPage: false,
        );

        expect(target.logicalWidth, 1000.0);
        expect(target.logicalHeight, 800.0);
        expect(target.fit, ComicImageTargetFit.contain);
        expect(target.physicalWidth, 2000);
        expect(target.physicalHeight, 1600);
        expect(target.cacheIdentity, 'w2000-h1600-dpr2.0-contain-splitfalse');
      },
    );
  });

  group('calculateReaderImageTarget - Cover and odd trailing page', () {
    test(
      'with showSingleImageOnFirstPage: true, cover is single, pairs are dual, odd tail is single',
      () {
        // Total 8 pages:
        // Page 1: Cover (single)
        // Pages 2-3: Pair 1 (dual)
        // Pages 4-5: Pair 2 (dual)
        // Pages 6-7: Pair 3 (dual)
        // Page 8: Odd tail (single, pairStart = 8 == totalImages)
        const totalImages = 8;

        final coverTarget = calculateReaderImageTarget(
          mode: ReaderMode.galleryLeftToRight,
          viewportSize: viewport,
          devicePixelRatio: 1.0,
          page: 1,
          totalImages: totalImages,
          imagesPerPage: 2,
          showSingleImageOnFirstPage: true,
        );
        expect(coverTarget.logicalWidth, 1000.0);
        expect(coverTarget.logicalHeight, 1600.0);

        final pairTargetPage2 = calculateReaderImageTarget(
          mode: ReaderMode.galleryLeftToRight,
          viewportSize: viewport,
          devicePixelRatio: 1.0,
          page: 2,
          totalImages: totalImages,
          imagesPerPage: 2,
          showSingleImageOnFirstPage: true,
        );
        expect(pairTargetPage2.logicalWidth, 500.0);
        expect(pairTargetPage2.logicalHeight, 1600.0);

        final pairTargetPage3 = calculateReaderImageTarget(
          mode: ReaderMode.galleryLeftToRight,
          viewportSize: viewport,
          devicePixelRatio: 1.0,
          page: 3,
          totalImages: totalImages,
          imagesPerPage: 2,
          showSingleImageOnFirstPage: true,
        );
        expect(pairTargetPage3.logicalWidth, 500.0);
        expect(pairTargetPage3.logicalHeight, 1600.0);

        final oddTailTarget = calculateReaderImageTarget(
          mode: ReaderMode.galleryLeftToRight,
          viewportSize: viewport,
          devicePixelRatio: 1.0,
          page: 8,
          totalImages: totalImages,
          imagesPerPage: 2,
          showSingleImageOnFirstPage: true,
        );
        expect(oddTailTarget.logicalWidth, 1000.0);
        expect(oddTailTarget.logicalHeight, 1600.0);
      },
    );

    test(
      'with showSingleImageOnFirstPage: true and odd total pages, last pair is dual',
      () {
        // Total 7 pages:
        // Page 1: Cover (single)
        // Pages 2-3: Pair 1 (dual)
        // Pages 4-5: Pair 2 (dual)
        // Pages 6-7: Pair 3 (dual, pairStart = 6 != 7)
        const totalImages = 7;

        final page6Target = calculateReaderImageTarget(
          mode: ReaderMode.galleryTopToBottom,
          viewportSize: viewport,
          devicePixelRatio: 1.0,
          page: 6,
          totalImages: totalImages,
          imagesPerPage: 2,
          showSingleImageOnFirstPage: true,
        );
        expect(page6Target.logicalWidth, 1000.0);
        expect(page6Target.logicalHeight, 800.0);

        final page7Target = calculateReaderImageTarget(
          mode: ReaderMode.galleryTopToBottom,
          viewportSize: viewport,
          devicePixelRatio: 1.0,
          page: 7,
          totalImages: totalImages,
          imagesPerPage: 2,
          showSingleImageOnFirstPage: true,
        );
        expect(page7Target.logicalWidth, 1000.0);
        expect(page7Target.logicalHeight, 800.0);
      },
    );

    test(
      'with showSingleImageOnFirstPage: false, page 1 is dual, odd tail is single',
      () {
        // Total 5 pages:
        // Pages 1-2: Pair 1 (dual)
        // Pages 3-4: Pair 2 (dual)
        // Page 5: Odd tail (single, pairStart = 5 == totalImages)
        const totalImages = 5;

        final page1Target = calculateReaderImageTarget(
          mode: ReaderMode.galleryLeftToRight,
          viewportSize: viewport,
          devicePixelRatio: 1.0,
          page: 1,
          totalImages: totalImages,
          imagesPerPage: 2,
          showSingleImageOnFirstPage: false,
        );
        expect(page1Target.logicalWidth, 500.0);
        expect(page1Target.logicalHeight, 1600.0);

        final page2Target = calculateReaderImageTarget(
          mode: ReaderMode.galleryLeftToRight,
          viewportSize: viewport,
          devicePixelRatio: 1.0,
          page: 2,
          totalImages: totalImages,
          imagesPerPage: 2,
          showSingleImageOnFirstPage: false,
        );
        expect(page2Target.logicalWidth, 500.0);
        expect(page2Target.logicalHeight, 1600.0);

        final oddTailTarget = calculateReaderImageTarget(
          mode: ReaderMode.galleryLeftToRight,
          viewportSize: viewport,
          devicePixelRatio: 1.0,
          page: 5,
          totalImages: totalImages,
          imagesPerPage: 2,
          showSingleImageOnFirstPage: false,
        );
        expect(oddTailTarget.logicalWidth, 1000.0);
        expect(oddTailTarget.logicalHeight, 1600.0);
      },
    );
  });

  group('calculateReaderImageTarget - Continuous vertical fitWidth', () {
    test(
      'continuousTopToBottom and waterfallTopToBottom set logicalWidth and null logicalHeight',
      () {
        const verticalModes = [
          ReaderMode.continuousTopToBottom,
          ReaderMode.waterfallTopToBottom,
        ];

        for (final mode in verticalModes) {
          final target = calculateReaderImageTarget(
            mode: mode,
            viewportSize: const Size(480, 960),
            devicePixelRatio: 2.5,
            page: 1,
            totalImages: 20,
          );

          expect(target.logicalWidth, 480.0);
          expect(target.logicalHeight, isNull);
          expect(target.fit, ComicImageTargetFit.fitWidth);
          expect(target.devicePixelRatio, 2.5);
          expect(target.physicalWidth, 1200);
          expect(target.physicalHeight, isNull);
          expect(
            target.cacheIdentity,
            'w1200-hnull-dpr2.5-fitWidth-splitfalse',
          );
        }
      },
    );
  });

  group('calculateReaderImageTarget - Continuous horizontal fitHeight', () {
    test(
      'continuousLeftToRight and continuousRightToLeft set null logicalWidth and logicalHeight',
      () {
        const horizontalModes = [
          ReaderMode.continuousLeftToRight,
          ReaderMode.continuousRightToLeft,
        ];

        for (final mode in horizontalModes) {
          final target = calculateReaderImageTarget(
            mode: mode,
            viewportSize: const Size(600, 1000),
            devicePixelRatio: 3.0,
            page: 2,
            totalImages: 15,
          );

          expect(target.logicalWidth, isNull);
          expect(target.logicalHeight, 1000.0);
          expect(target.fit, ComicImageTargetFit.fitHeight);
          expect(target.devicePixelRatio, 3.0);
          expect(target.physicalWidth, isNull);
          expect(target.physicalHeight, 3000);
          expect(
            target.cacheIdentity,
            'wnull-h3000-dpr3.0-fitHeight-splitfalse',
          );
        }
      },
    );
  });

  group('calculateReaderImageTarget - Device Pixel Ratio (DPR)', () {
    test('scales physical dimensions according to DPR with rounding', () {
      final targetDpr1 = calculateReaderImageTarget(
        mode: ReaderMode.galleryLeftToRight,
        viewportSize: const Size(375, 812),
        devicePixelRatio: 1.0,
        page: 1,
        totalImages: 1,
      );
      expect(targetDpr1.physicalWidth, 375);
      expect(targetDpr1.physicalHeight, 812);

      final targetDpr2 = calculateReaderImageTarget(
        mode: ReaderMode.galleryLeftToRight,
        viewportSize: const Size(375, 812),
        devicePixelRatio: 2.0,
        page: 1,
        totalImages: 1,
      );
      expect(targetDpr2.physicalWidth, 750);
      expect(targetDpr2.physicalHeight, 1624);

      final targetDpr2625 = calculateReaderImageTarget(
        mode: ReaderMode.galleryLeftToRight,
        viewportSize: const Size(411.4, 891.4),
        devicePixelRatio: 2.625,
        page: 1,
        totalImages: 1,
      );
      expect(targetDpr2625.physicalWidth, (411.4 * 2.625).round());
      expect(targetDpr2625.physicalHeight, (891.4 * 2.625).round());
    });

    test('invalid non-positive or infinite DPR defaults to 1.0', () {
      final targetZeroDpr = calculateReaderImageTarget(
        mode: ReaderMode.galleryLeftToRight,
        viewportSize: const Size(400, 800),
        devicePixelRatio: 0.0,
        page: 1,
        totalImages: 1,
      );
      expect(targetZeroDpr.devicePixelRatio, 1.0);
      expect(targetZeroDpr.physicalWidth, 400);
      expect(targetZeroDpr.physicalHeight, 800);

      final targetNegDpr = calculateReaderImageTarget(
        mode: ReaderMode.galleryLeftToRight,
        viewportSize: const Size(400, 800),
        devicePixelRatio: -2.0,
        page: 1,
        totalImages: 1,
      );
      expect(targetNegDpr.devicePixelRatio, 1.0);
      expect(targetNegDpr.physicalWidth, 400);
      expect(targetNegDpr.physicalHeight, 800);
    });
  });

  group('calculateReaderContentSize', () {
    test(
      '1920x1080 waterfall/continuous with limit=true limits width to 756',
      () {
        const size = Size(1920, 1080);
        // 1080 * 0.7 = 756.0
        final waterfall = calculateReaderContentSize(
          mode: ReaderMode.waterfallTopToBottom,
          viewportSize: size,
          limitImageWidth: true,
        );
        expect(waterfall.width, 756.0);
        expect(waterfall.height, 1080.0);

        final continuous = calculateReaderContentSize(
          mode: ReaderMode.continuousTopToBottom,
          viewportSize: size,
          limitImageWidth: true,
        );
        expect(continuous.width, 756.0);
        expect(continuous.height, 1080.0);
      },
    );

    test(
      'limit=false preserves original dimensions without limiting width',
      () {
        const size = Size(1920, 1080);
        final waterfall = calculateReaderContentSize(
          mode: ReaderMode.waterfallTopToBottom,
          viewportSize: size,
          limitImageWidth: false,
        );
        expect(waterfall.width, 1920.0);
        expect(waterfall.height, 1080.0);

        final continuous = calculateReaderContentSize(
          mode: ReaderMode.continuousTopToBottom,
          viewportSize: size,
          limitImageWidth: false,
        );
        expect(continuous.width, 1920.0);
        expect(continuous.height, 1080.0);
      },
    );

    test(
      'narrow viewport (width/height <= 0.7) is not limited even when limit=true',
      () {
        // 500 / 1000 = 0.5 <= 0.7
        const narrowSize = Size(500, 1000);
        final waterfall = calculateReaderContentSize(
          mode: ReaderMode.waterfallTopToBottom,
          viewportSize: narrowSize,
          limitImageWidth: true,
        );
        expect(waterfall.width, 500.0);
        expect(waterfall.height, 1000.0);

        // exactly 700 / 1000 = 0.7
        const exactSize = Size(700, 1000);
        final exact = calculateReaderContentSize(
          mode: ReaderMode.continuousTopToBottom,
          viewportSize: exactSize,
          limitImageWidth: true,
        );
        expect(exact.width, 700.0);
        expect(exact.height, 1000.0);
      },
    );

    test('Gallery modes are never limited regardless of limit setting', () {
      const size = Size(1920, 1080);
      for (final mode in [
        ReaderMode.galleryLeftToRight,
        ReaderMode.galleryRightToLeft,
        ReaderMode.galleryTopToBottom,
      ]) {
        final contentSize = calculateReaderContentSize(
          mode: mode,
          viewportSize: size,
          limitImageWidth: true,
        );
        expect(contentSize.width, 1920.0);
        expect(contentSize.height, 1080.0);
      }
    });

    test('invalid or zero sizes are safely handled and clamped', () {
      expect(
        calculateReaderContentSize(
          mode: ReaderMode.continuousTopToBottom,
          viewportSize: const Size(0, 0),
          limitImageWidth: true,
        ),
        const Size(0, 0),
      );

      expect(
        calculateReaderContentSize(
          mode: ReaderMode.continuousTopToBottom,
          viewportSize: const Size(-100, 500),
          limitImageWidth: true,
        ),
        const Size(0, 500),
      );

      expect(
        calculateReaderContentSize(
          mode: ReaderMode.continuousTopToBottom,
          viewportSize: const Size(500, -200),
          limitImageWidth: true,
        ),
        const Size(500, 0),
      );

      expect(
        calculateReaderContentSize(
          mode: ReaderMode.continuousTopToBottom,
          viewportSize: const Size(double.nan, double.infinity),
          limitImageWidth: true,
        ),
        const Size(0, 0),
      );
    });
  });

  group('calculateReaderImageTarget - limitImageWidth and splitWideImage', () {
    test(
      '1920x1080 waterfall/continuous TopToBottom with limitImageWidth yields physicalWidth 1512 at DPR 2.0',
      () {
        const size = Size(1920, 1080);
        final targetWaterfall = calculateReaderImageTarget(
          mode: ReaderMode.waterfallTopToBottom,
          viewportSize: size,
          devicePixelRatio: 2.0,
          page: 1,
          totalImages: 10,
          limitImageWidth: true,
        );
        // logicalWidth = 756.0, DPR = 2.0 -> physicalWidth = 1512
        expect(targetWaterfall.logicalWidth, 756.0);
        expect(targetWaterfall.logicalHeight, isNull);
        expect(targetWaterfall.physicalWidth, 1512);
        expect(targetWaterfall.physicalHeight, isNull);
        expect(targetWaterfall.fit, ComicImageTargetFit.fitWidth);
        expect(targetWaterfall.splitWideImage, isFalse);
        expect(
          targetWaterfall.cacheIdentity,
          'w1512-hnull-dpr2.0-fitWidth-splitfalse',
        );

        final targetContinuous = calculateReaderImageTarget(
          mode: ReaderMode.continuousTopToBottom,
          viewportSize: size,
          devicePixelRatio: 2.0,
          page: 1,
          totalImages: 10,
          limitImageWidth: true,
          splitWideImage: true,
        );
        expect(targetContinuous.logicalWidth, 756.0);
        expect(targetContinuous.physicalWidth, 1512);
        expect(targetContinuous.splitWideImage, isTrue);
        expect(
          targetContinuous.cacheIdentity,
          'w1512-hnull-dpr2.0-fitWidth-splittrue',
        );
      },
    );

    test('splitWideImage is preserved in Gallery when imagesPerPage is 1', () {
      final target = calculateReaderImageTarget(
        mode: ReaderMode.galleryLeftToRight,
        viewportSize: const Size(1000, 1600),
        devicePixelRatio: 2.0,
        page: 1,
        totalImages: 10,
        imagesPerPage: 1,
        splitWideImage: true,
      );
      expect(target.splitWideImage, isTrue);
      expect(target.cacheIdentity, 'w2000-h3200-dpr2.0-contain-splittrue');
    });

    test(
      'splitWideImage is enabled in Continuous and Waterfall top-to-bottom',
      () {
        for (final mode in [
          ReaderMode.continuousTopToBottom,
          ReaderMode.waterfallTopToBottom,
        ]) {
          final target = calculateReaderImageTarget(
            mode: mode,
            viewportSize: const Size(1000, 1600),
            devicePixelRatio: 2.0,
            page: 1,
            totalImages: 10,
            splitWideImage: true,
          );
          expect(target.splitWideImage, isTrue);
          expect(target.fit, ComicImageTargetFit.fitWidth);
        }
      },
    );

    test('splitWideImage is false in horizontal Continuous modes', () {
      for (final mode in [
        ReaderMode.continuousLeftToRight,
        ReaderMode.continuousRightToLeft,
      ]) {
        final target = calculateReaderImageTarget(
          mode: mode,
          viewportSize: const Size(1000, 1600),
          devicePixelRatio: 2.0,
          page: 1,
          totalImages: 10,
          splitWideImage: false,
        );
        expect(target.splitWideImage, isFalse);
        expect(target.fit, ComicImageTargetFit.fitHeight);
      }
    });
  });

  group('Continuous layout and Provider target alignment', () {
    testWidgets(
      'Continuous actual layout width and Provider target width are co-sourced and splitWideImage matches',
      (tester) async {
        final testImage = await _createTestUiImage(width: 100, height: 100);
        addTearDown(testImage.dispose);
        final provider = _TestUiImageProvider(testImage);

        const viewportSize = Size(1920, 1080);
        const dpr = 2.0;

        // Sourced directly from calculateReaderContentSize & calculateReaderImageTarget:
        final contentSize = calculateReaderContentSize(
          mode: ReaderMode.continuousTopToBottom,
          viewportSize: viewportSize,
          limitImageWidth: true,
        );
        final target = calculateReaderImageTarget(
          mode: ReaderMode.continuousTopToBottom,
          viewportSize: viewportSize,
          devicePixelRatio: dpr,
          page: 1,
          totalImages: 10,
          limitImageWidth: true,
          splitWideImage: true,
        );

        // Assert target width is co-sourced with contentSize
        expect(target.logicalWidth, contentSize.width);
        expect(target.physicalWidth, (contentSize.width * dpr).round());

        // Continuous layout wrapper renders child constrained by contentSize.width
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: contentSize.width,
                child: ComicImage(
                  image: provider,
                  splitWideImage: target.splitWideImage,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final comicImageFinder = find.byType(ComicImage);
        expect(comicImageFinder, findsOneWidget);

        final actualRenderedSize = tester.getSize(comicImageFinder);
        expect(actualRenderedSize.width, target.logicalWidth);
        expect(actualRenderedSize.width, 756.0);

        final comicImageWidget = tester.widget<ComicImage>(comicImageFinder);
        expect(comicImageWidget.splitWideImage, target.splitWideImage);
        expect(comicImageWidget.splitWideImage, isTrue);
      },
    );
  });

  group('ReaderImageReference cross-chapter eid and original image loading', () {
    test(
      'Waterfall cross-chapter image reference retains respective chapter eid',
      () {
        final flow = WaterfallChapterFlow(
          segments: [
            WaterfallChapterSegment(
              chapter: 1,
              eid: 'ep-chapter-1',
              images: ['c1-p1', 'c1-p2', 'c1-p3'],
            ),
            WaterfallChapterSegment(
              chapter: 2,
              eid: 'ep-chapter-2',
              images: ['c2-p1', 'c2-p2'],
            ),
          ],
        );

        // Index 4 corresponds to chapter 2, page 1 (1-based global index in Waterfall)
        final imageRef = flow.imageRefAt(4);
        expect(imageRef, isNotNull);
        expect(imageRef!.chapter, 2);
        expect(imageRef.eid, 'ep-chapter-2');
        expect(imageRef.page, 1);

        final readerRef = ReaderImageReference(
          imageKey: imageRef.imageKey,
          sourceKey: 'test-source',
          cid: 'test-comic',
          eid: imageRef.eid,
          page: imageRef.page,
        );

        expect(readerRef.eid, 'ep-chapter-2');
        expect(readerRef.eid, isNot('ep-chapter-1'));
      },
    );

    test(
      'original image read path uses target: null instead of display resize target',
      () async {
        ComicImageLoadTarget? observedTarget;
        var wasHookCalled = false;

        final originalLoader = ImageDownloader.debugLoadComicImageUnwrapped;
        ImageDownloader.debugLoadComicImageUnwrapped =
            (imageKey, sourceKey, cid, eid, {target}) {
              wasHookCalled = true;
              observedTarget = target;
              return Stream.value(
                ImageDownloadProgress(
                  currentBytes: 1,
                  totalBytes: 1,
                  imageBytes: Uint8List.fromList([1, 2, 3, 4]),
                ),
              );
            };

        try {
          final readerRef = ReaderImageReference(
            imageKey: 'test-key',
            sourceKey: 'test-source',
            cid: 'test-cid',
            eid: 'ep-chapter-2',
            page: 1,
          );

          // Load original image bytes using the original image read path (target: null)
          final bytes = await ImageDownloader.loadComicImageBytes(
            readerRef.imageKey,
            readerRef.sourceKey,
            readerRef.cid,
            readerRef.eid,
            target: null,
          );

          expect(wasHookCalled, isTrue);
          expect(observedTarget, isNull);
          expect(bytes, [1, 2, 3, 4]);
        } finally {
          ImageDownloader.debugLoadComicImageUnwrapped = originalLoader;
        }
      },
    );
  });
}

Future<ui.Image> _createTestUiImage({int width = 100, int height = 100}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(
    recorder,
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
  );
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF00FF00),
  );
  final picture = recorder.endRecording();
  return picture.toImage(width, height);
}

class _TestUiImageProvider extends ImageProvider<_TestUiImageProvider> {
  _TestUiImageProvider(this.image);

  final ui.Image image;

  @override
  Future<_TestUiImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<_TestUiImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    _TestUiImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(
      SynchronousFuture<ImageInfo>(ImageInfo(image: image, scale: 1.0)),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _TestUiImageProvider &&
          runtimeType == other.runtimeType &&
          image == other.image;

  @override
  int get hashCode => image.hashCode;
}
