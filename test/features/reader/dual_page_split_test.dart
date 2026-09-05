import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/comic_image.dart';
import 'package:venera_next/features/reader/gallery_page_plan.dart';

Future<ui.Image> createTestUiImage({int width = 120, int height = 80}) async {
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

class TestUiImageProvider extends ImageProvider<TestUiImageProvider> {
  TestUiImageProvider(this.image, {this.tag = 'test'});

  final ui.Image image;
  final String tag;

  @override
  Future<TestUiImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<TestUiImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    TestUiImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(
      SynchronousFuture<ImageInfo>(ImageInfo(image: image)),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TestUiImageProvider &&
          runtimeType == other.runtimeType &&
          tag == other.tag &&
          image == other.image;

  @override
  int get hashCode => Object.hash(image, tag);
}

void main() {
  group('dual page split helpers', () {
    test('detects wide images only', () {
      expect(shouldSplitWideImage(const Size(1200, 800)), isTrue);
      expect(shouldSplitWideImage(const Size(800, 1200)), isFalse);
      expect(shouldSplitWideImage(const Size(1000, 1000)), isFalse);
    });

    test('uses vertical display size for wide images', () {
      expect(
        splitWideImageDisplaySize(const Size(1200, 800)),
        const Size(600, 1600),
      );
      expect(
        splitWideImageDisplaySize(const Size(800, 1200)),
        const Size(800, 1200),
      );
    });

    test('puts right half first by default', () {
      expect(splitWideImageSourceRects(const Size(1200, 800), invert: false), [
        const Rect.fromLTWH(600, 0, 600, 800),
        const Rect.fromLTWH(0, 0, 600, 800),
      ]);
    });

    test('swaps split order when inverted', () {
      expect(splitWideImageSourceRects(const Size(1200, 800), invert: true), [
        const Rect.fromLTWH(0, 0, 600, 800),
        const Rect.fromLTWH(600, 0, 600, 800),
      ]);
    });
  });

  group('wide image single part helpers', () {
    const wideSize = Size(1200, 800);
    const tallSize = Size(800, 1200);

    test('calculates correct source rects for single half parts', () {
      expect(
        wideImagePartSourceRect(wideSize, GalleryImagePart.left),
        const Rect.fromLTWH(0, 0, 600, 800),
      );
      expect(
        wideImagePartSourceRect(wideSize, GalleryImagePart.right),
        const Rect.fromLTWH(600, 0, 600, 800),
      );
      expect(
        wideImagePartSourceRect(wideSize, GalleryImagePart.full),
        const Rect.fromLTWH(0, 0, 1200, 800),
      );
    });

    test(
      'calculates single part display size: wide images halved, non-wide kept full',
      () {
        // Wide image with left/right: width is halved
        expect(
          wideImagePartDisplaySize(wideSize, GalleryImagePart.left),
          const Size(600, 800),
        );
        expect(
          wideImagePartDisplaySize(wideSize, GalleryImagePart.right),
          const Size(600, 800),
        );

        // Wide image with full part: kept full
        expect(
          wideImagePartDisplaySize(wideSize, GalleryImagePart.full),
          wideSize,
        );
        expect(wideImagePartDisplaySize(wideSize, null), wideSize);

        // Non-wide image: always kept full even if left or right requested
        expect(
          wideImagePartDisplaySize(tallSize, GalleryImagePart.left),
          tallSize,
        );
        expect(
          wideImagePartDisplaySize(tallSize, GalleryImagePart.right),
          tallSize,
        );
        expect(
          wideImagePartDisplaySize(tallSize, GalleryImagePart.full),
          tallSize,
        );
      },
    );
  });

  group('size callback deduplication helper', () {
    const keyA = 'imageA';
    const keyB = 'imageB';
    const size1 = Size(1200, 800);
    const size2 = Size(1400, 900);

    test('reports when first resolved', () {
      expect(
        shouldNotifyImageSize(
          lastReportedSize: null,
          lastReportedKey: null,
          currentSize: size1,
          currentKey: keyA,
        ),
        isTrue,
      );
    });

    test('does not report when size and key are unchanged', () {
      expect(
        shouldNotifyImageSize(
          lastReportedSize: size1,
          lastReportedKey: keyA,
          currentSize: size1,
          currentKey: keyA,
        ),
        isFalse,
      );
    });

    test('reports when size changes for the same key', () {
      expect(
        shouldNotifyImageSize(
          lastReportedSize: size1,
          lastReportedKey: keyA,
          currentSize: size2,
          currentKey: keyA,
        ),
        isTrue,
      );
    });

    test('reports when image key changes even if size is identical', () {
      expect(
        shouldNotifyImageSize(
          lastReportedSize: size1,
          lastReportedKey: keyA,
          currentSize: size1,
          currentKey: keyB,
        ),
        isTrue,
      );
    });
  });

  group('ComicImage widget behavior', () {
    late ui.Image wideImage;
    late ui.Image tallImage;

    setUpAll(() async {
      wideImage = await createTestUiImage(width: 120, height: 80);
      tallImage = await createTestUiImage(width: 80, height: 120);
    });

    tearDownAll(() {
      wideImage.dispose();
      tallImage.dispose();
    });

    testWidgets('reports onImageSize once on load and deduplicates rebuilds', (
      tester,
    ) async {
      final reportedSizes = <Size>[];
      final provider = TestUiImageProvider(wideImage, tag: 'provider1');

      await tester.pumpWidget(
        MaterialApp(
          home: ComicImage(
            image: provider,
            onImageSize: (size) => reportedSizes.add(size),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(reportedSizes, [const Size(120, 80)]);

      // Rebuild with same provider
      await tester.pumpWidget(
        MaterialApp(
          home: ComicImage(
            image: provider,
            onImageSize: (size) => reportedSizes.add(size),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // No duplicate callback on rebuild
      expect(reportedSizes.length, 1);
    });

    testWidgets(
      'wideImagePart takes priority over splitWideImage on wide image',
      (tester) async {
        final provider = TestUiImageProvider(wideImage, tag: 'widePriority');

        await tester.pumpWidget(
          MaterialApp(
            home: ComicImage(
              image: provider,
              splitWideImage: true,
              wideImagePart: GalleryImagePart.left,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Should NOT render RawImage because it's single part wide image
        expect(find.byType(RawImage), findsNothing);
      },
    );

    testWidgets(
      'non-wide image keeps full image even if wideImagePart requested',
      (tester) async {
        final provider = TestUiImageProvider(tallImage, tag: 'tallFull');

        await tester.pumpWidget(
          MaterialApp(
            home: ComicImage(
              image: provider,
              splitWideImage: true,
              wideImagePart: GalleryImagePart.left,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Non-wide image renders full RawImage
        expect(find.byType(RawImage), findsOneWidget);
      },
    );

    testWidgets('splitWideImage renders when wideImagePart is null or full', (
      tester,
    ) async {
      final provider = TestUiImageProvider(wideImage, tag: 'splitFallback');

      await tester.pumpWidget(
        MaterialApp(
          home: ComicImage(
            image: provider,
            splitWideImage: true,
            wideImagePart: GalleryImagePart.full,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Because splitWideImage is true and wideImagePart is full, it performs vertical split (not RawImage)
      expect(find.byType(RawImage), findsNothing);
    });
  });
}
