import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';
import 'package:venera_next/features/reader/gallery_coordinator.dart';
import 'package:venera_next/features/reader/gallery_page_plan.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Gallery controller lifecycle contract', () {
    testWidgets(
      'mounts, renders PhotoView, and bounds controller pool across page changes',
      (tester) async {
        final pool = GalleryPhotoViewControllerPool();
        final pageController = PageController(initialPage: 1);
        final visitedPages = <int>[];

        String resolveKey(int index) {
          if (index == 5) return 'comments';
          return 'visual:$index';
        }

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 400,
                height: 600,
                child: _GalleryPhotoViewLifecycleHarness(
                  pool: pool,
                  totalVisualPages: 5,
                  resolveKeyForIndex: resolveKey,
                  initialPage: 1,
                  pageController: pageController,
                  onPageChanged: (page) => visitedPages.add(page),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Page 1 is active; PhotoView is rendered
        expect(find.byType(PhotoView), findsOneWidget);
        expect(pool.activeCount, greaterThanOrEqualTo(1));
        final controller1 = pool['visual:1'];
        expect(controller1, isNotNull);

        // Advance to Page 2
        pageController.jumpToPage(2);
        await tester.pumpAndSettle();

        // Window is [1, 2, 3]; visual:1 is still retained!
        expect(pool['visual:1'], isNotNull);
        final controller2 = pool['visual:2'];
        expect(controller2, isNotNull);

        // Advance to Page 3
        pageController.jumpToPage(3);
        await tester.pumpAndSettle();

        // Window is [2, 3, 4]; visual:1 left the window and is disposed post-frame
        expect(pool['visual:2'], isNotNull);
        expect(pool['visual:3'], isNotNull);
        expect(pool.disposedCount, greaterThanOrEqualTo(1));

        // Fast back-navigation to Page 2: controller2 is still active
        pageController.jumpToPage(2);
        await tester.pumpAndSettle();
        expect(pool['visual:2'], same(controller2));

        // Unmount the widget tree: pool.disposeAll() is called safely
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();

        expect(pool.activeCount, 0);
        expect(pool.pendingDisposeCount, 0);
        expect(pool.retainedCount, 0);
        pageController.dispose();
      },
    );

    testWidgets(
      'dynamic size recovery from comments prioritizes newly added final visual half',
      (tester) async {
        final plan = GalleryPagePlan(
          sourcePageCount: 3,
          direction: GalleryReadingDirection.leftToRight,
          splitDualPage: true,
        );
        final coalescer = GallerySizeUpdateCoalescer();

        // User starts on Comments (initially 3 visual pages -> comments page is at index 4)
        expect(plan.displayPageCount, 3);
        const initialLocation = GalleryCommentsLocation();
        coalescer.recordInitialLocation(initialLocation);

        // Final source image (source 2) confirms wide for the first time
        const sourceIndex = 2;
        const isWide = true;
        const wasWide = false;
        const wasResolved = false;

        final shouldRecover = shouldRecoverCommentsToFinalVisualHalf(
          isCommentsLocation:
              coalescer.initialLocation is GalleryCommentsLocation,
          isLastSource: sourceIndex == 2,
          isWide: isWide,
          wasWide: wasWide,
          wasResolved: wasResolved,
        );
        expect(shouldRecover, isTrue);
        coalescer.markCommentsTailGrowth();

        // Plan updates: 3 -> 4 visual pages
        plan.markWide(sourceIndex, isWide);
        expect(plan.displayPageCount, 4);

        // Recovery runs
        final hadTailGrowth = coalescer.hasCommentsTailGrowth;
        final location = coalescer.flush();
        expect(hadTailGrowth, isTrue);
        expect(location, const GalleryCommentsLocation());

        final targetIndex = resolveRecoveredControllerIndex(
          location: location!,
          plan: plan,
          isLastSourceResolved: true,
          totalVisualImagePages: plan.displayPageCount,
          hasCommentsTailGrowth: hadTailGrowth,
        );
        // Lands on controller index 4 (the newly added second half of source 2), NOT comments (5)!
        expect(targetIndex, 4);
        expect(plan[targetIndex - 1].sourceIndex, 2);
        expect(plan[targetIndex - 1].isSplit, isTrue);

        final decision = resolveCommentsRecoveryTarget(
          hasCommentsTailGrowth: hadTailGrowth,
          totalVisualImagePages: plan.displayPageCount,
          maxPage: 3,
        );
        expect(decision.shouldRecoverToFinalVisualHalf, isTrue);
        expect(decision.targetControllerIndex, 4);
        expect(decision.targetReaderPage, 3); // reader.page = maxPage
        expect(
          decision.notifyChapterCompleted,
          isFalse,
        ); // Chapter completion suppressed!
      },
    );
  });
}

class _GalleryPhotoViewLifecycleHarness extends StatefulWidget {
  const _GalleryPhotoViewLifecycleHarness({
    required this.pool,
    required this.totalVisualPages,
    required this.resolveKeyForIndex,
    this.initialPage = 1,
    this.pageController,
    this.onPageChanged,
  });

  final GalleryPhotoViewControllerPool pool;
  final int totalVisualPages;
  final String Function(int index) resolveKeyForIndex;
  final int initialPage;
  final PageController? pageController;
  final void Function(int page)? onPageChanged;

  @override
  State<_GalleryPhotoViewLifecycleHarness> createState() =>
      _GalleryPhotoViewLifecycleHarnessState();
}

class _GalleryPhotoViewLifecycleHarnessState
    extends State<_GalleryPhotoViewLifecycleHarness> {
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController =
        widget.pageController ??
        PageController(initialPage: widget.initialPage);
  }

  @override
  void dispose() {
    if (widget.pageController == null) {
      _pageController.dispose();
    }
    widget.pool.disposeAll();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageView.builder(
      controller: _pageController,
      itemCount: widget.totalVisualPages + 2,
      onPageChanged: (i) {
        final keepKeys = resolveKeepControllerKeys(
          currentIndex: i,
          totalVisualPages: widget.totalVisualPages,
          resolveKeyForIndex: widget.resolveKeyForIndex,
        );
        widget.pool.pruneExcept(keepKeys);
        widget.onPageChanged?.call(i);
      },
      itemBuilder: (context, index) {
        if (index <= 0 || index > widget.totalVisualPages) {
          return const SizedBox();
        }
        final key = widget.resolveKeyForIndex(index);
        final controller = widget.pool.getOrCreate(key);
        return PhotoView.customChild(
          controller: controller,
          child: SizedBox(
            key: ValueKey('page_$index'),
            width: 200,
            height: 200,
          ),
        );
      },
    );
  }
}
