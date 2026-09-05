import 'dart:collection';

import 'package:flutter/foundation.dart';

/// Represents the reading direction for gallery page planning.
enum GalleryReadingDirection {
  leftToRight,
  rightToLeft,
  topToBottom;

  bool get isRtl => this == GalleryReadingDirection.rightToLeft;
  bool get isTopToBottom => this == GalleryReadingDirection.topToBottom;
  bool get isLtr => this == GalleryReadingDirection.leftToRight;
}

/// Represents which part of an image is displayed.
enum GalleryImagePart {
  full,
  left,
  right;

  bool get isSplit => this != GalleryImagePart.full;
  bool get isLeft => this == GalleryImagePart.left;
  bool get isRight => this == GalleryImagePart.right;
  bool get isFull => this == GalleryImagePart.full;
}

/// An immutable descriptor for a single visual page in the gallery reader.
@immutable
class GalleryDisplayPage {
  const GalleryDisplayPage({
    required this.sourceIndex,
    this.part = GalleryImagePart.full,
  }) : assert(sourceIndex >= 0);

  /// The 0-based source image index.
  final int sourceIndex;

  /// The part of the source image to display.
  final GalleryImagePart part;

  /// 1-based source page number.
  int get sourcePage => sourceIndex + 1;

  /// Stable identifier for this visual page (e.g. '0:full', '2:right').
  String get stableId => '$sourceIndex:${part.name}';

  bool get isSplit => part.isSplit;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GalleryDisplayPage &&
          runtimeType == other.runtimeType &&
          sourceIndex == other.sourceIndex &&
          part == other.part;

  @override
  int get hashCode => Object.hash(sourceIndex, part);

  @override
  String toString() =>
      'GalleryDisplayPage(sourceIndex: $sourceIndex, part: $part)';
}

/// Pure helper to resolve wide image split part order based on reading direction and inversion.
List<GalleryImagePart> resolveWideImageParts({
  required GalleryReadingDirection direction,
  bool invert = false,
}) {
  final bool rightFirst;
  switch (direction) {
    case GalleryReadingDirection.leftToRight:
      rightFirst = invert;
      break;
    case GalleryReadingDirection.rightToLeft:
    case GalleryReadingDirection.topToBottom:
      rightFirst = !invert;
      break;
  }
  return rightFirst
      ? const [GalleryImagePart.right, GalleryImagePart.left]
      : const [GalleryImagePart.left, GalleryImagePart.right];
}

/// Pure helper to resolve wide image split part order with explicit direction flags.
List<GalleryImagePart> resolveWideImagePartsForDirection({
  bool isRtl = false,
  bool isTopToBottom = false,
  bool invert = false,
}) {
  final bool rightFirst = (isRtl || isTopToBottom) ? !invert : invert;
  return rightFirst
      ? const [GalleryImagePart.right, GalleryImagePart.left]
      : const [GalleryImagePart.left, GalleryImagePart.right];
}

/// Pure helper to verify if a visual page is the final visual part of its source,
/// guarding against premature chapter completion when source dimensions are unresolved.
bool isVisualPageAtLastPartOfSource({
  required GalleryPagePlan plan,
  required int visualIndex,
  required bool isSplitEnabled,
  required bool isSourceResolved,
}) {
  if (!isSplitEnabled) return true;
  if (!isSourceResolved) return false;
  return plan.isLastVisualPageOfSource(visualIndex);
}

/// Computes and manages the mapping between source comic images and visual pages.
class GalleryPagePlan {
  GalleryPagePlan({
    required int sourcePageCount,
    GalleryReadingDirection direction = GalleryReadingDirection.leftToRight,
    bool splitDualPage = false,
    bool splitDualPageInvert = false,
    Iterable<int>? wideSourceIndices,
  }) : _sourcePageCount = sourcePageCount,
       _direction = direction,
       _splitDualPage = splitDualPage,
       _splitDualPageInvert = splitDualPageInvert,
       _wideSourceIndices = SplayTreeSet<int>.from(
         (wideSourceIndices ?? const <int>[]).where(
           (i) => i >= 0 && i < sourcePageCount,
         ),
       ) {
    _rebuild();
  }

  int _sourcePageCount;
  GalleryReadingDirection _direction;
  bool _splitDualPage;
  bool _splitDualPageInvert;
  final SplayTreeSet<int> _wideSourceIndices;

  List<GalleryDisplayPage> _displayPages = const [];

  int get sourcePageCount => _sourcePageCount;
  set sourcePageCount(int count) {
    if (_sourcePageCount != count) {
      _sourcePageCount = count;
      _wideSourceIndices.removeWhere((i) => i >= count);
      _rebuild();
    }
  }

  GalleryReadingDirection get direction => _direction;
  set direction(GalleryReadingDirection value) {
    if (_direction != value) {
      _direction = value;
      _rebuild();
    }
  }

  bool get splitDualPage => _splitDualPage;
  set splitDualPage(bool value) {
    if (_splitDualPage != value) {
      _splitDualPage = value;
      _rebuild();
    }
  }

  bool get splitDualPageInvert => _splitDualPageInvert;
  set splitDualPageInvert(bool value) {
    if (_splitDualPageInvert != value) {
      _splitDualPageInvert = value;
      _rebuild();
    }
  }

  Set<int> get wideSourceIndices => Set.unmodifiable(_wideSourceIndices);

  List<GalleryDisplayPage> get displayPages => _displayPages;

  int get displayPageCount => _displayPages.length;

  int get length => _displayPages.length;

  bool get isEmpty => _displayPages.isEmpty;

  bool get isNotEmpty => _displayPages.isNotEmpty;

  GalleryDisplayPage operator [](int visualIndex) => _displayPages[visualIndex];

  bool isWide(int sourceIndex) => _wideSourceIndices.contains(sourceIndex);

  bool isSourceSplit(int sourceIndex) =>
      _splitDualPage && _wideSourceIndices.contains(sourceIndex);

  /// Idempotently marks a source image as wide or not wide.
  /// Returns true if the plan structure was modified.
  bool markWide(int sourceIndex, [bool isWide = true]) {
    if (sourceIndex < 0 || sourceIndex >= _sourcePageCount) {
      return false;
    }
    if (isWide) {
      if (_wideSourceIndices.add(sourceIndex)) {
        if (_splitDualPage) {
          _rebuild();
        }
        return true;
      }
      return false;
    } else {
      if (_wideSourceIndices.remove(sourceIndex)) {
        if (_splitDualPage) {
          _rebuild();
        }
        return true;
      }
      return false;
    }
  }

  /// Updates settings and rebuilds if any value changed.
  bool updateSettings({
    int? sourcePageCount,
    GalleryReadingDirection? direction,
    bool? splitDualPage,
    bool? splitDualPageInvert,
  }) {
    bool changed = false;
    if (sourcePageCount != null && _sourcePageCount != sourcePageCount) {
      _sourcePageCount = sourcePageCount;
      _wideSourceIndices.removeWhere((i) => i >= sourcePageCount);
      changed = true;
    }
    if (direction != null && _direction != direction) {
      _direction = direction;
      changed = true;
    }
    if (splitDualPage != null && _splitDualPage != splitDualPage) {
      _splitDualPage = splitDualPage;
      changed = true;
    }
    if (splitDualPageInvert != null &&
        _splitDualPageInvert != splitDualPageInvert) {
      _splitDualPageInvert = splitDualPageInvert;
      changed = true;
    }
    if (changed) {
      _rebuild();
    }
    return changed;
  }

  GalleryDisplayPage displayPageAt(int visualIndex) {
    if (visualIndex < 0 || visualIndex >= _displayPages.length) {
      throw RangeError.index(visualIndex, _displayPages, 'visualIndex');
    }
    return _displayPages[visualIndex];
  }

  GalleryDisplayPage? maybeDisplayPageAt(int visualIndex) {
    if (visualIndex < 0 || visualIndex >= _displayPages.length) {
      return null;
    }
    return _displayPages[visualIndex];
  }

  int visualIndexToSourceIndex(int visualIndex) {
    return displayPageAt(visualIndex).sourceIndex;
  }

  int visualIndexToSourcePage(int visualIndex) {
    return visualIndexToSourceIndex(visualIndex) + 1;
  }

  int sourceIndexToFirstVisualIndex(int sourceIndex) {
    for (int i = 0; i < _displayPages.length; i++) {
      if (_displayPages[i].sourceIndex == sourceIndex) {
        return i;
      }
    }
    return -1;
  }

  List<int> sourceIndexToVisualIndices(int sourceIndex) {
    final indices = <int>[];
    for (int i = 0; i < _displayPages.length; i++) {
      if (_displayPages[i].sourceIndex == sourceIndex) {
        indices.add(i);
      }
    }
    return indices;
  }

  int sourceIndexToLastVisualIndex(int sourceIndex) {
    for (int i = _displayPages.length - 1; i >= 0; i--) {
      if (_displayPages[i].sourceIndex == sourceIndex) {
        return i;
      }
    }
    return -1;
  }

  int? findVisualIndexByStableId(String stableId) {
    for (int i = 0; i < _displayPages.length; i++) {
      if (_displayPages[i].stableId == stableId) {
        return i;
      }
    }
    return null;
  }

  /// Recovers a visual index when the layout changes, using [stableId] with fallback.
  int recoverVisualIndex({
    required String stableId,
    int fallbackVisualIndex = 0,
  }) {
    if (_displayPages.isEmpty) return 0;
    final direct = findVisualIndexByStableId(stableId);
    if (direct != null) return direct;

    final colon = stableId.indexOf(':');
    if (colon > 0) {
      final parsedSourceIndex = int.tryParse(stableId.substring(0, colon));
      if (parsedSourceIndex != null) {
        final firstVisual = sourceIndexToFirstVisualIndex(parsedSourceIndex);
        if (firstVisual != -1) return firstVisual;
      }
    }
    return fallbackVisualIndex.clamp(0, _displayPages.length - 1);
  }

  /// Whether [visualIndex] corresponds to the visual end of the gallery.
  /// If the final source page is split, only its second half is the visual end.
  bool isVisualEnd(int visualIndex) {
    if (_displayPages.isEmpty) return true;
    return visualIndex >= _displayPages.length - 1;
  }

  /// Whether [visualIndex] corresponds to the visual start of the gallery.
  bool isVisualStart(int visualIndex) {
    return visualIndex <= 0;
  }

  /// Whether [visualIndex] is the first visual page for its corresponding source page.
  bool isFirstVisualPageOfSource(int visualIndex) {
    if (visualIndex < 0 || visualIndex >= _displayPages.length) return false;
    if (visualIndex == 0) return true;
    return _displayPages[visualIndex].sourceIndex !=
        _displayPages[visualIndex - 1].sourceIndex;
  }

  /// Whether [visualIndex] is the last visual page for its corresponding source page.
  bool isLastVisualPageOfSource(int visualIndex) {
    if (visualIndex < 0 || visualIndex >= _displayPages.length) return false;
    if (visualIndex == _displayPages.length - 1) return true;
    return _displayPages[visualIndex].sourceIndex !=
        _displayPages[visualIndex + 1].sourceIndex;
  }

  /// Checks if [visualIndex] is the last visual part of its source page,
  /// requiring [isSourceResolved] when [splitDualPage] is active.
  bool isVisualPartComplete({
    required int visualIndex,
    required bool isSourceResolved,
  }) {
    if (!_splitDualPage) return true;
    if (!isSourceResolved) return false;
    return isLastVisualPageOfSource(visualIndex);
  }

  void _rebuild() {
    final pages = <GalleryDisplayPage>[];
    final partsOrder = _splitDualPage
        ? resolveWideImageParts(
            direction: _direction,
            invert: _splitDualPageInvert,
          )
        : const [GalleryImagePart.full];

    for (int i = 0; i < _sourcePageCount; i++) {
      if (_splitDualPage && _wideSourceIndices.contains(i)) {
        for (final part in partsOrder) {
          pages.add(GalleryDisplayPage(sourceIndex: i, part: part));
        }
      } else {
        pages.add(
          GalleryDisplayPage(sourceIndex: i, part: GalleryImagePart.full),
        );
      }
    }
    _displayPages = List.unmodifiable(pages);
  }
}

/// Represents the user's visual page location before layout changes.
@immutable
sealed class GalleryVisualLocation {
  const GalleryVisualLocation();
}

/// Indicates the user is on the chapter comments page.
class GalleryCommentsLocation extends GalleryVisualLocation {
  const GalleryCommentsLocation();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is GalleryCommentsLocation;

  @override
  int get hashCode => 0;
}

/// Indicates an intent to be placed on the final visual page of the chapter
/// (e.g. when jumping to the end of the previous chapter).
class GalleryTargetLastVisualLocation extends GalleryVisualLocation {
  const GalleryTargetLastVisualLocation();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is GalleryTargetLastVisualLocation;

  @override
  int get hashCode => 1;
}

/// Indicates the user is viewing a comic image visual page.
class GalleryPageLocation extends GalleryVisualLocation {
  const GalleryPageLocation({
    required this.stableId,
    required this.fallbackVisualIndex,
  });

  final String stableId;
  final int fallbackVisualIndex;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GalleryPageLocation &&
          runtimeType == other.runtimeType &&
          stableId == other.stableId &&
          fallbackVisualIndex == other.fallbackVisualIndex;

  @override
  int get hashCode => Object.hash(stableId, fallbackVisualIndex);
}

/// Pure function to resolve the target controller index after layout changes.
int resolveRecoveredControllerIndex({
  required GalleryVisualLocation location,
  required GalleryPagePlan plan,
  required bool isLastSourceResolved,
  required int totalVisualImagePages,
  bool hasCommentsTailGrowth = false,
}) {
  if (location is GalleryCommentsLocation) {
    if (hasCommentsTailGrowth) {
      return totalVisualImagePages;
    }
    return totalVisualImagePages + 1;
  }
  if (location is GalleryTargetLastVisualLocation) {
    final lastSourceIndex = plan.sourcePageCount - 1;
    if (isLastSourceResolved) {
      final lastVisual = plan.sourceIndexToLastVisualIndex(lastSourceIndex);
      return (lastVisual != -1 ? lastVisual : plan.displayPageCount - 1) + 1;
    } else {
      return plan.displayPageCount;
    }
  }
  if (location is GalleryPageLocation) {
    final newVisual = plan.recoverVisualIndex(
      stableId: location.stableId,
      fallbackVisualIndex: location.fallbackVisualIndex,
    );
    return newVisual + 1;
  }
  return 1;
}

/// Coalesces multiple dynamic size updates in the same frame, capturing
/// the stable descriptor once before the initial mutation and preventing
/// subsequent mutations in the batch from reading corrupted state.
class GallerySizeUpdateCoalescer {
  GalleryVisualLocation? _initialLocation;
  bool _hasPendingUpdates = false;
  bool _hasCommentsTailGrowth = false;

  bool get hasPendingUpdates => _hasPendingUpdates;
  GalleryVisualLocation? get initialLocation => _initialLocation;
  bool get hasCommentsTailGrowth => _hasCommentsTailGrowth;

  /// Captures initial visual location before any plan mutation if not already batching.
  void recordInitialLocation(GalleryVisualLocation location) {
    if (!_hasPendingUpdates) {
      _hasPendingUpdates = true;
      _initialLocation = location;
      _hasCommentsTailGrowth = false;
    }
  }

  void markCommentsTailGrowth() {
    _hasCommentsTailGrowth = true;
  }

  /// Flushes the batch, returning the saved initial location and resetting batch state.
  GalleryVisualLocation? flush() {
    if (!_hasPendingUpdates) return null;
    final loc = _initialLocation;
    _initialLocation = null;
    _hasPendingUpdates = false;
    _hasCommentsTailGrowth = false;
    return loc;
  }

  void reset() {
    _initialLocation = null;
    _hasPendingUpdates = false;
    _hasCommentsTailGrowth = false;
  }
}
