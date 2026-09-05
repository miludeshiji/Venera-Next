import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/gallery_coordinator.dart';
import 'package:venera_next/features/reader/gallery_page_plan.dart';

void main() {
  group('Gallery visual order across 3 gallery modes', () {
    test(
      'LTR order: normal images full, wide images left then right (or inverted)',
      () {
        final plan = GalleryPagePlan(
          sourcePageCount: 3,
          direction: GalleryReadingDirection.leftToRight,
          splitDualPage: true,
          splitDualPageInvert: false,
          wideSourceIndices: [1],
        );

        expect(plan.displayPageCount, 4);
        expect(
          plan[0],
          const GalleryDisplayPage(sourceIndex: 0, part: GalleryImagePart.full),
        );
        expect(
          plan[1],
          const GalleryDisplayPage(sourceIndex: 1, part: GalleryImagePart.left),
        );
        expect(
          plan[2],
          const GalleryDisplayPage(
            sourceIndex: 1,
            part: GalleryImagePart.right,
          ),
        );
        expect(
          plan[3],
          const GalleryDisplayPage(sourceIndex: 2, part: GalleryImagePart.full),
        );

        // Inverted LTR
        plan.splitDualPageInvert = true;
        expect(
          plan[1],
          const GalleryDisplayPage(
            sourceIndex: 1,
            part: GalleryImagePart.right,
          ),
        );
        expect(
          plan[2],
          const GalleryDisplayPage(sourceIndex: 1, part: GalleryImagePart.left),
        );
      },
    );

    test('RTL order: wide images right then left (or inverted)', () {
      final plan = GalleryPagePlan(
        sourcePageCount: 2,
        direction: GalleryReadingDirection.rightToLeft,
        splitDualPage: true,
        splitDualPageInvert: false,
        wideSourceIndices: [0],
      );

      expect(plan.displayPageCount, 3);
      expect(
        plan[0],
        const GalleryDisplayPage(sourceIndex: 0, part: GalleryImagePart.right),
      );
      expect(
        plan[1],
        const GalleryDisplayPage(sourceIndex: 0, part: GalleryImagePart.left),
      );
      expect(
        plan[2],
        const GalleryDisplayPage(sourceIndex: 1, part: GalleryImagePart.full),
      );

      // Inverted RTL
      plan.splitDualPageInvert = true;
      expect(
        plan[0],
        const GalleryDisplayPage(sourceIndex: 0, part: GalleryImagePart.left),
      );
      expect(
        plan[1],
        const GalleryDisplayPage(sourceIndex: 0, part: GalleryImagePart.right),
      );
    });

    test(
      'TopToBottom order: wide images right then left by default (or inverted)',
      () {
        final plan = GalleryPagePlan(
          sourcePageCount: 2,
          direction: GalleryReadingDirection.topToBottom,
          splitDualPage: true,
          splitDualPageInvert: false,
          wideSourceIndices: [0],
        );

        expect(plan.displayPageCount, 3);
        expect(
          plan[0],
          const GalleryDisplayPage(
            sourceIndex: 0,
            part: GalleryImagePart.right,
          ),
        );
        expect(
          plan[1],
          const GalleryDisplayPage(sourceIndex: 0, part: GalleryImagePart.left),
        );
        expect(
          plan[2],
          const GalleryDisplayPage(sourceIndex: 1, part: GalleryImagePart.full),
        );

        // Inverted TopToBottom
        plan.splitDualPageInvert = true;
        expect(
          plan[0],
          const GalleryDisplayPage(sourceIndex: 0, part: GalleryImagePart.left),
        );
        expect(
          plan[1],
          const GalleryDisplayPage(
            sourceIndex: 0,
            part: GalleryImagePart.right,
          ),
        );
      },
    );
  });

  group('Dynamic insertion stability and stableId recovery', () {
    test(
      'user on subsequent page does not jump when prior image becomes wide',
      () {
        final plan = GalleryPagePlan(
          sourcePageCount: 4,
          direction: GalleryReadingDirection.leftToRight,
          splitDualPage: true,
        );

        // Initially all full: visualIndex 0 -> source 0, visualIndex 1 -> source 1, visualIndex 2 -> source 2
        expect(plan.displayPageCount, 4);
        final currentVisualIndex = 2; // viewing source 2 ('2:full')
        final currentStableId = plan[currentVisualIndex].stableId;
        expect(currentStableId, '2:full');

        // Now source 0 dynamically reports wide
        final modified = plan.markWide(0, true);
        expect(modified, isTrue);
        expect(
          plan.displayPageCount,
          5,
        ); // 0:left, 0:right, 1:full, 2:full, 3:full

        // Recover visual index for current content
        final recoveredIndex = plan.recoverVisualIndex(
          stableId: currentStableId,
          fallbackVisualIndex: currentVisualIndex,
        );
        // Source 2 ('2:full') is now at visual index 3
        expect(recoveredIndex, 3);
        expect(plan[recoveredIndex].stableId, '2:full');
        expect(plan[recoveredIndex].sourceIndex, 2);
      },
    );

    test(
      'user on current page stays on corresponding half when current image splits',
      () {
        final plan = GalleryPagePlan(
          sourcePageCount: 3,
          direction: GalleryReadingDirection.leftToRight,
          splitDualPage: true,
        );

        // User is viewing source 1 ('1:full') at visual index 1
        final currentStableId = plan[1].stableId;
        expect(currentStableId, '1:full');

        // Source 1 finishes loading and splits
        plan.markWide(1, true);
        expect(plan.displayPageCount, 4); // 0:full, 1:left, 1:right, 2:full

        final recoveredIndex = plan.recoverVisualIndex(
          stableId: currentStableId,
          fallbackVisualIndex: 1,
        );
        // Recovers to first visual page of source 1 ('1:left' at index 1)
        expect(recoveredIndex, 1);
        expect(plan[recoveredIndex].sourceIndex, 1);
        expect(plan[recoveredIndex].part, GalleryImagePart.left);
      },
    );
  });

  group('Two halves source page semantics', () {
    test(
      'both visual halves of a split image map to identical source page',
      () {
        final plan = GalleryPagePlan(
          sourcePageCount: 3,
          direction: GalleryReadingDirection.leftToRight,
          splitDualPage: true,
          wideSourceIndices: [1],
        );

        // visual 1 is 1:left, visual 2 is 1:right
        expect(plan.visualIndexToSourcePage(1), 2);
        expect(plan.visualIndexToSourcePage(2), 2);
        expect(plan.visualIndexToSourceIndex(1), 1);
        expect(plan.visualIndexToSourceIndex(2), 1);
      },
    );

    test('first visual index resolution maps to the first half', () {
      final plan = GalleryPagePlan(
        sourcePageCount: 3,
        direction: GalleryReadingDirection.leftToRight,
        splitDualPage: true,
        wideSourceIndices: [1],
      );

      expect(plan.sourceIndexToFirstVisualIndex(0), 0);
      expect(plan.sourceIndexToFirstVisualIndex(1), 1);
      expect(plan.sourceIndexToFirstVisualIndex(2), 3);
    });
  });

  group('Visual end completion gating', () {
    test(
      'last source page first half does NOT complete chapter, second half does',
      () {
        final plan = GalleryPagePlan(
          sourcePageCount: 3,
          direction: GalleryReadingDirection.leftToRight,
          splitDualPage: true,
          wideSourceIndices: [2], // source 2 is the last page (page 3)
        );

        // visual 0 -> source 0
        // visual 1 -> source 1
        // visual 2 -> source 2 (left half)
        // visual 3 -> source 2 (right half)
        expect(plan.displayPageCount, 4);

        // Visual 2 (first half of last source page)
        expect(plan.isLastVisualPageOfSource(2), isFalse);
        expect(plan.isVisualEnd(2), isFalse);

        // Visual 3 (second half of last source page)
        expect(plan.isLastVisualPageOfSource(3), isTrue);
        expect(plan.isVisualEnd(3), isTrue);
      },
    );

    test(
      'non-split last page is both first and last visual page of source',
      () {
        final plan = GalleryPagePlan(
          sourcePageCount: 3,
          direction: GalleryReadingDirection.leftToRight,
          splitDualPage: true,
          wideSourceIndices: [1], // middle page is wide, last page is not
        );

        expect(plan.displayPageCount, 4);
        // visual 3 is source 2 (not split)
        expect(plan.isFirstVisualPageOfSource(3), isTrue);
        expect(plan.isLastVisualPageOfSource(3), isTrue);
        expect(plan.isVisualEnd(3), isTrue);
      },
    );
    test(
      'completion gating with resolution states: unresolved=false, resolved nonwide=true, resolved wide first=false/second=true',
      () {
        final plan = GalleryPagePlan(
          sourcePageCount: 3,
          direction: GalleryReadingDirection.leftToRight,
          splitDualPage: true,
        );

        // State 1: unresolved last source page
        expect(
          isVisualPageAtLastPartOfSource(
            plan: plan,
            visualIndex: 2,
            isSplitEnabled: true,
            isSourceResolved: false,
          ),
          isFalse, // unresolved = false
        );
        expect(
          plan.isVisualPartComplete(visualIndex: 2, isSourceResolved: false),
          isFalse,
        );

        // State 2: resolved non-wide last source page
        expect(
          isVisualPageAtLastPartOfSource(
            plan: plan,
            visualIndex: 2,
            isSplitEnabled: true,
            isSourceResolved: true,
          ),
          isTrue, // resolved nonwide = true
        );
        expect(
          plan.isVisualPartComplete(visualIndex: 2, isSourceResolved: true),
          isTrue,
        );

        // State 3 & 4: resolved wide last source page (splits into visual 2 and visual 3)
        plan.markWide(2, true);
        expect(plan.displayPageCount, 4);

        // State 3: resolved wide first half
        expect(
          isVisualPageAtLastPartOfSource(
            plan: plan,
            visualIndex: 2,
            isSplitEnabled: true,
            isSourceResolved: true,
          ),
          isFalse, // resolved wide first = false
        );
        expect(
          plan.isVisualPartComplete(visualIndex: 2, isSourceResolved: true),
          isFalse,
        );

        // State 4: resolved wide second half
        expect(
          isVisualPageAtLastPartOfSource(
            plan: plan,
            visualIndex: 3,
            isSplitEnabled: true,
            isSourceResolved: true,
          ),
          isTrue, // resolved wide second = true
        );
        expect(
          plan.isVisualPartComplete(visualIndex: 3, isSourceResolved: true),
          isTrue,
        );
      },
    );
  });

  group('Chapter comments page ordering', () {
    test('comments page is placed strictly after all visual image pages', () {
      final plan = GalleryPagePlan(
        sourcePageCount: 3,
        direction: GalleryReadingDirection.leftToRight,
        splitDualPage: true,
        wideSourceIndices: [2], // 3 source pages -> 4 visual pages
      );

      final totalVisualImagePages = plan.displayPageCount; // 4
      const showChapterCommentsAtEnd = true;
      final totalVisualPages = totalVisualImagePages + 1; // 5

      // Comments page is at index totalVisualImagePages + 1 = 5
      bool isChapterCommentsPage(int index) =>
          showChapterCommentsAtEnd && index == totalVisualImagePages + 1;

      expect(totalVisualPages, 5);
      expect(isChapterCommentsPage(4), isFalse); // last half page
      expect(isChapterCommentsPage(5), isTrue); // comments page
      expect(
        isChapterCommentsPage(6),
        isFalse,
      ); // next chapter sentinel (totalVisualPages + 1)
    });
  });

  group('Stable controller key and visible identity mapping', () {
    test(
      'resolves stable keys and visible identity in split and non-split modes',
      () {
        final plan = GalleryPagePlan(
          sourcePageCount: 2,
          direction: GalleryReadingDirection.leftToRight,
          splitDualPage: true,
          wideSourceIndices: [
            1,
          ], // source 0: full (visual 0), source 1: left (visual 1), right (visual 2)
        );

        (int, int) getRange(int index) => (index - 1, index);

        // Split mode visual pages:
        expect(
          resolveControllerKey(
            controllerIndex: 1,
            isSplitEnabled: true,
            plan: plan,
            isCommentsPage: false,
            getPageImagesRange: getRange,
          ),
          '0:full',
        );
        expect(
          resolveControllerKey(
            controllerIndex: 2,
            isSplitEnabled: true,
            plan: plan,
            isCommentsPage: false,
            getPageImagesRange: getRange,
          ),
          '1:left',
        );
        expect(
          resolveControllerKey(
            controllerIndex: 3,
            isSplitEnabled: true,
            plan: plan,
            isCommentsPage: false,
            getPageImagesRange: getRange,
          ),
          '1:right',
        );
        // Comments page has fixed key:
        expect(
          resolveControllerKey(
            controllerIndex: 4,
            isSplitEnabled: true,
            plan: plan,
            isCommentsPage: true,
            getPageImagesRange: getRange,
          ),
          'comments',
        );

        // Non-split mode keys:
        expect(
          resolveControllerKey(
            controllerIndex: 1,
            isSplitEnabled: false,
            plan: null,
            isCommentsPage: false,
            getPageImagesRange: getRange,
          ),
          'source:0-1',
        );
        expect(
          resolveControllerKey(
            controllerIndex: 2,
            isSplitEnabled: false,
            plan: null,
            isCommentsPage: false,
            getPageImagesRange: getRange,
          ),
          'source:1-2',
        );

        // Visible stable identity:
        // Sentinels (0 and totalVisualPages + 1 = 5) return null
        expect(
          resolveVisibleStableIdentity(
            controllerIndex: 0,
            totalVisualPages: 4,
            isSplitEnabled: true,
            plan: plan,
            isCommentsPage: false,
            getPageImagesRange: getRange,
          ),
          isNull,
        );
        expect(
          resolveVisibleStableIdentity(
            controllerIndex: 5,
            totalVisualPages: 4,
            isSplitEnabled: true,
            plan: plan,
            isCommentsPage: false,
            getPageImagesRange: getRange,
          ),
          isNull,
        );
        expect(
          resolveVisibleStableIdentity(
            controllerIndex: 2,
            totalVisualPages: 4,
            isSplitEnabled: true,
            plan: plan,
            isCommentsPage: false,
            getPageImagesRange: getRange,
          ),
          '1:left',
        );
      },
    );
  });

  group('Comments source size resolution and completion gating', () {
    test(
      'comments page completion requires final source image resolved in split mode',
      () {
        expect(
          isCommentsSourceSizeResolved(
            isSplitEnabled: true,
            sourcePageCount: 3,
            resolvedSourceIndices: {0, 1},
          ),
          isFalse,
        );
        expect(
          isCommentsAtLastVisualPartOfSource(
            isSplitEnabled: true,
            sourcePageCount: 3,
            resolvedSourceIndices: {0, 1},
          ),
          isFalse,
        );

        expect(
          isCommentsSourceSizeResolved(
            isSplitEnabled: true,
            sourcePageCount: 3,
            resolvedSourceIndices: {0, 1, 2},
          ),
          isTrue,
        );
        expect(
          isCommentsAtLastVisualPartOfSource(
            isSplitEnabled: true,
            sourcePageCount: 3,
            resolvedSourceIndices: {0, 1, 2},
          ),
          isTrue,
        );

        // Non-split mode does not gate comments on image dimensions
        expect(
          isCommentsSourceSizeResolved(
            isSplitEnabled: false,
            sourcePageCount: 3,
            resolvedSourceIndices: {},
          ),
          isTrue,
        );
      },
    );
  });

  group('E-Ink refresh gating with layout recovery and split halves', () {
    test(
      'layout recovery index change with unchanged identity suppresses E-Ink refresh',
      () {
        // Layout recovery changes index (e.g. 2 -> 3) but visible identity is still '1:full'
        final shouldRefresh = shouldRefreshEInk(
          previousIdentity: '1:full',
          currentIdentity: '1:full',
          isCommentsPage: false,
        );
        expect(shouldRefresh, isFalse);
      },
    );

    test(
      'transitions between left and right halves of split image trigger E-Ink refresh',
      () {
        final shouldRefresh = shouldRefreshEInk(
          previousIdentity: '1:left',
          currentIdentity: '1:right',
          isCommentsPage: false,
        );
        expect(shouldRefresh, isTrue);
      },
    );

    test('chapter reset triggers E-Ink refresh on first page', () {
      final shouldRefresh = shouldRefreshEInk(
        previousIdentity: null,
        currentIdentity: '0:full',
        isCommentsPage: false,
      );
      expect(shouldRefresh, isTrue);
    });

    test('comments page never triggers E-Ink refresh', () {
      final shouldRefresh = shouldRefreshEInk(
        previousIdentity: '1:full',
        currentIdentity: 'comments',
        isCommentsPage: true,
      );
      expect(shouldRefresh, isFalse);
    });
  });

  group('Visual page navigation policy and animation re-entrancy', () {
    test(
      'ongoing animation consumes input and prevents re-entrant navigation or fallback',
      () {
        final decision = decideVisualMove(
          isAnimating: true,
          currentIndex: 2,
          delta: 1,
          totalVisualPages: 4,
        );
        expect(decision.consumed, isTrue);
        expect(decision.canMove, isFalse);
        expect(decision.targetIndex, isNull);
      },
    );

    test('in-bounds move request is consumed and proceeds to target', () {
      final decision = decideVisualMove(
        isAnimating: false,
        currentIndex: 2,
        delta: 1,
        totalVisualPages: 4,
      );
      expect(decision.consumed, isTrue);
      expect(decision.canMove, isTrue);
      expect(decision.targetIndex, 3);
    });

    test(
      'out-of-bounds at visual end is not consumed, allowing chapter progression',
      () {
        final decision = decideVisualMove(
          isAnimating: false,
          currentIndex: 4,
          delta: 1,
          totalVisualPages: 4,
        );
        expect(decision.consumed, isFalse);
        expect(decision.canMove, isFalse);
      },
    );

    test(
      'out-of-bounds at visual start is not consumed, allowing prev chapter progression',
      () {
        final decision = decideVisualMove(
          isAnimating: false,
          currentIndex: 1,
          delta: -1,
          totalVisualPages: 4,
        );
        expect(decision.consumed, isFalse);
        expect(decision.canMove, isFalse);
      },
    );
  });

  group('PhotoViewController pool lifecycle, bounded pruning, and safe disposal', () {
    test(
      'pool reuses controllers by key and safely disposes evicted controllers post-frame',
      () {
        final callbacks = <void Function(Duration)>[];
        final pool = GalleryPhotoViewControllerPool(
          postFrameCallbackScheduler: (cb) => callbacks.add(cb),
        );

        // 1. Get controller by key
        final c1 = pool.getOrCreate('0:full');
        expect(pool.activeCount, 1);
        expect(pool.getOrCreate('0:full'), same(c1)); // Same instance

        final c2 = pool.getOrCreate('1:left');
        expect(pool.activeCount, 2);
        expect(c2, isNot(same(c1)));

        // 2. Prune except '1:left'
        pool.pruneExcept({'1:left'});
        expect(pool.activeCount, 1);
        expect(pool.pendingDisposeCount, 1);
        expect(callbacks.length, 1);

        // 3. Post-frame callback executes and disposes c1
        callbacks.removeAt(0)(Duration.zero);
        expect(pool.pendingDisposeCount, 0);
        expect(pool.disposedCount, 1);

        // 4. Dispose all remaining controllers
        pool.disposeAll();
        expect(pool.activeCount, 0);
        expect(pool.disposedCount, 2);

        // 5. Calling disposeAll again does not double-dispose
        pool.disposeAll();
        expect(pool.disposedCount, 2);
      },
    );

    test(
      'pool rescues controller from pending dispose if re-requested in same frame',
      () {
        final callbacks = <void Function(Duration)>[];
        final pool = GalleryPhotoViewControllerPool(
          postFrameCallbackScheduler: (cb) => callbacks.add(cb),
        );

        final c1 = pool.getOrCreate('0:full');
        pool.pruneExcept({'1:left'});
        expect(pool.pendingDisposeCount, 1);

        // Re-request '0:full' before frame ends
        final rescued = pool.getOrCreate('0:full');
        expect(rescued, same(c1));
        expect(pool.pendingDisposeCount, 0);

        // Running post-frame callback does NOT dispose rescued controller
        callbacks.removeAt(0)(Duration.zero);
        expect(pool.disposedCount, 0);

        pool.disposeAll();
      },
    );

    test(
      'long sequence of prunes keeps active, pending, and retained controllers bounded without memory leak',
      () {
        final callbacks = <void Function(Duration)>[];
        final pool = GalleryPhotoViewControllerPool(
          postFrameCallbackScheduler: (cb) => callbacks.add(cb),
        );

        // Simulate navigating through 60 visual pages in gallery mode
        for (var i = 0; i < 60; i++) {
          final key = '$i:full';
          pool.getOrCreate(key);
          expect(pool.activeCount, inInclusiveRange(1, 2));
          pool.pruneExcept({key});
          expect(pool.activeCount, 1);
          expect(pool.pendingDisposeCount, inInclusiveRange(0, 1));
          expect(pool.retainedCount, inInclusiveRange(1, 2));

          // Flush scheduled post-frame dispose callbacks
          while (callbacks.isNotEmpty) {
            callbacks.removeAt(0)(Duration.zero);
          }
          expect(pool.activeCount, 1);
          expect(pool.pendingDisposeCount, 0);
          expect(pool.retainedCount, 1);
        }

        expect(pool.disposedCount, 59);
        expect(pool.activeCount, 1);
        expect(pool.pendingDisposeCount, 0);
        expect(pool.retainedCount, 1);

        // Dispose remaining controller
        pool.disposeAll();
        expect(pool.activeCount, 0);
        expect(pool.pendingDisposeCount, 0);
        expect(pool.retainedCount, 0);
        expect(pool.disposedCount, 60);

        // Multiple disposeAll calls do not double-dispose
        pool.disposeAll();
        expect(pool.disposedCount, 60);
      },
    );

    test(
      'disposeAll called while dispose is pending disposes exactly once and ignores subsequent callbacks',
      () {
        final callbacks = <void Function(Duration)>[];
        final pool = GalleryPhotoViewControllerPool(
          postFrameCallbackScheduler: (cb) => callbacks.add(cb),
        );

        pool.getOrCreate('0:full');
        pool.getOrCreate('1:full');
        expect(pool.activeCount, 2);

        // Prune 0:full, scheduling post-frame dispose
        pool.pruneExcept({'1:full'});
        expect(pool.pendingDisposeCount, 1);
        expect(callbacks.length, 1);

        // disposeAll invoked while 0:full is pending
        pool.disposeAll();
        expect(pool.activeCount, 0);
        expect(pool.pendingDisposeCount, 0);
        expect(pool.retainedCount, 0);
        expect(pool.disposedCount, 2);

        // Deferred callback executes now; should be a no-op
        callbacks.removeAt(0)(Duration.zero);
        expect(pool.disposedCount, 2);

        // Repeated disposeAll is also a no-op
        pool.disposeAll();
        expect(pool.disposedCount, 2);
      },
    );

    test(
      'resolveKeepControllerKeys retains visual adjacency window and excludes sentinels',
      () {
        String keyForIndex(int idx) => idx == 5 ? 'comments' : 'source:$idx';

        // 1. Page 1 (at start): window [0, 1, 2] -> 0 excluded (sentinel), keeps 1 and 2
        final startKeys = resolveKeepControllerKeys(
          currentIndex: 1,
          totalVisualPages: 5,
          resolveKeyForIndex: keyForIndex,
        );
        expect(startKeys, {'source:1', 'source:2'});

        // 2. Page 3 (interior): window [2, 3, 4] -> all kept
        final midKeys = resolveKeepControllerKeys(
          currentIndex: 3,
          totalVisualPages: 5,
          resolveKeyForIndex: keyForIndex,
        );
        expect(midKeys, {'source:2', 'source:3', 'source:4'});

        // 3. Page 5 (comments page at end): window [4, 5, 6] -> 6 excluded (sentinel), keeps 4 and 5
        final endKeys = resolveKeepControllerKeys(
          currentIndex: 5,
          totalVisualPages: 5,
          resolveKeyForIndex: keyForIndex,
        );
        expect(endKeys, {'source:4', 'comments'});

        // 4. Sentinel position 0: window [-1, 0, 1] -> keeps 1
        final sentinel0Keys = resolveKeepControllerKeys(
          currentIndex: 0,
          totalVisualPages: 5,
          resolveKeyForIndex: keyForIndex,
        );
        expect(sentinel0Keys, {'source:1'});

        // 5. Sentinel position 6: window [5, 6, 7] -> keeps 5 ('comments')
        final sentinelEndKeys = resolveKeepControllerKeys(
          currentIndex: 6,
          totalVisualPages: 5,
          resolveKeyForIndex: keyForIndex,
        );
        expect(sentinelEndKeys, {'comments'});
      },
    );

    test(
      'rapid back-and-forth across adjacent windows retains mounted controllers without premature disposal',
      () {
        final callbacks = <void Function(Duration)>[];
        final pool = GalleryPhotoViewControllerPool(
          postFrameCallbackScheduler: (cb) => callbacks.add(cb),
        );
        String keyForIndex(int idx) => 'page:$idx';

        // User starts on page 1
        pool.getOrCreate('page:1');
        pool.getOrCreate('page:2');
        var keys = resolveKeepControllerKeys(
          currentIndex: 1,
          totalVisualPages: 10,
          resolveKeyForIndex: keyForIndex,
        );
        pool.pruneExcept(keys);
        expect(pool.activeCount, 2);

        // Advance to page 2: window is [1, 2, 3] -> page 1 is NOT evicted!
        pool.getOrCreate('page:3');
        keys = resolveKeepControllerKeys(
          currentIndex: 2,
          totalVisualPages: 10,
          resolveKeyForIndex: keyForIndex,
        );
        pool.pruneExcept(keys);
        expect(pool.activeCount, 3);
        expect(pool.pendingDisposeCount, 0);

        // Quick return to page 1: page 1 controller is still alive and active
        keys = resolveKeepControllerKeys(
          currentIndex: 1,
          totalVisualPages: 10,
          resolveKeyForIndex: keyForIndex,
        );
        pool.pruneExcept(keys);
        // Page 3 left the window [0, 1, 2], so page 3 is pending disposal, pages 1 & 2 are active
        expect(pool.activeCount, 2);
        expect(pool.pendingDisposeCount, 1);

        // Flush post-frame disposal
        while (callbacks.isNotEmpty) {
          callbacks.removeAt(0)(Duration.zero);
        }
        expect(pool.disposedCount, 1);
        expect(pool.activeCount, 2);

        pool.disposeAll();
      },
    );
  });

  group('Visual end vs source jump target resolution', () {
    test(
      'resolveSourceJumpTarget always targets first visual half of source page',
      () {
        final plan = GalleryPagePlan(
          sourcePageCount: 3,
          direction: GalleryReadingDirection.leftToRight,
          splitDualPage: true,
          wideSourceIndices: [
            2,
          ], // source 2 is wide -> visual 2 (left) and 3 (right)
        );

        // Source jump to page 3 lands on visual index 2 -> controller index 3 (first half)
        final target = resolveSourceJumpTarget(
          isSplitEnabled: true,
          plan: plan,
          sourcePage: 3,
          sourcePageCount: 3,
        );
        expect(target, 3);
        expect(plan[target - 1].part, GalleryImagePart.left);
      },
    );

    test('resolveVisualEndTarget targets final visual half when resolved', () {
      final plan = GalleryPagePlan(
        sourcePageCount: 3,
        direction: GalleryReadingDirection.leftToRight,
        splitDualPage: true,
        wideSourceIndices: [
          2,
        ], // source 2 is wide -> visual 2 (left) and 3 (right)
      );

      final result = resolveVisualEndTarget(
        isSplitEnabled: true,
        plan: plan,
        sourcePageCount: 3,
        isLastSourceResolved: true,
        sourcePageToControllerIndex: (p) => p,
      );
      // Lands on controller index 4 (visual index 3 = right half)
      expect(result.targetIndex, 4);
      expect(result.retainTargetLastVisualPage, isFalse);
      expect(plan[result.targetIndex - 1].part, GalleryImagePart.right);
    });

    test(
      'resolveVisualEndTarget retains intent when last source unresolved and positions on load',
      () {
        final plan = GalleryPagePlan(
          sourcePageCount: 3,
          direction: GalleryReadingDirection.leftToRight,
          splitDualPage: true,
        );
        expect(plan.displayPageCount, 3);

        final result = resolveVisualEndTarget(
          isSplitEnabled: true,
          plan: plan,
          sourcePageCount: 3,
          isLastSourceResolved: false,
          sourcePageToControllerIndex: (p) => p,
        );
        expect(result.targetIndex, 3);
        expect(result.retainTargetLastVisualPage, isTrue);

        // Last source resolves wide later
        plan.markWide(2, true);
        expect(plan.displayPageCount, 4);

        final recovered = resolveRecoveredControllerIndex(
          location: const GalleryTargetLastVisualLocation(),
          plan: plan,
          isLastSourceResolved: true,
          totalVisualImagePages: plan.displayPageCount,
        );
        expect(recovered, 4); // Lands on final half
        expect(plan[recovered - 1].part, GalleryImagePart.right);
      },
    );

    test(
      'resolveVisualEndTarget degrades to source jump in non-split mode',
      () {
        final result = resolveVisualEndTarget(
          isSplitEnabled: false,
          plan: null,
          sourcePageCount: 5,
          isLastSourceResolved: true,
          sourcePageToControllerIndex: (p) => p,
        );
        expect(result.targetIndex, 5);
        expect(result.retainTargetLastVisualPage, isFalse);
      },
    );
  });

  group('Dynamic size updates and recovery resolution', () {
    test(
      'sourceIndexToLastVisualIndex returns final visual index for split and non-split pages',
      () {
        final plan = GalleryPagePlan(
          sourcePageCount: 3,
          direction: GalleryReadingDirection.leftToRight,
          splitDualPage: true,
          wideSourceIndices: [
            1,
          ], // source 0: full (0), source 1: left(1), right(2), source 2: full(3)
        );

        expect(plan.sourceIndexToLastVisualIndex(0), 0);
        expect(plan.sourceIndexToLastVisualIndex(1), 2); // second half!
        expect(plan.sourceIndexToLastVisualIndex(2), 3);
        expect(plan.sourceIndexToLastVisualIndex(99), -1);
      },
    );

    test(
      'coalescer captures initial descriptor once and does not read mutated plan on subsequent callbacks',
      () {
        final plan = GalleryPagePlan(
          sourcePageCount: 4,
          direction: GalleryReadingDirection.leftToRight,
          splitDualPage: true,
        );
        // Initially 0:full(0), 1:full(1), 2:full(2), 3:full(3)
        final coalescer = GallerySizeUpdateCoalescer();

        // User is viewing source 2 at visual index 2 ('2:full')
        const initialLocation = GalleryPageLocation(
          stableId: '2:full',
          fallbackVisualIndex: 2,
        );

        // First callback: image 0 becomes wide
        coalescer.recordInitialLocation(initialLocation);
        expect(coalescer.hasPendingUpdates, isTrue);
        plan.markWide(0, true);
        // Now visual index 2 in the plan is image 1 ('1:full'), NOT image 2!

        // Second callback in the same frame: image 1 becomes wide.
        // If the code erroneously queried plan[2] with old index, it would capture '1:left' or '1:full'.
        final faultySecondLocation = GalleryPageLocation(
          stableId: plan[2].stableId,
          fallbackVisualIndex: 2,
        );
        coalescer.recordInitialLocation(faultySecondLocation);

        // Verify coalescer kept the pre-mutation initial location!
        expect(coalescer.initialLocation, initialLocation);
        plan.markWide(1, true);

        // On flush, recovery restores the true user location (source 2) in the updated plan
        final flushed = coalescer.flush();
        expect(flushed, initialLocation);

        final recoveredControllerIndex = resolveRecoveredControllerIndex(
          location: flushed!,
          plan: plan,
          isLastSourceResolved: true,
          totalVisualImagePages: plan.displayPageCount,
        );

        // Plan now: 0:left(0), 0:right(1), 1:left(2), 1:right(3), 2:full(4), 3:full(5)
        // Source 2 ('2:full') is at visual 4 -> controller index 5
        expect(recoveredControllerIndex, 5);
        expect(plan[recoveredControllerIndex - 1].stableId, '2:full');
      },
    );

    test(
      'comments page dynamically adjusts to new comments index without image fallback',
      () {
        final plan = GalleryPagePlan(
          sourcePageCount: 3,
          direction: GalleryReadingDirection.leftToRight,
          splitDualPage: true,
        );
        expect(plan.displayPageCount, 3);

        const commentsLoc = GalleryCommentsLocation();
        // Before change, 3 visual pages -> comments page is at index 4
        expect(
          resolveRecoveredControllerIndex(
            location: commentsLoc,
            plan: plan,
            isLastSourceResolved: true,
            totalVisualImagePages: plan.displayPageCount,
          ),
          4,
        );

        // Image 1 becomes wide dynamically -> visual pages become 4
        plan.markWide(1, true);
        expect(plan.displayPageCount, 4);

        // Resolves to new comments page index (5), NOT an image page
        final newIndex = resolveRecoveredControllerIndex(
          location: commentsLoc,
          plan: plan,
          isLastSourceResolved: true,
          totalVisualImagePages: plan.displayPageCount,
        );
        expect(newIndex, 5);
      },
    );

    test(
      'comments location with tail growth recovers to newly added final visual half instead of comments',
      () {
        final plan = GalleryPagePlan(
          sourcePageCount: 3,
          direction: GalleryReadingDirection.leftToRight,
          splitDualPage: true,
        );
        expect(plan.displayPageCount, 3);

        // Initially at Comments, 3 visual image pages -> comments page is at index 4
        const commentsLoc = GalleryCommentsLocation();
        expect(
          resolveRecoveredControllerIndex(
            location: commentsLoc,
            plan: plan,
            isLastSourceResolved: false,
            totalVisualImagePages: plan.displayPageCount,
          ),
          4,
        );

        // Final source image (index 2) dynamically confirms wide for first time -> splits into 2 visual pages
        plan.markWide(2, true);
        expect(plan.displayPageCount, 4);

        // With tail growth, recovery MUST target the newly added final visual half (index 4), NOT comments (index 5)!
        final recoveredIndexWithTailGrowth = resolveRecoveredControllerIndex(
          location: commentsLoc,
          plan: plan,
          isLastSourceResolved: true,
          totalVisualImagePages: plan.displayPageCount,
          hasCommentsTailGrowth: true,
        );
        expect(
          recoveredIndexWithTailGrowth,
          4,
        ); // Controller index 4 = visual index 3 = last half
        expect(plan[recoveredIndexWithTailGrowth - 1].sourceIndex, 2);
        expect(plan[recoveredIndexWithTailGrowth - 1].isSplit, isTrue);

        // Recovery target outcome sets reader.page = maxPage and suppresses chapter completion
        final outcome = resolveCommentsRecoveryTarget(
          hasCommentsTailGrowth: true,
          totalVisualImagePages: plan.displayPageCount,
          maxPage: 3,
        );
        expect(outcome.shouldRecoverToFinalVisualHalf, isTrue);
        expect(outcome.targetControllerIndex, 4);
        expect(outcome.targetReaderPage, 3);
        expect(outcome.notifyChapterCompleted, isFalse);
      },
    );

    test(
      'comments tail growth recovery suppresses completion on initial sync and allows subsequent page turn completion',
      () {
        final plan = GalleryPagePlan(
          sourcePageCount: 3,
          direction: GalleryReadingDirection.leftToRight,
          splitDualPage: true,
        );
        plan.markWide(2, true);

        final outcome = resolveCommentsRecoveryTarget(
          hasCommentsTailGrowth: true,
          totalVisualImagePages: plan.displayPageCount,
          maxPage: 3,
        );
        expect(outcome.notifyChapterCompleted, isFalse);
        expect(outcome.targetReaderPage, 3);

        var completionNotified = false;
        var historyUpdated = false;
        var currentPage = 4; // initially on comments page (maxPage + 1)

        bool suppressionFlag = false;
        void onPageChanged() {
          historyUpdated = true;
          if (suppressionFlag) {
            suppressionFlag = false; // consumed
            return;
          }
          completionNotified = true;
        }

        void setPageSuppressingCompletion(int p) {
          suppressionFlag = true;
          try {
            currentPage = p;
            onPageChanged();
          } finally {
            suppressionFlag = false;
          }
        }

        // Step 1: dynamic comments recovery runs
        setPageSuppressingCompletion(outcome.targetReaderPage);
        expect(currentPage, 3);
        expect(historyUpdated, isTrue);
        expect(completionNotified, isFalse); // suppressed!
        expect(suppressionFlag, isFalse); // clean consumption

        // Step 2: user performs actual page turn forward to comments
        historyUpdated = false;
        currentPage = 4;
        onPageChanged();
        expect(historyUpdated, isTrue);
        expect(
          completionNotified,
          isTrue,
        ); // normal page turn completes chapter!
      },
    );

    test(
      'shouldRecoverCommentsToFinalVisualHalf pure decision covers all combinations',
      () {
        // Case 1: On comments, last source, first time wide confirmed -> true
        expect(
          shouldRecoverCommentsToFinalVisualHalf(
            isCommentsLocation: true,
            isLastSource: true,
            isWide: true,
            wasWide: false,
            wasResolved: false,
          ),
          isTrue,
        );

        // Case 2: Non-tail split (e.g. source 0 or 1 splits while at comments) -> false
        expect(
          shouldRecoverCommentsToFinalVisualHalf(
            isCommentsLocation: true,
            isLastSource: false,
            isWide: true,
            wasWide: false,
            wasResolved: false,
          ),
          isFalse,
        );

        // Case 3: Non-wide image -> false
        expect(
          shouldRecoverCommentsToFinalVisualHalf(
            isCommentsLocation: true,
            isLastSource: true,
            isWide: false,
            wasWide: false,
            wasResolved: false,
          ),
          isFalse,
        );

        // Case 4: Repeated callback (already resolved) -> false
        expect(
          shouldRecoverCommentsToFinalVisualHalf(
            isCommentsLocation: true,
            isLastSource: true,
            isWide: true,
            wasWide: true,
            wasResolved: true,
          ),
          isFalse,
        );

        // Case 5: Not on comments location (e.g. on visual image page) -> false
        expect(
          shouldRecoverCommentsToFinalVisualHalf(
            isCommentsLocation: false,
            isLastSource: true,
            isWide: true,
            wasWide: false,
            wasResolved: false,
          ),
          isFalse,
        );
      },
    );

    test('coalescer tracks comments tail growth and resets across batches', () {
      final coalescer = GallerySizeUpdateCoalescer();
      expect(coalescer.hasCommentsTailGrowth, isFalse);

      // Batch 1: Record comments location and mark tail growth
      coalescer.recordInitialLocation(const GalleryCommentsLocation());
      coalescer.markCommentsTailGrowth();
      expect(coalescer.hasCommentsTailGrowth, isTrue);

      final flushed = coalescer.flush();
      expect(flushed, const GalleryCommentsLocation());
      expect(coalescer.hasCommentsTailGrowth, isFalse);
      expect(coalescer.hasPendingUpdates, isFalse);

      // Batch 2: Record page location without tail growth
      coalescer.recordInitialLocation(
        const GalleryPageLocation(stableId: '0:full', fallbackVisualIndex: 0),
      );
      expect(coalescer.hasCommentsTailGrowth, isFalse);
      coalescer.reset();
      expect(coalescer.hasPendingUpdates, isFalse);
      expect(coalescer.hasCommentsTailGrowth, isFalse);
    });

    test(
      'GalleryCommentsLocation is fieldless value object and recovery index depends solely on hasCommentsTailGrowth parameter',
      () {
        const loc1 = GalleryCommentsLocation();
        const loc2 = GalleryCommentsLocation();
        expect(loc1, equals(loc2));
        expect(loc1.hashCode, equals(loc2.hashCode));

        final plan = GalleryPagePlan(
          sourcePageCount: 3,
          direction: GalleryReadingDirection.leftToRight,
          splitDualPage: true,
        );

        // When hasCommentsTailGrowth is false, resolves to totalVisualImagePages + 1
        final commentsIndex = resolveRecoveredControllerIndex(
          location: loc1,
          plan: plan,
          isLastSourceResolved: true,
          totalVisualImagePages: 4,
          hasCommentsTailGrowth: false,
        );
        expect(commentsIndex, 5);

        // When hasCommentsTailGrowth is true, resolves to totalVisualImagePages
        final tailGrowthIndex = resolveRecoveredControllerIndex(
          location: loc1,
          plan: plan,
          isLastSourceResolved: true,
          totalVisualImagePages: 4,
          hasCommentsTailGrowth: true,
        );
        expect(tailGrowthIndex, 4);
      },
    );

    test(
      'target last visual location retains intent when unresolved and lands on final half when resolved',
      () {
        final plan = GalleryPagePlan(
          sourcePageCount: 3,
          direction: GalleryReadingDirection.leftToRight,
          splitDualPage: true,
        );
        const targetLast = GalleryTargetLastVisualLocation();

        // State 1: last source unresolved -> lands on current displayPageCount (3)
        final unresolvedIndex = resolveRecoveredControllerIndex(
          location: targetLast,
          plan: plan,
          isLastSourceResolved: false,
          totalVisualImagePages: plan.displayPageCount,
        );
        expect(unresolvedIndex, 3);

        // State 2: last source resolves as wide -> splits into visual 2 & 3
        plan.markWide(2, true);
        expect(plan.displayPageCount, 4);

        final resolvedWideIndex = resolveRecoveredControllerIndex(
          location: targetLast,
          plan: plan,
          isLastSourceResolved: true,
          totalVisualImagePages: plan.displayPageCount,
        );
        // Lands on controller index 4 (visual index 3 = last half of wide image)
        expect(resolvedWideIndex, 4);
        expect(plan[resolvedWideIndex - 1].sourceIndex, 2);
        expect(plan[resolvedWideIndex - 1].isSplit, isTrue);
      },
    );
  });
}
