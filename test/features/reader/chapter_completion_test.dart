import 'dart:async';

import 'package:flutter/services.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/reader.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/foundation/comic_type.dart';

void main() {
  tearDown(() => configureReaderChapterCompletedHandler(null));

  test('notifier emits only once per completed chapter', () async {
    final events = <ReaderChapterCompletedEvent>[];
    final notifier = ReaderChapterCompletionNotifier(events.add);
    const event = ReaderChapterCompletedEvent(
      sourceKey: 'source',
      comicId: 'comic',
      chapterKey: 'one',
      chapterTitle: '第 1 话',
    );
    await notifier.notify(isAtEnd: false, event: event);
    await notifier.notify(isAtEnd: true, event: event);
    await notifier.notify(isAtEnd: true, event: event);
    expect(events, [event]);
  });

  test('different chapter keys emit independently', () async {
    final events = <ReaderChapterCompletedEvent>[];
    final notifier = ReaderChapterCompletionNotifier(events.add);
    const first = ReaderChapterCompletedEvent(
      sourceKey: 'source',
      comicId: 'comic',
      chapterKey: 'one',
      chapterTitle: '第 1 话',
    );
    const second = ReaderChapterCompletedEvent(
      sourceKey: 'source',
      comicId: 'comic',
      chapterKey: 'two',
      chapterTitle: '第 2 话',
    );

    await notifier.notify(isAtEnd: true, event: first);
    await notifier.notify(isAtEnd: true, event: second);

    expect(events, [first, second]);
  });

  test('configured handler is captured and awaited', () async {
    final events = <ReaderChapterCompletedEvent>[];
    final completed = Completer<void>();
    configureReaderChapterCompletedHandler((event) async {
      await completed.future;
      events.add(event);
    });
    final notifier = ReaderChapterCompletionNotifier();
    const event = ReaderChapterCompletedEvent(
      sourceKey: 'source',
      comicId: 'comic',
      chapterKey: 'one',
      chapterTitle: '第 1 话',
    );

    var returned = false;
    final notification = notifier
        .notify(isAtEnd: true, event: event)
        .then((_) => returned = true);
    await Future<void>.delayed(Duration.zero);
    expect(returned, isFalse);
    completed.complete();
    await notification;

    expect(events, [event]);
  });

  test('notifier without a handler ignores completion', () async {
    configureReaderChapterCompletedHandler(null);
    final notifier = ReaderChapterCompletionNotifier();
    const event = ReaderChapterCompletedEvent(
      sourceKey: 'source',
      comicId: 'comic',
      chapterKey: 'one',
      chapterTitle: '第 1 话',
    );

    await notifier.notify(isAtEnd: true, event: event);
  });

  test('completion position requires content and a valid final page', () {
    expect(
      isReaderChapterCompletionPosition(
        isActive: true,
        hasImages: false,
        page: 1,
        lastImagePage: 0,
        totalPages: 0,
      ),
      isFalse,
    );
    expect(
      isReaderChapterCompletionPosition(
        isActive: true,
        hasImages: true,
        page: 1,
        lastImagePage: 2,
        totalPages: 3,
      ),
      isFalse,
    );
    expect(
      isReaderChapterCompletionPosition(
        isActive: true,
        hasImages: true,
        page: 3,
        lastImagePage: 2,
        totalPages: 2,
      ),
      isFalse,
    );
    expect(
      isReaderChapterCompletionPosition(
        isActive: true,
        hasImages: true,
        page: 2,
        lastImagePage: 2,
        totalPages: 3,
      ),
      isTrue,
    );
    expect(
      isReaderChapterCompletionPosition(
        isActive: true,
        hasImages: true,
        page: 3,
        lastImagePage: 2,
        totalPages: 3,
      ),
      isTrue,
    );
    expect(
      isReaderChapterCompletionPosition(
        isActive: false,
        hasImages: true,
        page: 2,
        lastImagePage: 2,
        totalPages: 2,
      ),
      isFalse,
    );
  });

  test(
    'background completion is deferred until active and emitted once',
    () async {
      final events = <ReaderChapterCompletedEvent>[];
      final notifier = ReaderChapterCompletionNotifier(events.add);
      const event = ReaderChapterCompletedEvent(
        sourceKey: 'source',
        comicId: 'comic',
        chapterKey: 'one',
        chapterTitle: '第 1 话',
      );

      Future<void> check(bool isActive) => notifier.notify(
        isAtEnd: isReaderChapterCompletionPosition(
          isActive: isActive,
          hasImages: true,
          page: 1,
          lastImagePage: 1,
          totalPages: 1,
        ),
        event: event,
      );

      await check(false);
      expect(events, isEmpty);
      await check(true);
      await check(true);
      expect(events, [event]);
    },
  );

  test('ordinary chapter change enters loading before resetting its page', () {
    final location = _ReaderLocationHarness();

    expect(location.toChapter(2), isTrue);

    expect(location.chapter, 2);
    expect(location.completionChecks, 0);
    expect(location.contentReady, isFalse);
  });

  group('canCompleteReaderChapter gating logic', () {
    test('returns false when content is not ready', () {
      expect(
        canCompleteReaderChapter(
          isContentReady: false,
          isActive: true,
          hasImages: true,
          page: 2,
          lastImagePage: 2,
          totalPages: 2,
          chapter: 1,
          maxChapter: 1,
          isGallerySplitEnabled: false,
          controller: null,
        ),
        isFalse,
      );
    });

    test('returns false when split gallery enabled and controller is null', () {
      expect(
        canCompleteReaderChapter(
          isContentReady: true,
          isActive: true,
          hasImages: true,
          page: 2,
          lastImagePage: 2,
          totalPages: 2,
          chapter: 1,
          maxChapter: 1,
          isGallerySplitEnabled: true,
          controller: null,
        ),
        isFalse,
      );
    });

    test(
      'returns false when split gallery enabled and controller is for old chapter',
      () {
        final controller = _FakeCompletionController(
          readyChapter: 1,
          sourceResolved: true,
          atLastPart: true,
        );
        expect(
          canCompleteReaderChapter(
            isContentReady: true,
            isActive: true,
            hasImages: true,
            page: 2,
            lastImagePage: 2,
            totalPages: 2,
            chapter: 2,
            maxChapter: 2,
            isGallerySplitEnabled: true,
            controller: controller,
          ),
          isFalse,
        );
      },
    );

    test(
      'returns false when split gallery enabled and initial last source size is unresolved',
      () {
        final controller = _FakeCompletionController(
          readyChapter: 1,
          sourceResolved: false,
          atLastPart: true,
        );
        expect(
          canCompleteReaderChapter(
            isContentReady: true,
            isActive: true,
            hasImages: true,
            page: 2,
            lastImagePage: 2,
            totalPages: 2,
            chapter: 1,
            maxChapter: 1,
            isGallerySplitEnabled: true,
            controller: controller,
          ),
          isFalse,
        );
      },
    );

    test(
      'returns false when split gallery enabled and on first half of split wide image',
      () {
        final controller = _FakeCompletionController(
          readyChapter: 1,
          sourceResolved: true,
          atLastPart: false,
        );
        expect(
          canCompleteReaderChapter(
            isContentReady: true,
            isActive: true,
            hasImages: true,
            page: 2,
            lastImagePage: 2,
            totalPages: 2,
            chapter: 1,
            maxChapter: 1,
            isGallerySplitEnabled: true,
            controller: controller,
          ),
          isFalse,
        );
      },
    );

    test(
      'returns true when split gallery enabled and on second half of resolved wide image',
      () {
        final controller = _FakeCompletionController(
          readyChapter: 1,
          sourceResolved: true,
          atLastPart: true,
        );
        expect(
          canCompleteReaderChapter(
            isContentReady: true,
            isActive: true,
            hasImages: true,
            page: 2,
            lastImagePage: 2,
            totalPages: 2,
            chapter: 1,
            maxChapter: 1,
            isGallerySplitEnabled: true,
            controller: controller,
          ),
          isTrue,
        );
      },
    );

    test(
      'returns true for non-split mode with null controller at completion position',
      () {
        expect(
          canCompleteReaderChapter(
            isContentReady: true,
            isActive: true,
            hasImages: true,
            page: 2,
            lastImagePage: 2,
            totalPages: 2,
            chapter: 1,
            maxChapter: 1,
            isGallerySplitEnabled: false,
            controller: null,
          ),
          isTrue,
        );
      },
    );

    test(
      'returns false when on chapter comments page but last source image is unresolved',
      () {
        final controller = _FakeCompletionController(
          readyChapter: 1,
          sourceResolved: false,
          atLastPart: false,
        );
        expect(
          canCompleteReaderChapter(
            isContentReady: true,
            isActive: true,
            hasImages: true,
            page: 3,
            lastImagePage: 2,
            totalPages: 3,
            chapter: 1,
            maxChapter: 1,
            isGallerySplitEnabled: true,
            controller: controller,
          ),
          isFalse,
        );
      },
    );

    test(
      'returns true when on chapter comments page and last source image is resolved',
      () {
        final controller = _FakeCompletionController(
          readyChapter: 1,
          sourceResolved: true,
          atLastPart: true,
        );
        expect(
          canCompleteReaderChapter(
            isContentReady: true,
            isActive: true,
            hasImages: true,
            page: 3,
            lastImagePage: 2,
            totalPages: 3,
            chapter: 1,
            maxChapter: 1,
            isGallerySplitEnabled: true,
            controller: controller,
          ),
          isTrue,
        );
      },
    );

    test(
      'resets imageViewController to null onReaderContentLoading to prevent old controller reuse',
      () {
        final location = _ReaderLocationHarness();
        location.imageViewController = _FakeReaderImageViewController();
        expect(location.imageViewController, isNotNull);

        location.onReaderContentLoading();
        expect(location.imageViewController, isNull);
      },
    );

    test(
      'resets imageViewController to null when toChapter rebuilds standard non-continuous chapter',
      () {
        final location = _ReaderLocationHarness();
        final controller = _FakeReaderImageViewController();
        location.imageViewController = controller;
        expect(location.imageViewController, isNotNull);

        final switched = location.toChapter(2);
        expect(switched, isTrue);
        expect(location.chapter, 2);
        expect(location.imageViewController, isNull);
      },
    );

    test(
      'onReaderContentLoading preserves imageViewController when keepImageViewController is true',
      () {
        final location = _ReaderLocationHarness();
        final controller = _FakeReaderImageViewController();
        location.imageViewController = controller;
        expect(location.imageViewController, isNotNull);

        location.onReaderContentLoading(keepImageViewController: true);
        expect(location.imageViewController, same(controller));
        expect(location.contentReady, isFalse);
      },
    );

    test(
      'in-place waterfall chapter loading preserves and re-attaches controller so routing continues',
      () {
        final location = _ReaderLocationHarness();
        location.testMaxPage = 5;
        final waterfallController = _RoutingWaterfallImageViewController();
        location.imageViewController = waterfallController;

        // 1) When toChapter is called, in-place controller handles it directly
        final switched = location.toChapter(2);
        expect(switched, isTrue);
        expect(location.imageViewController, same(waterfallController));

        // 2) During in-place waterfall loading, keepImageViewController is true
        location.onReaderContentLoading(keepImageViewController: true);
        expect(location.imageViewController, same(waterfallController));

        // 3) Post-load re-attaches / confirms controller
        location.imageViewController = waterfallController;

        // 4) Verify all routing operations continue without null controller error
        expect(location.imageViewController!.handleOnTap(Offset.zero), isTrue);
        location.toVisualEnd();
        expect(waterfallController.visualEndCalled, isTrue);
        location.toPage(2);
        expect(waterfallController.lastToPage, 2);
      },
    );

    group('toVisualEnd controller delegation and null resilience', () {
      test(
        'delegates to imageViewController.toVisualEnd when controller is present',
        () {
          final location = _ReaderLocationHarness();
          final controller = _RoutingWaterfallImageViewController();
          location.imageViewController = controller;

          location.toVisualEnd();
          expect(controller.visualEndCalled, isTrue);
        },
      );

      test(
        'sets jumpToLastPageOnLoad = true when controller is null and isLoading is true',
        () {
          final location = _ReaderLocationHarness();
          location.imageViewController = null;
          location.testIsLoading = true;
          location.jumpToLastPageOnLoad = false;

          location.toVisualEnd();
          expect(location.jumpToLastPageOnLoad, isTrue);
        },
      );

      test(
        'safe no-op when controller is null and isLoading is false, never enters toPage',
        () {
          final location = _ReaderLocationHarness();
          location.imageViewController = null;
          location.testIsLoading = false;
          location.jumpToLastPageOnLoad = false;
          location.testMaxPage = 10;
          location.page = 1;

          // Must not throw Null check operator error or change page
          expect(() => location.toVisualEnd(), returnsNormally);
          expect(location.jumpToLastPageOnLoad, isFalse);
          expect(location.page, 1);
        },
      );
    });

    group(
      'ReaderLocation toPage / toNextPage / toPrevPage null controller resilience',
      () {
        test(
          'toPage returns false and does not mutate page or animation when controller is null',
          () {
            final location = _ReaderLocationHarness();
            location.imageViewController = null;
            location.testMaxPage = 5;
            location.page = 1;

            final result = location.toPage(3);
            expect(result, isFalse);
            expect(location.page, 1);
            expect(location.isPageAnimating, isFalse);
          },
        );

        test(
          'toNextPage and toPrevPage safely return false when controller is null without state progression',
          () {
            final location = _ReaderLocationHarness();
            location.imageViewController = null;
            location.testMaxPage = 5;
            location.page = 2;

            expect(location.toNextPage(), isFalse);
            expect(location.page, 2);
            expect(location.isPageAnimating, isFalse);

            expect(location.toPrevPage(), isFalse);
            expect(location.page, 2);
            expect(location.isPageAnimating, isFalse);
          },
        );

        test(
          'toPage executes and updates page when controller is present and animation disabled',
          () {
            final location = _ReaderLocationHarness();
            location.testEnableAnimation = false;
            final controller = _RoutingWaterfallImageViewController();
            location.imageViewController = controller;
            location.testMaxPage = 5;
            location.page = 1;

            final result = location.toPage(3);
            expect(result, isTrue);
            expect(location.page, 3);
            expect(controller.lastToPage, 3);
          },
        );

        test('toPage delegates to animateToPage when animation is enabled', () {
          final location = _ReaderLocationHarness();
          location.testEnableAnimation = true;
          final controller = _RoutingWaterfallImageViewController();
          location.imageViewController = controller;
          location.testMaxPage = 5;
          location.page = 1;

          final result = location.toPage(3);
          expect(result, isTrue);
          expect(controller.lastToPage, 3);
        });
      },
    );

    group('ReaderLocation chapter completion suppression contract', () {
      test(
        'setPageSuppressingCompletion updates page and suppresses synchronous completion check',
        () {
          final location = _ReaderLocationHarness();
          location.testMaxPage = 3;
          location.page = 1;
          expect(location.completionChecks, 0);

          location.setPageSuppressingCompletion(location.maxPage);
          expect(location.page, location.maxPage);
          expect(location.completionChecks, 0);
        },
      );

      test(
        'suppression is consumed immediately and does not leak to subsequent page turn',
        () {
          final location = _ReaderLocationHarness();
          location.testMaxPage = 3;
          location.page = 1;

          // 1) Comments tail-growth recovery sets page with suppression
          location.setPageSuppressingCompletion(location.maxPage);
          expect(location.page, location.maxPage);
          expect(location.completionChecks, 0);

          // 2) User takes a real page turn action (triggering onPageChanged)
          location.page = location.maxPage;
          expect(location.completionChecks, 1);
        },
      );
    });
  });
}

class _FakeCompletionController implements ChapterCompletionSourceController {
  _FakeCompletionController({
    required this.readyChapter,
    required this.sourceResolved,
    required this.atLastPart,
  });

  final int readyChapter;
  final bool sourceResolved;
  final bool atLastPart;

  @override
  bool isReadyForChapter(int chapter) => chapter == readyChapter;

  @override
  bool isCurrentSourceSizeResolved() => sourceResolved;

  @override
  bool isAtLastVisualPartOfSource() => atLastPart;
}

class _FakeReaderImageViewController implements ReaderImageViewController {
  @override
  Future<void> animateToPage(int page) async {}

  @override
  Future<Uint8List?> getImageByOffset(Offset offset) async => null;

  @override
  String? getImageKeyByOffset(dynamic offset) => null;

  @override
  void handleDoubleTap(dynamic location) {}

  @override
  void handleKeyEvent(dynamic event) {}

  @override
  void handleLongPressDown(dynamic location) {}

  @override
  void handleLongPressUp(dynamic location) {}

  @override
  bool handleOnTap(dynamic location) => false;

  @override
  bool isAtLastVisualPartOfSource() => true;

  @override
  bool isCurrentSourceSizeResolved() => true;

  @override
  bool isReadyForChapter(int chapter) => true;

  @override
  bool toChapter(int chapter, {bool toLastPage = false}) => false;

  @override
  bool toNextPage() => false;

  @override
  void toPage(int page) {}

  @override
  void toVisualEnd() {}

  @override
  bool toPrevPage() => false;
}

class _RoutingWaterfallImageViewController
    extends _FakeReaderImageViewController {
  bool visualEndCalled = false;
  int? lastToPage;

  @override
  bool toChapter(int chapter, {bool toLastPage = false}) => true;

  @override
  bool handleOnTap(dynamic location) => true;

  @override
  void toVisualEnd() {
    visualEndCalled = true;
  }

  @override
  void toPage(int page) {
    lastToPage = page;
  }

  @override
  Future<void> animateToPage(int page) async {
    lastToPage = page;
  }
}

class _ReaderLocationHarness with ReaderLocation {
  bool contentReady = true;
  int completionChecks = 0;
  int testMaxPage = 1;
  bool testEnableAnimation = false;

  @override
  bool enablePageAnimation(String cid, ComicType type) => testEnableAnimation;

  @override
  String get cid => 'comic';

  bool testIsLoading = false;

  @override
  bool get isLoading => testIsLoading;

  @override
  int get maxChapter => 2;

  @override
  int get maxPage => testMaxPage;

  @override
  int get totalPages => maxPage;
  @override
  ComicType get type => ComicType.local;

  @override
  void onPageChanged() {
    if (consumeChapterCompletionSuppression()) {
      return;
    }
    if (contentReady && page >= maxPage) {
      completionChecks++;
    }
  }

  @override
  void onReaderContentLoading({bool keepImageViewController = false}) {
    super.onReaderContentLoading(
      keepImageViewController: keepImageViewController,
    );
    contentReady = false;
  }

  @override
  void flushRemoteProgress() {}

  @override
  void update() {}
}
