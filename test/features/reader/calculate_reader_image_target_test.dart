import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/images.dart';
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
          expect(target.cacheIdentity, 'w2000-h3200-contain');
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
        expect(target.cacheIdentity, 'w1000-h3200-contain');
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
        expect(target.cacheIdentity, 'w2000-h1600-contain');
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
          expect(target.cacheIdentity, 'w1200-hnull-fitWidth');
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
          expect(target.cacheIdentity, 'wnull-h3000-fitHeight');
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
}
