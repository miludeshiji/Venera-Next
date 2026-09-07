import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/images.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/features/reader/waterfall_flow.dart';
import 'package:venera_next/foundation/image_provider/reader_image.dart';
import 'package:venera_next/network/images.dart';

void main() {
  group('Reader initial page normalization & calculation pure logic', () {
    test(
      'normalizeReaderInitialPage normalizes null, 0, negative to 1 and keeps positive',
      () {
        expect(normalizeReaderInitialPage(null), 1);
        expect(normalizeReaderInitialPage(0), 1);
        expect(normalizeReaderInitialPage(-1), 1);
        expect(normalizeReaderInitialPage(-99), 1);
        expect(normalizeReaderInitialPage(1), 1);
        expect(normalizeReaderInitialPage(5), 5);
      },
    );

    test(
      'calculateInitialReaderPageForImagesPerPage handles imagesPerPage and showSingleImageOnFirstPage with no side effects',
      () {
        // imagesPerPage <= 1 should return normalized page
        expect(
          calculateInitialReaderPageForImagesPerPage(
            initialPage: -5,
            imagesPerPage: 1,
            showSingleImageOnFirstPage: false,
          ),
          1,
        );
        expect(
          calculateInitialReaderPageForImagesPerPage(
            initialPage: 4,
            imagesPerPage: 1,
            showSingleImageOnFirstPage: true,
          ),
          4,
        );

        // Two-page mode without single image on first page
        expect(
          calculateInitialReaderPageForImagesPerPage(
            initialPage: -2,
            imagesPerPage: 2,
            showSingleImageOnFirstPage: false,
          ),
          1,
        );
        expect(
          calculateInitialReaderPageForImagesPerPage(
            initialPage: 1,
            imagesPerPage: 2,
            showSingleImageOnFirstPage: false,
          ),
          1,
        );
        expect(
          calculateInitialReaderPageForImagesPerPage(
            initialPage: 2,
            imagesPerPage: 2,
            showSingleImageOnFirstPage: false,
          ),
          1,
        );
        expect(
          calculateInitialReaderPageForImagesPerPage(
            initialPage: 3,
            imagesPerPage: 2,
            showSingleImageOnFirstPage: false,
          ),
          2,
        );
        expect(
          calculateInitialReaderPageForImagesPerPage(
            initialPage: 4,
            imagesPerPage: 2,
            showSingleImageOnFirstPage: false,
          ),
          2,
        );

        // Two-page mode with single image on first page
        expect(
          calculateInitialReaderPageForImagesPerPage(
            initialPage: 1,
            imagesPerPage: 2,
            showSingleImageOnFirstPage: true,
          ),
          1,
        );
        expect(
          calculateInitialReaderPageForImagesPerPage(
            initialPage: 2,
            imagesPerPage: 2,
            showSingleImageOnFirstPage: true,
          ),
          2,
        );
        expect(
          calculateInitialReaderPageForImagesPerPage(
            initialPage: 3,
            imagesPerPage: 2,
            showSingleImageOnFirstPage: true,
          ),
          2,
        );
        expect(
          calculateInitialReaderPageForImagesPerPage(
            initialPage: 4,
            imagesPerPage: 2,
            showSingleImageOnFirstPage: true,
          ),
          3,
        );
      },
    );
  });

  group('Gallery page entries ordering & deduplication', () {
    test('buildGalleryPageEntries orders A/B in RTL as B(page2), A(page1)', () {
      final entries = buildGalleryPageEntries(
        images: ['A', 'B'],
        startIndex: 0,
        isRightToLeft: true,
      );
      expect(entries.length, 2);
      expect(entries[0].imageKey, 'B');
      expect(entries[0].sourcePage, 2);
      expect(entries[1].imageKey, 'A');
      expect(entries[1].sourcePage, 1);
    });

    test(
      'buildGalleryPageEntries retains page2 and page1 when keys are duplicated in RTL',
      () {
        final entries = buildGalleryPageEntries(
          images: ['A', 'A'],
          startIndex: 0,
          isRightToLeft: true,
        );
        expect(entries.length, 2);
        expect(entries[0].imageKey, 'A');
        expect(entries[0].sourcePage, 2);
        expect(entries[1].imageKey, 'A');
        expect(entries[1].sourcePage, 1);
      },
    );

    test('buildGalleryPageEntries preserves order in LTR', () {
      final entries = buildGalleryPageEntries(
        images: ['A', 'B'],
        startIndex: 0,
        isRightToLeft: false,
      );
      expect(entries.length, 2);
      expect(entries[0].imageKey, 'A');
      expect(entries[0].sourcePage, 1);
      expect(entries[1].imageKey, 'B');
      expect(entries[1].sourcePage, 2);
    });
  });

  group('WaterfallChapterFlow and Provider reference resolver', () {
    test('WaterfallChapterFlow index and ref resolution for C2, P1', () {
      final flow = WaterfallChapterFlow(
        segments: [
          WaterfallChapterSegment(
            chapter: 1,
            eid: 'e1',
            images: ['c1_p1', 'c1_p2', 'c1_p3'],
          ),
          WaterfallChapterSegment(
            chapter: 2,
            eid: 'e2',
            images: ['c2_p1', 'c2_p2'],
          ),
        ],
      );

      expect(flow.imageIndexOf(chapter: 2, page: 1), 4);

      final ref = flow.imageRefAt(4);
      expect(ref, isNotNull);
      expect(ref!.chapter, 2);
      expect(ref.page, 1);
      expect(ref.eid, 'e2');
      expect(ref.imageKey, 'c2_p1');
    });

    test(
      'createReaderImageReferenceFromProvider with chapter: 2 constructs correct reference',
      () {
        const provider = ReaderImageProvider(
          'key_c2_p1',
          'source_1',
          'comic_1',
          'e2',
          1,
          chapter: 2,
        );

        final ref = createReaderImageReferenceFromProvider(provider);
        expect(ref.imageKey, 'key_c2_p1');
        expect(ref.sourceKey, 'source_1');
        expect(ref.cid, 'comic_1');
        expect(ref.eid, 'e2');
        expect(ref.chapter, 2);
        expect(ref.page, 1);
        expect(ref.file, isNull);
      },
    );

    test(
      'createReaderImageReferenceFromProvider falls back to segments when chapter is null',
      () {
        final segments = [
          WaterfallChapterSegment(chapter: 2, eid: 'e2', images: ['key_c2_p1']),
        ];

        const provider = ReaderImageProvider(
          'key_c2_p1',
          null,
          'comic_1',
          'e2',
          1,
        );

        final ref = createReaderImageReferenceFromProvider(
          provider,
          fallbackSourceKey: 'default_source',
          segments: segments,
        );

        expect(ref.chapter, 2);
        expect(ref.sourceKey, 'default_source');
        expect(ref.page, 1);
      },
    );
  });

  group(
    'Reader image export filename sanitizer & original image loader contract',
    () {
      test(
        'buildReaderImageFileName removes illegal characters and contains chapter/page suffix with extension',
        () {
          final fileName = buildReaderImageFileName(
            'Comic/Title:with*invalid?chars|"<test>',
            2,
            1,
            '.png',
          );

          // Must not contain Windows invalid chars
          final invalidChars = RegExp(r'[<>:"/\\|?*]');
          expect(invalidChars.hasMatch(fileName), isFalse);
          expect(fileName.contains('_EP2_P1'), isTrue);
          expect(fileName.endsWith('.png'), isTrue);
        },
      );

      test(
        'loadReaderOriginalImageBytes invokes remote loader with target: null and passes keys',
        () async {
          String? capturedImageKey;
          String? capturedSourceKey;
          String? capturedCid;
          String? capturedEid;
          ComicImageLoadTarget? capturedTarget;
          var loaderCallCount = 0;

          final dummyBytes = Uint8List.fromList([1, 2, 3, 4]);

          Future<Uint8List> mockLoader(
            String imageKey,
            String? sourceKey,
            String cid,
            String eid, {
            ComicImageLoadTarget? target,
          }) async {
            loaderCallCount++;
            capturedImageKey = imageKey;
            capturedSourceKey = sourceKey;
            capturedCid = cid;
            capturedEid = eid;
            capturedTarget = target;
            return dummyBytes;
          }

          const ref = ReaderImageReference(
            imageKey: 'test_image_key',
            sourceKey: null,
            cid: 'test_cid',
            eid: 'test_eid',
            chapter: 2,
            page: 1,
          );

          final bytes = await loadReaderOriginalImageBytes(
            ref,
            fallbackSourceKey: 'fallback_src',
            loader: mockLoader,
          );

          expect(loaderCallCount, 1);
          expect(bytes, dummyBytes);
          expect(capturedImageKey, 'test_image_key');
          expect(capturedSourceKey, 'fallback_src');
          expect(capturedCid, 'test_cid');
          expect(capturedEid, 'test_eid');
          expect(capturedTarget, isNull);
        },
      );

      test(
        'loadReaderOriginalImageBytes throws FileSystemException when backing file is not found',
        () async {
          final nonExistentFile = File('non_existent_image_12345.png');
          final ref = ReaderImageReference(
            imageKey: 'dummy_key',
            cid: 'cid',
            eid: 'eid',
            file: nonExistentFile,
          );

          expect(
            () => loadReaderOriginalImageBytes(ref),
            throwsA(isA<FileSystemException>()),
          );
        },
      );
    },
  );
}
