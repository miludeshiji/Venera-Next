import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/gallery_page_plan.dart';

void main() {
  group('GalleryDisplayPage', () {
    test('computes sourcePage and stableId correctly', () {
      const pageFull = GalleryDisplayPage(
        sourceIndex: 0,
        part: GalleryImagePart.full,
      );
      expect(pageFull.sourcePage, 1);
      expect(pageFull.stableId, '0:full');
      expect(pageFull.isSplit, isFalse);

      const pageLeft = GalleryDisplayPage(
        sourceIndex: 2,
        part: GalleryImagePart.left,
      );
      expect(pageLeft.sourcePage, 3);
      expect(pageLeft.stableId, '2:left');
      expect(pageLeft.isSplit, isTrue);

      const pageRight = GalleryDisplayPage(
        sourceIndex: 2,
        part: GalleryImagePart.right,
      );
      expect(pageRight.sourcePage, 3);
      expect(pageRight.stableId, '2:right');
      expect(pageRight.isSplit, isTrue);
    });

    test('value equality and hashCode', () {
      const p1 = GalleryDisplayPage(
        sourceIndex: 1,
        part: GalleryImagePart.left,
      );
      const p2 = GalleryDisplayPage(
        sourceIndex: 1,
        part: GalleryImagePart.left,
      );
      const p3 = GalleryDisplayPage(
        sourceIndex: 1,
        part: GalleryImagePart.right,
      );
      const p4 = GalleryDisplayPage(
        sourceIndex: 2,
        part: GalleryImagePart.left,
      );

      expect(p1, equals(p2));
      expect(p1.hashCode, equals(p2.hashCode));
      expect(p1, isNot(equals(p3)));
      expect(p1, isNot(equals(p4)));
    });
  });

  group('pure order functions (LTR, RTL, TopToBottom, invert)', () {
    test('galleryLeftToRight order', () {
      expect(
        resolveWideImageParts(
          direction: GalleryReadingDirection.leftToRight,
          invert: false,
        ),
        [GalleryImagePart.left, GalleryImagePart.right],
      );
      expect(
        resolveWideImageParts(
          direction: GalleryReadingDirection.leftToRight,
          invert: true,
        ),
        [GalleryImagePart.right, GalleryImagePart.left],
      );
    });

    test('galleryRightToLeft order', () {
      expect(
        resolveWideImageParts(
          direction: GalleryReadingDirection.rightToLeft,
          invert: false,
        ),
        [GalleryImagePart.right, GalleryImagePart.left],
      );
      expect(
        resolveWideImageParts(
          direction: GalleryReadingDirection.rightToLeft,
          invert: true,
        ),
        [GalleryImagePart.left, GalleryImagePart.right],
      );
    });

    test('galleryTopToBottom order', () {
      expect(
        resolveWideImageParts(
          direction: GalleryReadingDirection.topToBottom,
          invert: false,
        ),
        [GalleryImagePart.right, GalleryImagePart.left],
      );
      expect(
        resolveWideImageParts(
          direction: GalleryReadingDirection.topToBottom,
          invert: true,
        ),
        [GalleryImagePart.left, GalleryImagePart.right],
      );
    });

    test('resolveWideImagePartsForDirection helper', () {
      // LTR
      expect(
        resolveWideImagePartsForDirection(
          isRtl: false,
          isTopToBottom: false,
          invert: false,
        ),
        [GalleryImagePart.left, GalleryImagePart.right],
      );
      expect(
        resolveWideImagePartsForDirection(
          isRtl: false,
          isTopToBottom: false,
          invert: true,
        ),
        [GalleryImagePart.right, GalleryImagePart.left],
      );

      // RTL
      expect(
        resolveWideImagePartsForDirection(
          isRtl: true,
          isTopToBottom: false,
          invert: false,
        ),
        [GalleryImagePart.right, GalleryImagePart.left],
      );
      expect(
        resolveWideImagePartsForDirection(
          isRtl: true,
          isTopToBottom: false,
          invert: true,
        ),
        [GalleryImagePart.left, GalleryImagePart.right],
      );

      // TopToBottom
      expect(
        resolveWideImagePartsForDirection(
          isRtl: false,
          isTopToBottom: true,
          invert: false,
        ),
        [GalleryImagePart.right, GalleryImagePart.left],
      );
      expect(
        resolveWideImagePartsForDirection(
          isRtl: false,
          isTopToBottom: true,
          invert: true,
        ),
        [GalleryImagePart.left, GalleryImagePart.right],
      );
    });
  });

  group('GalleryPagePlan mapping and dual page splitting', () {
    test('does not split wide images when splitDualPage is false', () {
      final plan = GalleryPagePlan(
        sourcePageCount: 3,
        splitDualPage: false,
        wideSourceIndices: [1],
      );

      expect(plan.displayPageCount, 3);
      expect(plan[0].part, GalleryImagePart.full);
      expect(plan[1].part, GalleryImagePart.full);
      expect(plan[2].part, GalleryImagePart.full);
    });

    test(
      'splits wide images into two visual pages when splitDualPage is true',
      () {
        final plan = GalleryPagePlan(
          sourcePageCount: 3,
          splitDualPage: true,
          direction: GalleryReadingDirection.leftToRight,
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
      },
    );

    test('两个半页映射同一 sourcePage', () {
      final plan = GalleryPagePlan(
        sourcePageCount: 3,
        splitDualPage: true,
        direction: GalleryReadingDirection.rightToLeft,
        wideSourceIndices: [1],
      );

      // Visual page 1 is right half of source 1 (page 2)
      expect(plan[1].sourceIndex, 1);
      expect(plan[1].sourcePage, 2);
      expect(plan.visualIndexToSourcePage(1), 2);
      expect(plan.visualIndexToSourceIndex(1), 1);

      // Visual page 2 is left half of source 1 (page 2)
      expect(plan[2].sourceIndex, 1);
      expect(plan[2].sourcePage, 2);
      expect(plan.visualIndexToSourcePage(2), 2);
      expect(plan.visualIndexToSourceIndex(2), 1);

      // Both map to the exact same source page number
      expect(plan[1].sourcePage, equals(plan[2].sourcePage));
    });
  });

  group('GalleryPagePlan idempotency and dynamic insertion', () {
    test('重复 markWide 幂等', () {
      final plan = GalleryPagePlan(sourcePageCount: 3, splitDualPage: true);
      expect(plan.displayPageCount, 3);

      // First call marks as wide
      final changed1 = plan.markWide(1);
      expect(changed1, isTrue);
      expect(plan.displayPageCount, 4);

      // Second call with same index is idempotent
      final changed2 = plan.markWide(1);
      expect(changed2, isFalse);
      expect(plan.displayPageCount, 4);

      // Third call is also idempotent
      final changed3 = plan.markWide(1, true);
      expect(changed3, isFalse);
      expect(plan.displayPageCount, 4);

      // Unmark wide
      final changed4 = plan.markWide(1, false);
      expect(changed4, isTrue);
      expect(plan.displayPageCount, 3);

      // Second unmark call is idempotent
      final changed5 = plan.markWide(1, false);
      expect(changed5, isFalse);
      expect(plan.displayPageCount, 3);
    });

    test('前方动态插入可按 stableId 找回', () {
      final plan = GalleryPagePlan(
        sourcePageCount: 4,
        splitDualPage: true,
        direction: GalleryReadingDirection.leftToRight,
        wideSourceIndices: [2],
      );

      // Initial visual pages:
      // 0: 0:full
      // 1: 1:full
      // 2: 2:left
      // 3: 2:right
      // 4: 3:full
      expect(plan.displayPageCount, 5);
      expect(plan[3].stableId, '2:right');
      expect(plan.findVisualIndexByStableId('2:right'), 3);

      // Earlier page (index 0) dynamically loads and is marked wide
      final changed = plan.markWide(0);
      expect(changed, isTrue);

      // Visual pages after insertion in front:
      // 0: 0:left
      // 1: 0:right
      // 2: 1:full
      // 3: 2:left
      // 4: 2:right  <-- shifted from index 3 to 4!
      // 5: 3:full
      expect(plan.displayPageCount, 6);
      expect(plan.findVisualIndexByStableId('2:right'), 4);
      expect(
        plan.recoverVisualIndex(stableId: '2:right', fallbackVisualIndex: 3),
        4,
      );

      // Check recovery when splitting is turned off
      plan.splitDualPage = false;
      // '2:right' is no longer a distinct page, but recoverVisualIndex falls back to source 2's visual index
      expect(
        plan.recoverVisualIndex(stableId: '2:right', fallbackVisualIndex: 0),
        2,
      );
    });
  });

  group('visual end judgment', () {
    test('末页第二半才 visual end', () {
      // 3 source pages (0, 1, 2); last source page (index 2) is wide and split
      final plan = GalleryPagePlan(
        sourcePageCount: 3,
        splitDualPage: true,
        direction: GalleryReadingDirection.leftToRight,
        wideSourceIndices: [2],
      );

      // Visual pages:
      // 0: 0:full
      // 1: 1:full
      // 2: 2:left  (first half of last page)
      // 3: 2:right (second half of last page)
      expect(plan.displayPageCount, 4);

      // First half of last page is NOT visual end
      expect(plan.isVisualEnd(2), isFalse);
      expect(plan.isLastVisualPageOfSource(2), isFalse);

      // Only the second half of last page IS visual end
      expect(plan.isVisualEnd(3), isTrue);
      expect(plan.isLastVisualPageOfSource(3), isTrue);

      // First visual page is visual start
      expect(plan.isVisualStart(0), isTrue);
      expect(plan.isVisualStart(1), isFalse);
    });

    test('non-wide last page has visual end at its only page', () {
      final plan = GalleryPagePlan(
        sourcePageCount: 3,
        splitDualPage: true,
        wideSourceIndices: [0], // page 0 is wide, page 2 is NOT wide
      );

      // Visual pages:
      // 0: 0:left, 1: 0:right, 2: 1:full, 3: 2:full
      expect(plan.displayPageCount, 4);
      expect(plan.isVisualEnd(2), isFalse);
      expect(plan.isVisualEnd(3), isTrue);
    });

    test(
      'resolution states gating: unresolved=false, resolved nonwide=true, resolved wide first=false/second=true',
      () {
        final plan = GalleryPagePlan(
          sourcePageCount: 3,
          direction: GalleryReadingDirection.leftToRight,
          splitDualPage: true,
        );

        // Unresolved last source page -> false
        expect(
          isVisualPageAtLastPartOfSource(
            plan: plan,
            visualIndex: 2,
            isSplitEnabled: true,
            isSourceResolved: false,
          ),
          isFalse,
        );
        expect(
          plan.isVisualPartComplete(visualIndex: 2, isSourceResolved: false),
          isFalse,
        );

        // Resolved non-wide -> true
        expect(
          isVisualPageAtLastPartOfSource(
            plan: plan,
            visualIndex: 2,
            isSplitEnabled: true,
            isSourceResolved: true,
          ),
          isTrue,
        );
        expect(
          plan.isVisualPartComplete(visualIndex: 2, isSourceResolved: true),
          isTrue,
        );

        // Split as wide -> 2 visual parts
        plan.markWide(2, true);
        expect(plan.displayPageCount, 4);

        // First half -> false
        expect(
          isVisualPageAtLastPartOfSource(
            plan: plan,
            visualIndex: 2,
            isSplitEnabled: true,
            isSourceResolved: true,
          ),
          isFalse,
        );
        expect(
          plan.isVisualPartComplete(visualIndex: 2, isSourceResolved: true),
          isFalse,
        );

        // Second half -> true
        expect(
          isVisualPageAtLastPartOfSource(
            plan: plan,
            visualIndex: 3,
            isSplitEnabled: true,
            isSourceResolved: true,
          ),
          isTrue,
        );
        expect(
          plan.isVisualPartComplete(visualIndex: 3, isSourceResolved: true),
          isTrue,
        );
      },
    );
  });
}
