import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/foundation.dart';
import 'package:photo_view/photo_view.dart';

import 'gallery_page_plan.dart';

/// Resolves the stable cache key for a [PhotoViewController] in Gallery mode.
///
/// In split mode:
/// - Comments page: returns `'comments'`.
/// - Image visual page: returns the visual page's [GalleryDisplayPage.stableId] (e.g. `'0:full'`, `'1:left'`).
///
/// In non-split mode:
/// - Comments page: returns `'comments'`.
/// - Image page: returns a range-based key `'source:$start-$end'` representing the source slice.
String resolveControllerKey({
  required int controllerIndex,
  required bool isSplitEnabled,
  required GalleryPagePlan? plan,
  required bool isCommentsPage,
  required (int, int) Function(int index) getPageImagesRange,
}) {
  if (isCommentsPage) {
    return 'comments';
  }
  if (isSplitEnabled && plan != null) {
    final visualIndex = controllerIndex - 1;
    final displayPage = plan.maybeDisplayPageAt(visualIndex);
    return displayPage?.stableId ?? '$visualIndex:fallback';
  }
  final range = getPageImagesRange(controllerIndex);
  return 'source:${range.$1}-${range.$2}';
}

/// Resolves the visible stable identity of the current visual page.
///
/// Returns null if [controllerIndex] is out of bounds (e.g. sentinels).
/// For split pages, returns [GalleryDisplayPage.stableId] (differentiating left and right halves).
/// For non-split pages, returns `'source:$start-$end'`.
String? resolveVisibleStableIdentity({
  required int controllerIndex,
  required int totalVisualPages,
  required bool isSplitEnabled,
  required GalleryPagePlan? plan,
  required bool isCommentsPage,
  required (int, int) Function(int index) getPageImagesRange,
}) {
  if (controllerIndex <= 0 || controllerIndex > totalVisualPages) {
    return null;
  }
  if (isCommentsPage) {
    return 'comments';
  }
  if (isSplitEnabled && plan != null) {
    final visualIndex = controllerIndex - 1;
    final displayPage = plan.maybeDisplayPageAt(visualIndex);
    return displayPage?.stableId;
  }
  final range = getPageImagesRange(controllerIndex);
  return 'source:${range.$1}-${range.$2}';
}

/// Evaluates whether an E-Ink screen refresh should be requested.
///
/// An E-Ink refresh is triggered ONLY when:
/// 1. The page is not the chapter comments page.
/// 2. The new visible stable identity is non-null.
/// 3. The new visible stable identity is DIFFERENT from [previousIdentity].
///
/// Transitions between the left and right halves of the same source page have
/// different stable IDs (e.g. `'1:left'` vs `'1:right'`), so they WILL refresh.
/// Layout recovery shifts that alter the numeric controller index while maintaining
/// the same stable ID (e.g. index 2 -> 3 with stableId `'1:full'`) will NOT refresh.
bool shouldRefreshEInk({
  required String? previousIdentity,
  required String? currentIdentity,
  required bool isCommentsPage,
}) {
  if (isCommentsPage) return false;
  if (currentIdentity == null) return false;
  if (previousIdentity == currentIdentity) return false;
  return true;
}

/// Checks whether the final source image's dimensions have been resolved
/// when positioned on the chapter comments page.
bool isCommentsSourceSizeResolved({
  required bool isSplitEnabled,
  required int sourcePageCount,
  required Set<int> resolvedSourceIndices,
}) {
  if (!isSplitEnabled || sourcePageCount <= 0) return true;
  return resolvedSourceIndices.contains(sourcePageCount - 1);
}

/// Checks whether the user on the chapter comments page is at the last visual
/// part of the source images.
///
/// Requires the final source image to be resolved in split mode.
bool isCommentsAtLastVisualPartOfSource({
  required bool isSplitEnabled,
  required int sourcePageCount,
  required Set<int> resolvedSourceIndices,
}) {
  return isCommentsSourceSizeResolved(
    isSplitEnabled: isSplitEnabled,
    sourcePageCount: sourcePageCount,
    resolvedSourceIndices: resolvedSourceIndices,
  );
}

/// Pure decision on whether a dynamic size update while positioned at Comments
/// causes visual tail growth that requires recovering to the newly added final visual half.
///
/// In split dual page mode:
/// If the user is at Comments and the final source image is confirmed wide for the first
/// time ([isCommentsLocation] is true, [isLastSource] is true, [isWide] is true, [wasWide] is false,
/// and [wasResolved] is false), tail growth has occurred. The reader must recover to the newly
/// added final visual half (with controller index pointing to the final half, `reader.page = maxPage`,
/// and chapter completion suppressed).
///
/// Non-tail split, non-wide, or repeated callbacks return false and preserve existing comments semantics.
bool shouldRecoverCommentsToFinalVisualHalf({
  required bool isCommentsLocation,
  required bool isLastSource,
  required bool isWide,
  required bool wasWide,
  required bool wasResolved,
}) {
  if (!isCommentsLocation) return false;
  if (!isLastSource) return false;
  if (wasResolved) return false;
  if (wasWide) return false;
  if (!isWide) return false;
  return true;
}

/// Outcome of resolving a recovery destination when positioned at Comments.
@immutable
class CommentsTailGrowthRecoveryResult {
  const CommentsTailGrowthRecoveryResult({
    required this.shouldRecoverToFinalVisualHalf,
    required this.targetControllerIndex,
    required this.targetReaderPage,
    required this.notifyChapterCompleted,
  });

  /// Whether the reader should recover to the newly added final visual half instead of Comments.
  final bool shouldRecoverToFinalVisualHalf;

  /// The 1-based controller index to navigate to.
  final int targetControllerIndex;

  /// The 1-based reader page value to set on [ReaderLocation].
  final int targetReaderPage;

  /// Whether chapter completion notification should be evaluated.
  final bool notifyChapterCompleted;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CommentsTailGrowthRecoveryResult &&
          shouldRecoverToFinalVisualHalf ==
              other.shouldRecoverToFinalVisualHalf &&
          targetControllerIndex == other.targetControllerIndex &&
          targetReaderPage == other.targetReaderPage &&
          notifyChapterCompleted == other.notifyChapterCompleted;

  @override
  int get hashCode => Object.hash(
    shouldRecoverToFinalVisualHalf,
    targetControllerIndex,
    targetReaderPage,
    notifyChapterCompleted,
  );

  @override
  String toString() =>
      'CommentsTailGrowthRecoveryResult(shouldRecoverToFinalVisualHalf: $shouldRecoverToFinalVisualHalf, '
      'targetControllerIndex: $targetControllerIndex, targetReaderPage: $targetReaderPage, '
      'notifyChapterCompleted: $notifyChapterCompleted)';
}

/// Resolves the recovery outcome for a Comments location following a dynamic layout update.
CommentsTailGrowthRecoveryResult resolveCommentsRecoveryTarget({
  required bool hasCommentsTailGrowth,
  required int totalVisualImagePages,
  required int maxPage,
}) {
  if (hasCommentsTailGrowth) {
    return CommentsTailGrowthRecoveryResult(
      shouldRecoverToFinalVisualHalf: true,
      targetControllerIndex: totalVisualImagePages,
      targetReaderPage: maxPage,
      notifyChapterCompleted: false,
    );
  } else {
    return CommentsTailGrowthRecoveryResult(
      shouldRecoverToFinalVisualHalf: false,
      targetControllerIndex: totalVisualImagePages + 1,
      targetReaderPage: maxPage + 1,
      notifyChapterCompleted: true,
    );
  }
}

/// Represents the decision outcome of a visual page movement request.
@immutable
class VisualMoveDecision {
  const VisualMoveDecision({
    required this.consumed,
    required this.canMove,
    this.targetIndex,
  });

  /// Whether the input event was consumed by the visual reader.
  /// If true, the caller must NOT perform fallback navigation (e.g. source toPage or chapter skip).
  final bool consumed;

  /// Whether a page transition animation/jump should proceed.
  final bool canMove;

  /// The target 1-based controller index when [canMove] is true.
  final int? targetIndex;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VisualMoveDecision &&
          consumed == other.consumed &&
          canMove == other.canMove &&
          targetIndex == other.targetIndex;

  @override
  int get hashCode => Object.hash(consumed, canMove, targetIndex);

  @override
  String toString() =>
      'VisualMoveDecision(consumed: $consumed, canMove: $canMove, targetIndex: $targetIndex)';
}

/// Pure policy deciding visual page navigation.
///
/// During ongoing page animation, returns `consumed: true, canMove: false` to consume
/// the input without initiating re-entrant animations or triggering fallbacks.
VisualMoveDecision decideVisualMove({
  required bool isAnimating,
  required int currentIndex,
  required int delta,
  required int totalVisualPages,
}) {
  if (isAnimating) {
    return const VisualMoveDecision(consumed: true, canMove: false);
  }
  final target = currentIndex + delta;
  if (target < 1 || target > totalVisualPages) {
    return const VisualMoveDecision(consumed: false, canMove: false);
  }
  return VisualMoveDecision(consumed: true, canMove: true, targetIndex: target);
}

/// Outcome of resolving a visual end jump.
@immutable
class VisualEndTarget {
  const VisualEndTarget({
    required this.targetIndex,
    required this.retainTargetLastVisualPage,
  });

  /// The target 1-based controller index.
  final int targetIndex;

  /// Whether the reader should retain the intent to land on the last visual page
  /// once dimensions finish resolving.
  final bool retainTargetLastVisualPage;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VisualEndTarget &&
          targetIndex == other.targetIndex &&
          retainTargetLastVisualPage == other.retainTargetLastVisualPage;

  @override
  int get hashCode => Object.hash(targetIndex, retainTargetLastVisualPage);

  @override
  String toString() =>
      'VisualEndTarget(targetIndex: $targetIndex, retainTargetLastVisualPage: $retainTargetLastVisualPage)';
}

/// Resolves the destination for `toVisualEnd`.
///
/// If split dual page is active:
/// - If the last source image is resolved, locates the last visual part (second half for wide images).
/// - If the last source image is not yet resolved, targets the current display end and retains
///   [retainTargetLastVisualPage] so layout recovery can position to the final half once resolved.
///
/// If split dual page is disabled, degrades to the standard source jump to [sourcePageCount].
VisualEndTarget resolveVisualEndTarget({
  required bool isSplitEnabled,
  required GalleryPagePlan? plan,
  required int sourcePageCount,
  required bool isLastSourceResolved,
  required int Function(int sourcePage) sourcePageToControllerIndex,
}) {
  if (!isSplitEnabled || plan == null || sourcePageCount <= 0) {
    final maxPage = math.max(1, sourcePageCount);
    return VisualEndTarget(
      targetIndex: sourcePageToControllerIndex(maxPage),
      retainTargetLastVisualPage: false,
    );
  }
  final lastSourceIndex = sourcePageCount - 1;
  if (isLastSourceResolved) {
    final lastVisual = plan.sourceIndexToLastVisualIndex(lastSourceIndex);
    final target = lastVisual != -1 ? lastVisual + 1 : plan.displayPageCount;
    return VisualEndTarget(
      targetIndex: target,
      retainTargetLastVisualPage: false,
    );
  } else {
    return VisualEndTarget(
      targetIndex: plan.displayPageCount,
      retainTargetLastVisualPage: true,
    );
  }
}

/// Resolves the controller index for a source page jump (e.g. via slider or `toPage`).
///
/// Always jumps to the FIRST visual half of the requested source page.
int resolveSourceJumpTarget({
  required bool isSplitEnabled,
  required GalleryPagePlan? plan,
  required int sourcePage,
  required int sourcePageCount,
}) {
  if (isSplitEnabled && plan != null) {
    final sourceIndex = (sourcePage - 1)
        .clamp(0, math.max(0, sourcePageCount - 1))
        .toInt();
    final firstVisual = plan.sourceIndexToFirstVisualIndex(sourceIndex);
    if (firstVisual != -1) {
      return firstVisual + 1;
    }
  }
  return sourcePage;
}

/// Resolves the set of stable controller keys that should be retained during pruning.
///
/// Retains the stable keys for pages in the visual adjacency window `[currentIndex - 1, currentIndex, currentIndex + 1]`.
/// Excludes chapter transition sentinels (index <= 0 or index >= totalVisualPages + 1).
/// Includes the comments page key ('comments') if present within the window.
Set<String> resolveKeepControllerKeys({
  required int currentIndex,
  required int totalVisualPages,
  required String Function(int index) resolveKeyForIndex,
}) {
  final keepKeys = <String>{};
  for (final idx in [currentIndex - 1, currentIndex, currentIndex + 1]) {
    if (idx >= 1 && idx <= totalVisualPages) {
      keepKeys.add(resolveKeyForIndex(idx));
    }
  }
  return keepKeys;
}

/// Manages the pool of [PhotoViewController]s keyed by stable strings.
///
/// Guarantees:
/// - Controllers are reused by stable key.
/// - Evicted controllers are disposed safely post-frame so active frame operations do not crash.
/// - Controllers are disposed at most once (no double-dispose).
/// - Number of active controllers is bounded.
class GalleryPhotoViewControllerPool {
  GalleryPhotoViewControllerPool({
    void Function(FrameCallback callback)? postFrameCallbackScheduler,
  }) : _postFrameCallbackScheduler =
           postFrameCallbackScheduler ??
           SchedulerBinding.instance.addPostFrameCallback;

  final void Function(FrameCallback callback) _postFrameCallbackScheduler;

  final Map<String, PhotoViewController> _controllers =
      <String, PhotoViewController>{};
  final Map<String, PhotoViewController> _pendingDisposeByKey =
      <String, PhotoViewController>{};
  final Expando<bool> _disposedExpando = Expando<bool>();
  int _disposedCount = 0;
  bool _disposeScheduled = false;

  Map<String, PhotoViewController> get controllers =>
      Map.unmodifiable(_controllers);

  int get activeCount => _controllers.length;
  int get pendingDisposeCount => _pendingDisposeByKey.length;
  int get disposedCount => _disposedCount;
  int get retainedCount => _controllers.length + _pendingDisposeByKey.length;

  PhotoViewController? operator [](String key) =>
      _controllers[key] ?? _pendingDisposeByKey[key];

  PhotoViewController getOrCreate(
    String key, {
    PhotoViewController Function()? factory,
  }) {
    var controller = _controllers[key];
    if (controller != null) {
      return controller;
    }
    controller = _pendingDisposeByKey.remove(key);
    if (controller != null) {
      _controllers[key] = controller;
      return controller;
    }
    controller = factory != null ? factory() : PhotoViewController();
    _controllers[key] = controller;
    return controller;
  }

  /// Evicts all controllers whose keys are not in [keepKeys], scheduling them for post-frame disposal.
  void pruneExcept(Set<String> keepKeys) {
    final toRemove = <String>[];
    for (final key in _controllers.keys) {
      if (!keepKeys.contains(key)) {
        toRemove.add(key);
      }
    }
    for (final key in toRemove) {
      final controller = _controllers.remove(key);
      if (controller != null) {
        _scheduleDispose(key, controller);
      }
    }
  }

  void _scheduleDispose(String key, PhotoViewController controller) {
    final old = _pendingDisposeByKey[key];
    if (old != null && !identical(old, controller)) {
      _safeDispose(old);
    }
    _pendingDisposeByKey[key] = controller;

    if (!_disposeScheduled) {
      _disposeScheduled = true;
      _postFrameCallbackScheduler((_) {
        _disposeScheduled = false;
        final toDispose = _pendingDisposeByKey.values.toList();
        _pendingDisposeByKey.clear();
        for (final c in toDispose) {
          _safeDispose(c);
        }
      });
    }
  }

  void _safeDispose(PhotoViewController controller) {
    if (_disposedExpando[controller] == true) {
      return;
    }
    _disposedExpando[controller] = true;
    _disposedCount++;
    try {
      controller.dispose();
    } catch (_) {
      // Guard against any external disposal
    }
  }

  /// Immediately and safely disposes all active and pending controllers.
  void disposeAll() {
    final all = <PhotoViewController>{
      ..._controllers.values,
      ..._pendingDisposeByKey.values,
    };
    _controllers.clear();
    _pendingDisposeByKey.clear();
    for (final c in all) {
      _safeDispose(c);
    }
  }
}
