import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:venera_next/components/gesture.dart';
import 'package:venera_next/components/loading.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/reader/chapter_comments.dart';
import 'package:venera_next/features/reader/comic_image.dart';
import 'package:venera_next/features/reader/gallery_page_plan.dart';
import 'package:venera_next/features/reader/gallery_coordinator.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/features/reader/waterfall_flow.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/image_provider/reader_image.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';
import 'package:venera_next/network/images.dart';

class ReaderImages extends StatefulWidget {
  const ReaderImages({super.key});

  @override
  State<ReaderImages> createState() => ReaderImagesState();
}

class ReaderImagesState extends State<ReaderImages> {
  String? error;

  bool inProgress = false;

  late ReaderState reader;

  @override
  void initState() {
    reader = context.reader;
    reader.onReaderContentLoading();
    reader.isLoading = true;
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
    ImageDownloader.cancelAllLoadingImages();
  }

  /// Handle jumping to last page when jumpToLastPageOnLoad is true
  void _handleJumpToLastPage() {
    if (reader.jumpToLastPageOnLoad) {
      if (reader.isSplitDualPageEnabled) {
        reader.targetLastVisualPage = true;
      } else {
        reader.targetLastVisualPage = false;
      }
      reader.pageValue = reader.maxPage;
      reader.jumpToLastPageOnLoad = false;
    } else if (!reader.isSplitDualPageEnabled) {
      reader.targetLastVisualPage = false;
    }
  }

  void load() async {
    if (inProgress) return;
    inProgress = true;
    if (reader.type == ComicType.local ||
        (LocalManager().isDownloaded(
          reader.cid,
          reader.type,
          reader.chapter,
          reader.widget.chapters,
        ))) {
      try {
        var images = await LocalManager().getImages(
          reader.cid,
          reader.type,
          reader.chapter,
        );
        setState(() {
          reader.images = images;
          reader.isLoading = false;
          inProgress = false;
          _handleJumpToLastPage();
          Future.microtask(() {
            reader.onReaderContentReady();
            reader.updateHistory();
          });
        });
      } catch (e) {
        setState(() {
          error = e.toString();
          reader.isLoading = false;
          inProgress = false;
        });
      }
    } else {
      var cp = reader.widget.chapters?.ids.elementAtOrNull(reader.chapter - 1);
      var res = await reader.type.comicSource!.loadComicPages!(
        reader.widget.cid,
        cp,
      );
      if (res.error) {
        setState(() {
          error = res.errorMessage;
          reader.isLoading = false;
          inProgress = false;
        });
      } else {
        setState(() {
          reader.images = res.data;
          reader.isLoading = false;
          inProgress = false;
          _handleJumpToLastPage();
          Future.microtask(() {
            reader.onReaderContentReady();
            reader.updateHistory();
          });
        });
      }
    }
    context.readerScaffold.update();
  }

  @override
  Widget build(BuildContext context) {
    if (reader.isLoading) {
      load();
      return const Center(child: CircularProgressIndicator());
    } else if (error != null) {
      return GestureDetector(
        onTap: () {
          context.readerScaffold.openOrClose();
        },
        child: SizedBox.expand(
          child: NetworkError(
            message: error!,
            retry: () {
              setState(() {
                reader.isLoading = true;
                error = null;
              });
            },
          ),
        ),
      );
    } else {
      if (reader.mode.isGallery) {
        var showComments =
            appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterComments',
            ) ==
            true;
        var showCommentsAtEnd =
            appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterCommentsAtEnd',
            ) ==
            true;
        var splitDualPage =
            appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'splitDualPage',
            ) ==
            true;
        var splitDualPageInvert =
            appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'splitDualPageInvert',
            ) ==
            true;
        return _GalleryMode(
          key: Key(
            '${reader.mode.key}_${reader.imagesPerPage}_${showComments}_${showCommentsAtEnd}_${splitDualPage}_${splitDualPageInvert}_${reader.chapter}',
          ),
        );
      } else {
        return _ContinuousMode(
          key: Key(reader.mode.key),
          crossChapter: reader.mode.isWaterfall,
        );
      }
    }
  }
}

GalleryReadingDirection _galleryReadingDirectionOf(ReaderMode mode) {
  switch (mode) {
    case ReaderMode.galleryRightToLeft:
    case ReaderMode.continuousRightToLeft:
      return GalleryReadingDirection.rightToLeft;
    case ReaderMode.galleryTopToBottom:
    case ReaderMode.continuousTopToBottom:
    case ReaderMode.waterfallTopToBottom:
      return GalleryReadingDirection.topToBottom;
    case ReaderMode.galleryLeftToRight:
    case ReaderMode.continuousLeftToRight:
      return GalleryReadingDirection.leftToRight;
  }
}

@visibleForTesting
class GalleryMode extends StatefulWidget {
  const GalleryMode({super.key});

  @override
  State<GalleryMode> createState() => GalleryModeState();
}

typedef _GalleryMode = GalleryMode;

class GalleryModeState extends State<_GalleryMode>
    implements ReaderImageViewController {
  late PageController controller;

  int get preCacheCount => appdata.settings["preloadImageCount"];

  final _pool = GalleryPhotoViewControllerPool();
  String? _lastVisibleStableIdentity;
  bool _isAnimatingVisualPage = false;

  String _controllerKeyForIndex(int index) {
    return resolveControllerKey(
      controllerIndex: index,
      isSplitEnabled: isSplitEnabled,
      plan: _pagePlan,
      isCommentsPage: isChapterCommentsPage(index),
      getPageImagesRange: getPageImagesRange,
    );
  }

  String? _visibleStableIdentityForIndex(int index) {
    return resolveVisibleStableIdentity(
      controllerIndex: index,
      totalVisualPages: totalVisualPages,
      isSplitEnabled: isSplitEnabled,
      plan: _pagePlan,
      isCommentsPage: isChapterCommentsPage(index),
      getPageImagesRange: getPageImagesRange,
    );
  }

  late ReaderState reader;

  GalleryPagePlan? _pagePlan;
  int _currentControllerIndex = 1;
  int? _attachedChapter;
  final Set<int> _resolvedSourceIndices = <int>{};
  final _coalescer = GallerySizeUpdateCoalescer();
  bool _recoveryScheduled = false;
  bool isSourceSizeResolved(int sourceIndex) =>
      _resolvedSourceIndices.contains(sourceIndex);

  @override
  bool isReadyForChapter(int chapter) =>
      mounted && _attachedChapter == chapter && _pagePlan != null;

  @override
  bool isCurrentSourceSizeResolved() {
    if (!isSplitEnabled || _pagePlan == null) return true;
    final current = controller.hasClients && controller.page != null
        ? controller.page!.round()
        : _currentControllerIndex;
    if (isChapterCommentsPage(current)) {
      return isCommentsSourceSizeResolved(
        isSplitEnabled: isSplitEnabled,
        sourcePageCount: reader.images?.length ?? 0,
        resolvedSourceIndices: _resolvedSourceIndices,
      );
    }
    final visualIndex = current - 1;
    final displayPage = _pagePlan!.maybeDisplayPageAt(visualIndex);
    if (displayPage == null) return false;
    return _resolvedSourceIndices.contains(displayPage.sourceIndex);
  }

  bool get isSplitEnabled => reader.imagesPerPage == 1 && _splitDualPage;

  bool get _splitDualPage =>
      appdata.settings.getReaderSetting(
        reader.cid,
        reader.type.sourceKey,
        'splitDualPage',
      ) ==
      true;

  bool get _splitDualPageInvert =>
      appdata.settings.getReaderSetting(
        reader.cid,
        reader.type.sourceKey,
        'splitDualPageInvert',
      ) ==
      true;

  bool get showChapterCommentsAtEnd {
    if (reader.mode != ReaderMode.galleryLeftToRight &&
        reader.mode != ReaderMode.galleryRightToLeft) {
      return false;
    }
    if (reader.widget.chapters == null) return false;
    var source = ComicSource.find(reader.type.sourceKey);
    if (source?.chapterCommentsLoader == null) return false;
    return appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterComments',
            ) ==
            true &&
        appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterCommentsAtEnd',
            ) ==
            true;
  }

  int get totalImagePages {
    return !reader.showSingleImageOnFirstPage()
        ? (reader.images!.length / reader.imagesPerPage).ceil()
        : 1 + ((reader.images!.length - 1) / reader.imagesPerPage).ceil();
  }

  int get totalVisualImagePages => (isSplitEnabled && _pagePlan != null)
      ? _pagePlan!.displayPageCount
      : totalImagePages;

  int get totalVisualPages {
    var pages = totalVisualImagePages;
    if (showChapterCommentsAtEnd) pages++;
    return pages;
  }

  int get totalPages => totalVisualPages;

  bool isChapterCommentsPage(int pageIndex) {
    return showChapterCommentsAtEnd && pageIndex == totalVisualImagePages + 1;
  }

  var imageStates = <State<ComicImage>>{};

  bool isLongPressing = false;

  int fingers = 0;

  void _initPagePlan() {
    _resolvedSourceIndices.clear();
    _lastVisibleStableIdentity = null;
    _attachedChapter = reader.chapter;
    if (!isSplitEnabled) {
      _pagePlan = null;
      return;
    }
    final wideIndices = <int>[];
    if (reader.images != null) {
      for (int i = 0; i < reader.images!.length; i++) {
        final provider = _createImageProvider(i + 1, context);
        final size = ComicImage.getCachedImageSize(provider);
        if (size != null) {
          _resolvedSourceIndices.add(i);
          if (shouldSplitWideImage(size)) {
            wideIndices.add(i);
          }
        }
      }
    }
    _pagePlan = GalleryPagePlan(
      sourcePageCount: reader.images?.length ?? 0,
      direction: _galleryReadingDirectionOf(reader.mode),
      splitDualPage: isSplitEnabled,
      splitDualPageInvert: _splitDualPageInvert,
      wideSourceIndices: wideIndices,
    );
  }

  int _computeInitialControllerIndex() {
    if (!isSplitEnabled || _pagePlan == null) {
      return reader.page;
    }
    if (reader.targetLastVisualPage) {
      final lastSourceIndex = (reader.images?.length ?? 0) - 1;
      if (isSourceSizeResolved(lastSourceIndex)) {
        reader.targetLastVisualPage = false;
        final lastVisual = _pagePlan!.sourceIndexToLastVisualIndex(
          lastSourceIndex,
        );
        return lastVisual != -1 ? lastVisual + 1 : _pagePlan!.displayPageCount;
      } else {
        return _pagePlan!.displayPageCount;
      }
    }
    if (reader.isOnChapterCommentsPage || reader.page > reader.maxPage) {
      return totalVisualImagePages + 1;
    }
    final sourceIndex = (reader.page - 1)
        .clamp(0, math.max(0, (reader.images?.length ?? 1) - 1))
        .toInt();
    final firstVisual = _pagePlan!.sourceIndexToFirstVisualIndex(sourceIndex);
    return firstVisual != -1 ? firstVisual + 1 : 1;
  }

  @override
  void initState() {
    reader = context.reader;
    _attachedChapter = reader.chapter;
    _initPagePlan();
    final initialPage = _computeInitialControllerIndex();
    _currentControllerIndex = initialPage;
    controller = PageController(initialPage: initialPage);
    reader.imageViewController = this;
    Future.microtask(() {
      context.readerScaffold.setFloatingButton(0);
      if (mounted) {
        reader.notifyChapterCompletedIfNeeded();
      }
    });
    super.initState();
  }

  @override
  void dispose() {
    if (reader.imageViewController == this) {
      reader.imageViewController = null;
    }
    _coalescer.reset();
    controller.dispose();
    if (_isAnimatingVisualPage) {
      _isAnimatingVisualPage = false;
      reader.endPageAnimation();
    }
    _pool.disposeAll();
    super.dispose();
  }

  void _onSourceImageSize(int sourceIndex, Size size) {
    if (!mounted || !isSplitEnabled || _pagePlan == null) return;
    final wasResolved = _resolvedSourceIndices.contains(sourceIndex);
    _resolvedSourceIndices.add(sourceIndex);

    final lastSourceIndex = (reader.images?.length ?? 0) - 1;
    final isLastSource = sourceIndex == lastSourceIndex;

    final isWide = shouldSplitWideImage(size);
    final wasWide = _pagePlan!.isWide(sourceIndex);
    final wideChanged = wasWide != isWide;

    if (!wideChanged) {
      if (isLastSource && reader.targetLastVisualPage) {
        reader.targetLastVisualPage = false;
      }
      if (!wasResolved) {
        reader.notifyChapterCompletedIfNeeded();
      }
      return;
    }

    if (!_coalescer.hasPendingUpdates) {
      final current = controller.hasClients && controller.page != null
          ? controller.page!.round()
          : _currentControllerIndex;
      final GalleryVisualLocation loc;
      if (isChapterCommentsPage(current)) {
        loc = const GalleryCommentsLocation();
      } else if (reader.targetLastVisualPage) {
        loc = const GalleryTargetLastVisualLocation();
      } else {
        final currentVisual = (current - 1)
            .clamp(0, math.max(0, _pagePlan!.displayPageCount - 1))
            .toInt();
        loc = GalleryPageLocation(
          stableId:
              _pagePlan!.maybeDisplayPageAt(currentVisual)?.stableId ??
              '$currentVisual:full',
          fallbackVisualIndex: currentVisual,
        );
      }
      _coalescer.recordInitialLocation(loc);
    }

    final isCommentsLocation =
        _coalescer.initialLocation is GalleryCommentsLocation;
    if (shouldRecoverCommentsToFinalVisualHalf(
      isCommentsLocation: isCommentsLocation,
      isLastSource: isLastSource,
      isWide: isWide,
      wasWide: wasWide,
      wasResolved: wasResolved,
    )) {
      _coalescer.markCommentsTailGrowth();
    }

    final modified = _pagePlan!.markWide(sourceIndex, isWide);
    if (!modified) return;

    _scheduleRecovery();
  }

  void _scheduleRecovery() {
    if (_recoveryScheduled) return;
    _recoveryScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _recoveryScheduled = false;
      _applyPendingSizeRecovery();
    });
  }

  void _applyPendingSizeRecovery() {
    if (!mounted) return;
    final hadCommentsTailGrowth = _coalescer.hasCommentsTailGrowth;
    final location = _coalescer.flush();
    if (location == null) return;

    final lastSourceIndex = (reader.images?.length ?? 0) - 1;
    final isLastResolved = isSourceSizeResolved(lastSourceIndex);

    if (location is GalleryTargetLastVisualLocation && isLastResolved) {
      reader.targetLastVisualPage = false;
    }

    final targetIndex = resolveRecoveredControllerIndex(
      location: location,
      plan: _pagePlan!,
      isLastSourceResolved: isLastResolved,
      totalVisualImagePages: totalVisualImagePages,
      hasCommentsTailGrowth: hadCommentsTailGrowth,
    );

    _currentControllerIndex = targetIndex;
    if (controller.hasClients && controller.page?.round() != targetIndex) {
      controller.jumpToPage(targetIndex);
    }

    if (location is GalleryCommentsLocation) {
      final recoveryTarget = resolveCommentsRecoveryTarget(
        hasCommentsTailGrowth: hadCommentsTailGrowth,
        totalVisualImagePages: totalVisualImagePages,
        maxPage: reader.maxPage,
      );
      if (hadCommentsTailGrowth) {
        reader.setPageSuppressingCompletion(recoveryTarget.targetReaderPage);
      } else {
        reader.setPage(recoveryTarget.targetReaderPage);
      }
      if (recoveryTarget.notifyChapterCompleted) {
        reader.notifyChapterCompletedIfNeeded();
      }
    } else {
      reader.notifyChapterCompletedIfNeeded();
    }

    setState(() {});
  }

  int controllerIndexToSourcePage(int index) {
    if (isChapterCommentsPage(index)) {
      return reader.maxPage + 1;
    }
    if (isSplitEnabled && _pagePlan != null) {
      final visualIndex = index - 1;
      if (visualIndex >= 0 && visualIndex < _pagePlan!.displayPageCount) {
        return _pagePlan!.visualIndexToSourcePage(visualIndex);
      }
    }
    return index;
  }

  int _sourcePageToControllerIndex(int sourcePage) {
    if (showChapterCommentsAtEnd && sourcePage > reader.maxPage) {
      return totalVisualImagePages + 1;
    }
    if (isSplitEnabled && _pagePlan != null) {
      final sourceIndex = (sourcePage - 1)
          .clamp(0, math.max(0, (reader.images?.length ?? 1) - 1))
          .toInt();
      final visualIndex = _pagePlan!.sourceIndexToFirstVisualIndex(sourceIndex);
      if (visualIndex != -1) {
        return visualIndex + 1;
      }
    }
    return sourcePage;
  }

  /// Get the range of images for the given page. [page] is 1-based.
  (int start, int end) getPageImagesRange(int page) {
    var imagesPerPage = reader.imagesPerPage;
    if (reader.showSingleImageOnFirstPage()) {
      if (page == 1) {
        return (0, 1);
      } else {
        int startIndex = (page - 2) * imagesPerPage + 1;
        int endIndex = math.min(
          startIndex + imagesPerPage,
          reader.images!.length,
        );
        return (startIndex, endIndex);
      }
    } else {
      int startIndex = (page - 1) * imagesPerPage;
      int endIndex = math.min(
        startIndex + imagesPerPage,
        reader.images!.length,
      );
      return (startIndex, endIndex);
    }
  }

  /// Get the image indices for current page. Returns null if no images.
  /// Returns a single index if only one image, or a range if multiple images.
  (int, int)? getCurrentPageImageRange() {
    if (reader.images == null ||
        reader.images!.isEmpty ||
        reader.isOnChapterCommentsPage ||
        reader.page > reader.maxPage ||
        reader.page < 1) {
      return null;
    }
    var (startIndex, endIndex) = getPageImagesRange(reader.page);
    return (startIndex, endIndex);
  }

  void cache(int startPage) {
    for (int i = startPage - 1; i <= startPage + preCacheCount; i++) {
      if (i == startPage ||
          i <= 0 ||
          i > totalPages ||
          isChapterCommentsPage(i)) {
        continue;
      }
      _cachePage(i, i == startPage + 1 || i == startPage - 1);
    }
  }

  void _cachePage(int page, bool shouldPreCache) {
    if (isChapterCommentsPage(page)) return;
    if (isSplitEnabled && _pagePlan != null) {
      final visualIndex = page - 1;
      if (visualIndex >= 0 && visualIndex < _pagePlan!.displayPageCount) {
        final sourceIndex = _pagePlan!.displayPageAt(visualIndex).sourceIndex;
        shouldPreCache
            ? _precacheImage(sourceIndex + 1, context)
            : _preDownloadImage(sourceIndex + 1, context);
      }
      return;
    }
    var (startIndex, endIndex) = getPageImagesRange(page);
    for (int i = startIndex; i < endIndex; i++) {
      shouldPreCache
          ? _precacheImage(i + 1, context)
          : _preDownloadImage(i + 1, context);
    }
  }

  Widget _buildChapterCommentsPage() {
    var source = ComicSource.find(reader.type.sourceKey);
    var chapters = reader.widget.chapters;
    if (source == null || chapters == null) return const SizedBox();
    var chapterIndex = reader.chapter - 1;
    return EmbeddedChapterCommentsPage(
      comicId: reader.cid,
      epId: chapters.ids.elementAt(chapterIndex),
      source: source,
      comicTitle: reader.widget.name,
      chapterTitle: chapters.titles.elementAt(chapterIndex),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_attachedChapter != reader.chapter) {
      _attachedChapter = reader.chapter;
      _lastVisibleStableIdentity = null;
    }
    return Listener(
      onPointerDown: (event) {
        fingers++;
      },
      onPointerUp: (event) {
        fingers--;
      },
      onPointerCancel: (event) {
        fingers--;
      },
      onPointerMove: (event) {
        if (isLongPressing) {
          final currentIndex = controller.hasClients && controller.page != null
              ? controller.page!.round()
              : _currentControllerIndex;
          final key = _controllerKeyForIndex(currentIndex);
          var currentController = _pool[key];
          Offset value = event.delta;
          if (isLongPressing) {
            currentController?.updateMultiple(
              position: currentController.position + value,
            );
          }
        }
      },
      child: PhotoViewGallery.builder(
        backgroundDecoration: BoxDecoration(color: context.colorScheme.surface),
        reverse: reader.mode == ReaderMode.galleryRightToLeft,
        scrollDirection: reader.mode == ReaderMode.galleryTopToBottom
            ? Axis.vertical
            : Axis.horizontal,
        itemCount: totalVisualPages + 2,
        builder: (BuildContext context, int index) {
          if (index == 0 || index == totalVisualPages + 1) {
            return PhotoViewGalleryPageOptions.customChild(
              child: const SizedBox(),
            );
          } else if (isChapterCommentsPage(index)) {
            return PhotoViewGalleryPageOptions.customChild(
              child: _buildChapterCommentsPage(),
            );
          } else {
            cache(index);
            final key = _controllerKeyForIndex(index);
            final photoViewController = _pool.getOrCreate(key);

            if (isSplitEnabled && _pagePlan != null) {
              final visualIndex = index - 1;
              final displayPage = _pagePlan![visualIndex];
              final sourceIndex = displayPage.sourceIndex;
              final part = displayPage.part;
              final imageKey = reader.images![sourceIndex];
              final provider = _createImageProviderFromKey(
                imageKey,
                context,
                sourceIndex + 1,
              );
              final viewportSize = MediaQuery.of(context).size;
              return PhotoViewGalleryPageOptions.customChild(
                childSize: viewportSize,
                controller: photoViewController,
                minScale: PhotoViewComputedScale.contained * 1.0,
                maxScale: PhotoViewComputedScale.covered * 10.0,
                child: SizedBox.fromSize(
                  size: viewportSize,
                  child: ComicImage(
                    image: provider,
                    wideImagePart: part,
                    onImageSize: (size) =>
                        _onSourceImageSize(sourceIndex, size),
                    fit: BoxFit.contain,
                    width: double.infinity,
                    height: double.infinity,
                    onInit: (state) => imageStates.add(state),
                    onDispose: (state) => imageStates.remove(state),
                  ),
                ),
              );
            }
            var (startIndex, endIndex) = getPageImagesRange(index);
            List<String> pageImages = reader.images!.sublist(
              startIndex,
              endIndex,
            );

            if (reader.imagesPerPage == 1 || pageImages.length == 1) {
              return PhotoViewGalleryPageOptions(
                filterQuality: FilterQuality.medium,
                controller: photoViewController,
                imageProvider: _createImageProviderFromKey(
                  pageImages[0],
                  context,
                  startIndex + 1,
                ),
                fit: BoxFit.contain,
                errorBuilder: (_, error, s, retry) {
                  return NetworkError(message: error.toString(), retry: retry);
                },
              );
            }

            final viewportSize = MediaQuery.of(context).size;
            return PhotoViewGalleryPageOptions.customChild(
              childSize: viewportSize,
              controller: photoViewController,
              minScale: PhotoViewComputedScale.contained * 1.0,
              maxScale: PhotoViewComputedScale.covered * 10.0,
              child: buildPageImages(pageImages, startIndex),
            );
          }
        },
        pageController: controller,
        loadingBuilder: (context, event) {
          return PhotoView.customChild(
            childSize: MediaQuery.of(context).size,
            initialScale: PhotoViewComputedScale.contained,
            minScale: PhotoViewComputedScale.contained * 1.0,
            maxScale: PhotoViewComputedScale.covered * 10.0,
            backgroundDecoration: BoxDecoration(
              color: context.colorScheme.surface,
            ),
            child: Center(
              child: SizedBox(
                width: 20.0,
                height: 20.0,
                child: CircularProgressIndicator(
                  backgroundColor: context.colorScheme.surfaceContainerHigh,
                  value: event == null || event.expectedTotalBytes == null
                      ? null
                      : event.cumulativeBytesLoaded / event.expectedTotalBytes!,
                ),
              ),
            ),
          );
        },
        onPageChanged: (i) {
          _currentControllerIndex = i;
          var shouldRefresh = false;
          if (i == 0) {
            _lastVisibleStableIdentity = null;
            if (reader.isFirstChapterOfGroup ||
                !reader.toPrevChapter(toLastPage: true)) {
              controller.jumpToPage(1);
            } else {
              shouldRefresh = true;
            }
          } else if (i == totalVisualPages + 1) {
            _lastVisibleStableIdentity = null;
            if (reader.isLastChapterOfGroup || !reader.toNextChapter()) {
              controller.jumpToPage(totalVisualPages);
            } else {
              shouldRefresh = true;
            }
          } else {
            final targetSourcePage = controllerIndexToSourcePage(i);
            if (reader.page != targetSourcePage) {
              if (targetSourcePage < reader.maxPage) {
                reader.targetLastVisualPage = false;
              }
              reader.setPage(targetSourcePage);
            } else {
              reader.notifyChapterCompletedIfNeeded();
            }
            context.readerScaffold.update();

            final currentIdentity = _visibleStableIdentityForIndex(i);
            shouldRefresh = shouldRefreshEInk(
              previousIdentity: _lastVisibleStableIdentity,
              currentIdentity: currentIdentity,
              isCommentsPage: isChapterCommentsPage(i),
            );
            if (currentIdentity != null) {
              _lastVisibleStableIdentity = currentIdentity;
            }

            // Auto close toolbar when entering chapter comments page
            if (isChapterCommentsPage(i) && context.readerScaffold.isOpen) {
              context.readerScaffold.openOrClose();
            }
          }
          if (shouldRefresh) {
            context.readerScaffold.requestEInkRefresh();
          }
          final keepKeys = resolveKeepControllerKeys(
            currentIndex: i,
            totalVisualPages: totalVisualPages,
            resolveKeyForIndex: _controllerKeyForIndex,
          );
          _pool.pruneExcept(keepKeys);
        },
      ),
    );
  }

  Widget buildPageImages(List<String> images, int startIndex) {
    Axis axis = (reader.mode == ReaderMode.galleryTopToBottom)
        ? Axis.vertical
        : Axis.horizontal;

    bool reverse = reader.mode == ReaderMode.galleryRightToLeft;
    if (reverse) {
      images = images.reversed.toList();
    }

    List<Widget> imageWidgets;

    if (images.length == 2) {
      imageWidgets = [
        Expanded(
          child: ComicImage(
            width: double.infinity,
            height: double.infinity,
            image: _createImageProviderFromKey(
              images[0],
              context,
              startIndex + 1,
            ),
            fit: BoxFit.contain,
            alignment: axis == Axis.vertical
                ? Alignment.bottomCenter
                : Alignment.centerRight,
            onInit: (state) => imageStates.add(state),
            onDispose: (state) => imageStates.remove(state),
          ),
        ),
        Expanded(
          child: ComicImage(
            width: double.infinity,
            height: double.infinity,
            image: _createImageProviderFromKey(
              images[1],
              context,
              startIndex + 2,
            ),
            fit: BoxFit.contain,
            alignment: axis == Axis.vertical
                ? Alignment.topCenter
                : Alignment.centerLeft,
            onInit: (state) => imageStates.add(state),
            onDispose: (state) => imageStates.remove(state),
          ),
        ),
      ];
    } else {
      imageWidgets = images.map((imageKey) {
        startIndex++;
        ImageProvider imageProvider = _createImageProviderFromKey(
          imageKey,
          context,
          startIndex,
        );
        return Expanded(
          child: ComicImage(
            image: imageProvider,
            fit: BoxFit.contain,
            onInit: (state) => imageStates.add(state),
            onDispose: (state) => imageStates.remove(state),
          ),
        );
      }).toList();
    }

    return axis == Axis.vertical
        ? Column(children: imageWidgets)
        : Row(children: imageWidgets);
  }

  @override
  bool toNextPage() {
    return _moveVisualPage(1);
  }

  @override
  bool toPrevPage() {
    reader.targetLastVisualPage = false;
    return _moveVisualPage(-1);
  }

  @override
  bool isAtLastVisualPartOfSource() {
    if (!isSplitEnabled || _pagePlan == null) return true;
    if (!isCurrentSourceSizeResolved()) return false;
    final current = controller.hasClients && controller.page != null
        ? controller.page!.round()
        : _currentControllerIndex;
    if (isChapterCommentsPage(current)) {
      return isCommentsAtLastVisualPartOfSource(
        isSplitEnabled: isSplitEnabled,
        sourcePageCount: reader.images?.length ?? 0,
        resolvedSourceIndices: _resolvedSourceIndices,
      );
    }
    final visualIndex = current - 1;
    final displayPage = _pagePlan!.maybeDisplayPageAt(visualIndex);
    if (displayPage == null) return false;
    return _pagePlan!.isLastVisualPageOfSource(visualIndex);
  }

  bool _moveVisualPage(int delta) {
    if (!controller.hasClients) return false;
    final current = controller.page?.round() ?? _currentControllerIndex;
    final decision = decideVisualMove(
      isAnimating: reader.isPageAnimating || _isAnimatingVisualPage,
      currentIndex: current,
      delta: delta,
      totalVisualPages: totalVisualPages,
    );
    if (!decision.consumed) {
      return false;
    }
    if (!decision.canMove || decision.targetIndex == null) {
      return true;
    }
    final target = decision.targetIndex!;
    if (reader.enablePageAnimation(reader.cid, reader.type)) {
      animateToControllerPage(target);
    } else {
      controller.jumpToPage(target);
    }
    return true;
  }

  Future<void> animateToControllerPage(int target) async {
    if (_isAnimatingVisualPage) return;
    _isAnimatingVisualPage = true;
    reader.startPageAnimation();
    try {
      final current = controller.hasClients && controller.page != null
          ? controller.page!.round()
          : _currentControllerIndex;
      if ((target - current).abs() > 1) {
        controller.jumpToPage(target > current ? target - 1 : target + 1);
      }
      await controller.animateToPage(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.ease,
      );
    } finally {
      if (_isAnimatingVisualPage) {
        _isAnimatingVisualPage = false;
        reader.endPageAnimation();
      }
    }
  }

  @override
  Future<void> animateToPage(int page) {
    if (page < reader.maxPage) {
      reader.targetLastVisualPage = false;
    }
    final target = _sourcePageToControllerIndex(page);
    return animateToControllerPage(target);
  }

  @override
  void toPage(int page) {
    if (page < reader.maxPage) {
      reader.targetLastVisualPage = false;
    }
    final target = _sourcePageToControllerIndex(page);
    controller.jumpToPage(target);
  }

  @override
  void toVisualEnd() {
    final result = resolveVisualEndTarget(
      isSplitEnabled: isSplitEnabled,
      plan: _pagePlan,
      sourcePageCount: reader.images?.length ?? 0,
      isLastSourceResolved: isSourceSizeResolved(
        (reader.images?.length ?? 0) - 1,
      ),
      sourcePageToControllerIndex: _sourcePageToControllerIndex,
    );
    reader.targetLastVisualPage = result.retainTargetLastVisualPage;
    if (controller.hasClients) {
      controller.jumpToPage(result.targetIndex);
    } else {
      _currentControllerIndex = result.targetIndex;
    }
    reader.setPage(reader.maxPage);
  }

  @override
  bool toChapter(int chapter, {bool toLastPage = false}) {
    return false;
  }

  @override
  void handleDoubleTap(Offset location) {
    if (appdata.settings['quickCollectImage'] == 'DoubleTap') {
      context.readerScaffold.addImageFavorite();
      return;
    }
    final currentIndex = controller.hasClients && controller.page != null
        ? controller.page!.round()
        : _currentControllerIndex;
    final key = _controllerKeyForIndex(currentIndex);
    var controllerForPage = _pool[key];
    controllerForPage?.onDoubleClick?.call();
  }

  @override
  void handleLongPressDown(Offset location) {
    if (!appdata.settings['enableLongPressToZoom'] || fingers != 1) {
      return;
    }
    final currentIndex = controller.hasClients && controller.page != null
        ? controller.page!.round()
        : _currentControllerIndex;
    final key = _controllerKeyForIndex(currentIndex);
    var photoViewController = _pool[key];
    if (photoViewController == null) return;
    double target = (photoViewController.getInitialScale?.call() ?? 1.0) * 1.75;
    var size = reader.size;
    Offset zoomPosition;
    if (appdata.settings['longPressZoomPosition'] != 'center') {
      zoomPosition = Offset(
        size.width / 2 - location.dx,
        size.height / 2 - location.dy,
      );
    } else {
      zoomPosition = Offset(0, 0);
    }
    photoViewController.animateScale?.call(target, zoomPosition);
    isLongPressing = true;
  }

  @override
  void handleLongPressUp(Offset location) {
    if (!appdata.settings['enableLongPressToZoom'] || !isLongPressing) {
      return;
    }
    final currentIndex = controller.hasClients && controller.page != null
        ? controller.page!.round()
        : _currentControllerIndex;
    final key = _controllerKeyForIndex(currentIndex);
    var photoViewController = _pool[key];
    double target = photoViewController?.getInitialScale?.call() ?? 1.0;
    photoViewController?.animateScale?.call(target);
    isLongPressing = false;
  }

  Timer? keyRepeatTimer;

  @override
  void handleKeyEvent(KeyEvent event) {
    bool? forward;
    if (reader.mode == ReaderMode.galleryLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = true;
    } else if (reader.mode == ReaderMode.galleryRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = true;
    } else if (reader.mode == ReaderMode.galleryTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      forward = true;
    } else if (reader.mode == ReaderMode.galleryTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      forward = false;
    } else if (reader.mode == ReaderMode.galleryLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = false;
    } else if (reader.mode == ReaderMode.galleryRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = false;
    }
    if (event is KeyDownEvent) {
      if (keyRepeatTimer != null) {
        keyRepeatTimer!.cancel();
        keyRepeatTimer = null;
      }
      if (forward == true) {
        reader.toNextPage();
      } else if (forward == false) {
        reader.toPrevPage();
      }
    }
    if (event is KeyRepeatEvent && keyRepeatTimer == null) {
      keyRepeatTimer = Timer.periodic(
        reader.enablePageAnimation(reader.cid, reader.type)
            ? const Duration(milliseconds: 200)
            : const Duration(milliseconds: 50),
        (timer) {
          if (!mounted) {
            timer.cancel();
            return;
          } else if (forward == true) {
            reader.toNextPage();
          } else if (forward == false) {
            reader.toPrevPage();
          }
        },
      );
    }
    if (event is KeyUpEvent && keyRepeatTimer != null) {
      keyRepeatTimer!.cancel();
      keyRepeatTimer = null;
    }
  }

  @override
  bool handleOnTap(Offset location) {
    return false;
  }

  @override
  Future<Uint8List?> getImageByOffset(Offset offset) async {
    var imageKey = getImageKeyByOffset(offset);
    if (imageKey == null) return null;
    if (imageKey.startsWith("file://")) {
      return await File(imageKey.substring(7)).readAsBytes();
    } else {
      return (await CacheManager().findCache(
        "$imageKey@${context.reader.type.sourceKey}@${context.reader.cid}@${context.reader.eid}",
      ))!.readAsBytes();
    }
  }

  @override
  String? getImageKeyByOffset(Offset offset) {
    var range = getCurrentPageImageRange();
    if (range == null) return null;

    var (startIndex, endIndex) = range;
    int actualImageCount = endIndex - startIndex;

    if (actualImageCount == 1) {
      return reader.images![startIndex];
    }

    for (var imageState in imageStates) {
      if ((imageState as ComicImageState).containsPoint(offset)) {
        var imageKey =
            (imageState.widget.image as ReaderImageProvider).imageKey;
        int index = reader.images!.indexOf(imageKey);
        if (index >= startIndex && index < endIndex) {
          return imageKey;
        }
      }
    }

    return reader.images![startIndex];
  }
}

const Set<PointerDeviceKind> _kTouchLikeDeviceTypes = <PointerDeviceKind>{
  PointerDeviceKind.touch,
  PointerDeviceKind.mouse,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
  PointerDeviceKind.unknown,
};

const double _kChangeChapterOffset = 160;

class _ContinuousMode extends StatefulWidget {
  const _ContinuousMode({super.key, this.crossChapter = false});

  final bool crossChapter;

  @override
  State<_ContinuousMode> createState() => ContinuousModeState();
}

class ContinuousModeState extends State<_ContinuousMode>
    implements ReaderImageViewController {
  late ReaderState reader;

  var itemScrollController = ItemScrollController();
  var itemPositionsListener = ItemPositionsListener.create();
  var photoViewController = PhotoViewController();
  ScrollController? _scrollController;

  ScrollController get scrollController => _scrollController!;

  var isCTRLPressed = false;
  static var _isMouseScrolling = false;
  var fingers = 0;
  bool disableScroll = false;

  late List<bool> cached;

  final _waterfallFlow = WaterfallChapterFlow();

  bool _isLoadingNextSegment = false;

  bool _isLoadingPrevSegment = false;

  bool _isRestoringPrependedSegmentPosition = false;

  bool _isNavigatingWaterfallLocation = false;

  String? _nextSegmentError;

  int get preCacheCount => appdata.settings["preloadImageCount"];

  /// Whether the user was scrolling the page.
  /// The gesture detector has a delay to detect tap event.
  /// To handle the tap event, we need to know if the user was scrolling before the delay.
  bool delayedIsScrolling = false;

  var imageStates = <State<ComicImage>>{};

  void delayedSetIsScrolling(bool value) {
    Future.delayed(
      const Duration(milliseconds: 300),
      () => delayedIsScrolling = value,
    );
  }

  bool prepareToPrevChapter = false;
  bool prepareToNextChapter = false;
  bool jumpToNextChapter = false;
  bool jumpToPrevChapter = false;

  bool isZoomedIn = false;
  bool isLongPressing = false;

  bool get crossChapter => widget.crossChapter;

  bool get _splitWideImages =>
      reader.mode.isTopToBottom &&
      appdata.settings.getReaderSetting(
            reader.cid,
            reader.type.sourceKey,
            'splitDualPage',
          ) ==
          true;

  bool get _splitWideImagesInvert =>
      appdata.settings.getReaderSetting(
        reader.cid,
        reader.type.sourceKey,
        'splitDualPageInvert',
      ) ==
      true;

  int get _flowImageCount =>
      crossChapter ? _waterfallFlow.imageCount : reader.maxPage;

  int get _flowItemCount => _flowImageCount + 2;

  void _initSegments() {
    if (!crossChapter || !_waterfallFlow.isEmpty || reader.images == null) {
      return;
    }
    _waterfallFlow.addAfter(
      WaterfallChapterSegment(
        chapter: reader.chapter,
        eid: reader.eid,
        images: reader.images!,
      ),
    );
  }

  WaterfallChapterSegment? _segmentOfChapter(int chapter) {
    return _waterfallFlow.segmentOfChapter(chapter);
  }

  WaterfallImageRef? _imageRefAt(int index) {
    if (!crossChapter) {
      if (index <= 0 || index > reader.images!.length) return null;
      return WaterfallImageRef(
        chapter: reader.chapter,
        page: index,
        eid: reader.eid,
        imageKey: reader.images![index - 1],
        isFirstInSegment: index == 1,
      );
    }
    return _waterfallFlow.imageRefAt(index);
  }

  Future<List<String>> _loadChapterImages(int chapter) async {
    if (reader.type == ComicType.local ||
        LocalManager().isDownloaded(
          reader.cid,
          reader.type,
          chapter,
          reader.widget.chapters,
        )) {
      return LocalManager().getImages(reader.cid, reader.type, chapter);
    }
    var chapterId = reader.widget.chapters?.ids.elementAtOrNull(chapter - 1);
    var res = await reader.type.comicSource!.loadComicPages!(
      reader.widget.cid,
      chapterId,
    );
    if (res.error) throw res.errorMessage ?? 'Failed to load chapter';
    return res.data;
  }

  Future<void> _ensureWaterfallImagesAfter(int current) async {
    if (!crossChapter || _isLoadingNextSegment) return;
    var threshold = math.max(preCacheCount, 1);
    if (_flowImageCount - current >= threshold) return;
    var nextChapter =
        (_waterfallFlow.isEmpty
            ? reader.chapter
            : _waterfallFlow.lastChapter!) +
        1;
    if (nextChapter > reader.maxChapter) return;
    setState(() => _isLoadingNextSegment = true);
    var loaded = false;
    try {
      var images = await _loadChapterImages(nextChapter);
      if (!mounted) return;
      setState(() {
        _waterfallFlow.addAfter(
          WaterfallChapterSegment(
            chapter: nextChapter,
            eid:
                reader.widget.chapters?.ids.elementAtOrNull(nextChapter - 1) ??
                '0',
            images: images,
          ),
        );
        _nextSegmentError = null;
      });
      loaded = true;
    } catch (e) {
      if (!mounted) return;
      setState(() => _nextSegmentError = e.toString());
    } finally {
      _isLoadingNextSegment = false;
      if (mounted) setState(() {});
      if (loaded && mounted && _flowImageCount - current < threshold) {
        _ensureWaterfallImagesAfter(current);
      }
    }
  }

  Future<void> _ensureWaterfallImagesBefore(int current) async {
    if (!crossChapter || _isLoadingPrevSegment) return;
    var threshold = math.max(preCacheCount, 1);
    if (current > threshold) return;
    var prevChapter =
        (_waterfallFlow.isEmpty
            ? reader.chapter
            : _waterfallFlow.firstChapter!) -
        1;
    if (prevChapter < 1) return;
    _isLoadingPrevSegment = true;
    var insertedCount = 0;
    try {
      var images = await _loadChapterImages(prevChapter);
      if (!mounted) return;
      _isRestoringPrependedSegmentPosition = true;
      setState(() {
        insertedCount = _waterfallFlow.addBefore(
          WaterfallChapterSegment(
            chapter: prevChapter,
            eid:
                reader.widget.chapters?.ids.elementAtOrNull(prevChapter - 1) ??
                '0',
            images: images,
          ),
        );
      });
      if (insertedCount == 0) {
        _isRestoringPrependedSegmentPosition = false;
      }
    } catch (e) {
      _isRestoringPrependedSegmentPosition = false;
      if (!mounted) return;
      Log.error("Reader", "Failed to load previous chapter", e);
    } finally {
      _isLoadingPrevSegment = false;
      if (mounted) {
        setState(() {});
      }
      if (mounted && insertedCount > 0) {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            itemScrollController.jumpTo(index: current + insertedCount);
            SchedulerBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                _isRestoringPrependedSegmentPosition = false;
              }
            });
          }
        });
      }
    }
  }

  void _setReaderLocation(WaterfallImageRef imageRef) {
    var segment = _segmentOfChapter(imageRef.chapter);
    var chapterChanged = reader.chapter != imageRef.chapter;
    if (segment != null && chapterChanged) {
      reader.flushRemoteProgress();
      reader.chapter = imageRef.chapter;
      reader.images = segment.images;
    }
    if (chapterChanged || reader.page != imageRef.page) {
      reader.setPage(imageRef.page);
    }
  }

  int? _waterfallIndexOfChapterPage(int chapter, int page) {
    if (!crossChapter) return page;
    return _waterfallFlow.imageIndexOf(chapter: chapter, page: page);
  }

  Future<bool> _loadWaterfallNavigationChapter(int chapter) async {
    if (_segmentOfChapter(chapter) != null) return true;
    try {
      var images = await _loadChapterImages(chapter);
      if (!mounted) return false;
      setState(() {
        _waterfallFlow.reset(
          WaterfallChapterSegment(
            chapter: chapter,
            eid:
                reader.widget.chapters?.ids.elementAtOrNull(chapter - 1) ?? '0',
            images: images,
          ),
        );
        _nextSegmentError = null;
      });
      return true;
    } catch (e) {
      if (!mounted) return false;
      Log.error("Reader", "Failed to load chapter $chapter", e);
      context.showMessage(message: e.toString());
      return false;
    }
  }

  Future<void> _navigateToWaterfallChapter(
    int chapter, {
    required bool toLastPage,
  }) async {
    final needsLoading = _segmentOfChapter(chapter) == null;
    if (needsLoading) {
      reader.onReaderContentLoading(keepImageViewController: true);
    }
    try {
      if (!await _loadWaterfallNavigationChapter(chapter) || !mounted) {
        return;
      }
    } finally {
      if (needsLoading && mounted) reader.onReaderContentReady();
      if (mounted) {
        reader.imageViewController ??= this;
      }
    }
    if (!mounted) return;
    reader.imageViewController = this;
    var segment = _segmentOfChapter(chapter);
    if (segment == null || segment.images.isEmpty) return;
    var page = toLastPage ? segment.images.length : 1;
    var index = _waterfallIndexOfChapterPage(chapter, page);
    if (index == null) return;
    var imageRef = _imageRefAt(index);
    if (imageRef == null) return;
    _isNavigatingWaterfallLocation = true;
    setState(() {
      _setReaderLocation(imageRef);
      reader.jumpToLastPageOnLoad = false;
    });
    context.readerScaffold.update();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      itemScrollController.jumpTo(index: index);
      _futurePosition = null;
      cacheImages(index);
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _isNavigatingWaterfallLocation = false;
        }
      });
    });
  }

  @override
  void initState() {
    reader = context.reader;
    reader.targetLastVisualPage = false;
    reader.imageViewController = this;
    _initSegments();
    itemPositionsListener.itemPositions.addListener(onPositionChanged);
    cached = List.filled(reader.maxPage + 2, false);
    Future.delayed(
      const Duration(milliseconds: 100),
      () => cacheImages(reader.page),
    );
    super.initState();
  }

  @override
  void dispose() {
    if (reader.imageViewController == this) {
      reader.imageViewController = null;
    }
    itemPositionsListener.itemPositions.removeListener(onPositionChanged);
    super.dispose();
  }

  void onPositionChanged() {
    if (itemPositionsListener.itemPositions.value.isEmpty) {
      return;
    }
    var page = resolveFlowCurrentImageIndex(
      visibleIndex: itemPositionsListener.itemPositions.value.first.index,
      imageCount: _flowImageCount,
      isTopToBottom: reader.mode.isTopToBottom,
      isAtScrollEnd: _isAtScrollEnd,
    );
    var imageRef = _imageRefAt(page);
    if (imageRef == null) return;
    if (crossChapter) {
      if (_isRestoringPrependedSegmentPosition ||
          _isNavigatingWaterfallLocation) {
        return;
      }
      _setReaderLocation(imageRef);
      context.readerScaffold.update();
    } else if (page != reader.page) {
      reader.setPage(page);
      context.readerScaffold.update();
    }
    cacheImages(page);
    if (crossChapter) {
      _ensureWaterfallImagesBefore(page);
      _ensureWaterfallImagesAfter(page);
    }
  }

  bool get _isAtScrollEnd {
    final controller = _scrollController;
    if (controller == null || !controller.hasClients) {
      return false;
    }
    final position = controller.position;
    return position.pixels >= position.maxScrollExtent - 1;
  }

  double? _futurePosition;

  void smoothTo(double offset) {
    if (HardwareKeyboard.instance.isShiftPressed) {
      return;
    }
    var currentLocation = scrollController.position.pixels;
    var old = _futurePosition;
    _futurePosition ??= currentLocation;
    double k = (_futurePosition! - currentLocation).abs() / 1600 + 1;
    final customSpeed = appdata.settings.getReaderSetting(
      context.reader.cid,
      context.reader.type.sourceKey,
      "readerScrollSpeed",
    );
    if (customSpeed is num) {
      k *= customSpeed;
    }
    _futurePosition = _futurePosition! + offset * k;
    var beforeOffset = (_futurePosition! - currentLocation).abs();
    _futurePosition = _futurePosition!.clamp(
      scrollController.position.minScrollExtent,
      scrollController.position.maxScrollExtent,
    );
    var afterOffset = (_futurePosition! - currentLocation).abs();
    if (_futurePosition == old) return;
    var target = _futurePosition!;
    var duration = const Duration(milliseconds: 160);
    if (afterOffset < beforeOffset) {
      duration = duration * (afterOffset / beforeOffset);
      if (duration < Duration(milliseconds: 10)) {
        duration = Duration(milliseconds: 10);
      }
    }
    scrollController
        .animateTo(_futurePosition!, duration: duration, curve: Curves.linear)
        .then((_) {
          var current = scrollController.position.pixels;
          if (current == target && current == _futurePosition) {
            _futurePosition = null;
          }
        });
  }

  void onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      if (!_isMouseScrolling) {
        setState(() {
          _isMouseScrolling = true;
        });
      }
      if (isCTRLPressed) {
        return;
      }
      smoothTo(event.scrollDelta.dy);
    }
  }

  void cacheImages(int current) {
    for (int i = current + 1; i <= current + preCacheCount; i++) {
      if (crossChapter) {
        var imageRef = _imageRefAt(i);
        if (imageRef == null) continue;
        var segment = _segmentOfChapter(imageRef.chapter);
        if (segment != null && !segment.cached.contains(imageRef.page)) {
          _preDownloadImageRef(imageRef, context);
          segment.cached.add(imageRef.page);
        }
      } else if (i <= reader.maxPage && !cached[i]) {
        _preDownloadImage(i, context);
        cached[i] = true;
      }
    }
  }

  Widget _buildFlowEnd(BuildContext context) {
    if (!crossChapter) return const SizedBox();
    if (_isLoadingNextSegment) {
      return SizedBox(
        height: 96,
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Text('Loading next chapter'.tl),
            ],
          ),
        ),
      );
    }
    if (_nextSegmentError != null) {
      return ClickInkWell(
        onTap: () {
          setState(() => _nextSegmentError = null);
          _ensureWaterfallImagesAfter(_flowImageCount);
        },
        child: SizedBox(
          height: 120,
          child: Center(
            child: Text(
              '${'Failed to load next chapter'.tl}\n${'Tap to retry'.tl}',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    var lastChapter = !_waterfallFlow.isEmpty
        ? _waterfallFlow.lastChapter!
        : reader.chapter;
    if (lastChapter >= reader.maxChapter) {
      return SizedBox(
        height: 96,
        child: Center(child: Text('No more chapters'.tl)),
      );
    }
    return const SizedBox(height: 48);
  }

  String _chapterTitle(int chapter) {
    return reader.widget.chapters?.titles.elementAtOrNull(chapter - 1) ??
        '${'Chapter'.tl} $chapter';
  }

  Widget _buildChapterDivider(
    BuildContext context,
    WaterfallImageRef imageRef,
  ) {
    if (!crossChapter || !imageRef.isFirstInSegment) {
      return const SizedBox();
    }
    var isInitialChapter = imageRef.chapter == _waterfallFlow.firstChapter;
    if (isInitialChapter) return const SizedBox();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: context.colorScheme.surfaceContainerHighest.toOpacity(0.72),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: context.colorScheme.outlineVariant.toOpacity(0.7),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: Text(
              'Continue to @chapter'.tlParams({
                'chapter': _chapterTitle(imageRef.chapter),
              }),
              style: TextStyle(
                color: context.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void onScroll() {
    if (prepareToPrevChapter) {
      jumpToNextChapter = false;
      jumpToPrevChapter =
          scrollController.offset <
          scrollController.position.minScrollExtent - _kChangeChapterOffset;
    } else if (prepareToNextChapter) {
      jumpToNextChapter =
          scrollController.offset >
          scrollController.position.maxScrollExtent + _kChangeChapterOffset;
      jumpToPrevChapter = false;
    }
  }

  bool onScaleUpdate([double? scale]) {
    if (prepareToNextChapter || prepareToPrevChapter) {
      setState(() {
        prepareToPrevChapter = false;
        prepareToNextChapter = false;
      });
      context.readerScaffold.setFloatingButton(0);
    }
    var isZoomedIn = (scale ?? photoViewController.scale) != 1.0;
    if (isZoomedIn != this.isZoomedIn) {
      setState(() {
        this.isZoomedIn = isZoomedIn;
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    Widget widget = ScrollablePositionedList.builder(
      initialScrollIndex: reader.page,
      itemScrollController: itemScrollController,
      itemPositionsListener: itemPositionsListener,
      scrollControllerCallback: (scrollController) {
        if (_scrollController != null) {
          _scrollController!.removeListener(onScroll);
        }
        _scrollController = scrollController;
        _scrollController!.addListener(onScroll);
      },
      itemCount: _flowItemCount,
      addSemanticIndexes: false,
      scrollDirection: reader.mode.isTopToBottom
          ? Axis.vertical
          : Axis.horizontal,
      reverse: reader.mode == ReaderMode.continuousRightToLeft,
      physics: isCTRLPressed || _isMouseScrolling || disableScroll
          ? const NeverScrollableScrollPhysics()
          : isZoomedIn
          ? const ClampingScrollPhysics()
          : const BouncingScrollPhysics(),
      itemBuilder: (context, index) {
        if (index == 0) {
          return const SizedBox();
        }
        if (index == _flowImageCount + 1) {
          return _buildFlowEnd(context);
        }
        var imageRef = _imageRefAt(index);
        if (imageRef == null) {
          return const SizedBox();
        }
        double? width, height;
        if (reader.mode == ReaderMode.continuousLeftToRight ||
            reader.mode == ReaderMode.continuousRightToLeft) {
          height = double.infinity;
        } else {
          width = double.infinity;
        }

        ImageProvider image = _createImageProviderFromRef(imageRef, context);

        var comicImage = ComicImage(
          filterQuality: FilterQuality.medium,
          image: image,
          width: width,
          height: height,
          fit: BoxFit.contain,
          splitWideImage: _splitWideImages,
          splitWideImageInvert: _splitWideImagesInvert,
          onInit: (state) => imageStates.add(state),
          onDispose: (state) => imageStates.remove(state),
        );

        return ColoredBox(
          color: context.colorScheme.surface,
          child: reader.mode.isTopToBottom
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildChapterDivider(context, imageRef),
                    comicImage,
                  ],
                )
              : comicImage,
        );
      },
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        scrollbars: false,
        dragDevices: _kTouchLikeDeviceTypes,
      ),
    );

    widget = Stack(
      children: [
        Positioned.fill(child: buildBackground(context)),
        Positioned.fill(child: widget),
      ],
    );

    widget = Listener(
      onPointerDown: (event) {
        fingers++;
        if (fingers > 1 && !disableScroll) {
          setState(() {
            disableScroll = true;
          });
        }
        _futurePosition = null;
        if (_isMouseScrolling) {
          setState(() {
            _isMouseScrolling = false;
          });
        }
      },
      onPointerUp: (event) {
        fingers--;
        if (fingers <= 1 && disableScroll) {
          setState(() {
            disableScroll = false;
          });
        }
        if (fingers == 0) {
          if (jumpToPrevChapter) {
            context.readerScaffold.setFloatingButton(0);
            reader.toPrevChapter(toLastPage: true);
          } else if (jumpToNextChapter) {
            context.readerScaffold.setFloatingButton(0);
            reader.toNextChapter();
          }
        }
      },
      onPointerCancel: (event) {
        fingers--;
        if (fingers <= 1 && disableScroll) {
          setState(() {
            disableScroll = false;
          });
        }
      },
      onPointerPanZoomUpdate: (event) {
        if (event.scale == 1.0) {
          smoothTo(0 - event.panDelta.dy);
        }
      },
      onPointerMove: (event) {
        Offset value = event.delta;
        if (photoViewController.scale == 1 || fingers != 1) {
          return;
        }
        Offset offset;
        var sp = scrollController.position;
        if (sp.pixels <= sp.minScrollExtent ||
            sp.pixels >= sp.maxScrollExtent) {
          offset = Offset(value.dx, value.dy);
        } else {
          if (reader.mode.isTopToBottom) {
            offset = Offset(value.dx, 0);
          } else {
            offset = Offset(0, value.dy);
          }
        }
        if (isLongPressing) {
          offset += value;
        }
        photoViewController.updateMultiple(
          position: photoViewController.position + offset,
        );
      },
      onPointerSignal: onPointerSignal,
      child: widget,
    );

    widget = NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification) {
          delayedSetIsScrolling(true);
        } else if (notification is ScrollEndNotification) {
          delayedSetIsScrolling(false);
        }

        var scale = photoViewController.scale ?? 1.0;

        if (notification is ScrollUpdateNotification &&
            (scale - 1).abs() < 0.05) {
          if (!scrollController.hasClients) return false;
          if (scrollController.position.pixels <=
                  scrollController.position.minScrollExtent &&
              !reader.isFirstChapterOfGroup &&
              !crossChapter) {
            if (!prepareToPrevChapter) {
              jumpToPrevChapter = false;
              jumpToNextChapter = false;
              context.readerScaffold.setFloatingButton(-1);
              setState(() {
                prepareToPrevChapter = true;
              });
            }
          } else if (scrollController.position.pixels >=
                  scrollController.position.maxScrollExtent &&
              !reader.isLastChapterOfGroup &&
              !crossChapter) {
            if (!prepareToNextChapter) {
              jumpToPrevChapter = false;
              jumpToNextChapter = false;
              context.readerScaffold.setFloatingButton(1);
              setState(() {
                prepareToNextChapter = true;
              });
            }
          } else {
            context.readerScaffold.setFloatingButton(0);
            if (prepareToPrevChapter || prepareToNextChapter) {
              jumpToPrevChapter = false;
              jumpToNextChapter = false;
              setState(() {
                prepareToPrevChapter = false;
                prepareToNextChapter = false;
              });
            }
          }
        }

        return true;
      },
      child: widget,
    );
    var width = reader.size.width;
    var height = reader.size.height;
    if (appdata.settings['limitImageWidth'] &&
        width / height > 0.7 &&
        reader.mode.isTopToBottom) {
      width = height * 0.7;
    }

    return PhotoView.customChild(
      backgroundDecoration: BoxDecoration(color: context.colorScheme.surface),
      childSize: Size(width, height),
      minScale: 1.0,
      maxScale: 2.5,
      strictScale: true,
      controller: photoViewController,
      onScaleUpdate: onScaleUpdate,
      child: SizedBox(width: width, height: height, child: widget),
    );
  }

  Widget buildBackground(BuildContext context) {
    return Column(
      children: [
        SizedBox(height: context.padding.top + 16),
        if (prepareToPrevChapter)
          _SwipeChangeChapterProgress(
            controller: scrollController,
            isPrev: true,
          ),
        const Spacer(),
        if (prepareToNextChapter)
          _SwipeChangeChapterProgress(
            controller: scrollController,
            isPrev: false,
          ),
        SizedBox(height: 36),
      ],
    );
  }

  @override
  Future<void> animateToPage(int page) {
    var index = _waterfallIndexOfChapterPage(reader.chapter, page) ?? page;
    return itemScrollController.scrollTo(
      index: index,
      duration: const Duration(milliseconds: 200),
      curve: Curves.ease,
    );
  }

  @override
  void handleDoubleTap(Offset location) {
    if (appdata.settings['quickCollectImage'] == 'DoubleTap') {
      context.readerScaffold.addImageFavorite();
      return;
    }
    double target;
    if (photoViewController.scale !=
        photoViewController.getInitialScale?.call()) {
      target = photoViewController.getInitialScale!.call()!;
    } else {
      target = photoViewController.getInitialScale!.call()! * 1.75;
    }
    var size = MediaQuery.of(context).size;
    photoViewController.animateScale?.call(
      target,
      Offset(size.width / 2 - location.dx, size.height / 2 - location.dy),
    );
    onScaleUpdate(target);
  }

  @override
  void handleLongPressDown(Offset location) {
    if (!appdata.settings['enableLongPressToZoom'] || delayedIsScrolling) {
      return;
    }
    double target = photoViewController.getInitialScale!.call()! * 1.75;
    var size = reader.size;
    Offset zoomPosition;
    if (appdata.settings['longPressZoomPosition'] != 'center') {
      zoomPosition = Offset(
        size.width / 2 - location.dx,
        size.height / 2 - location.dy,
      );
    } else {
      zoomPosition = Offset(0, 0);
    }
    photoViewController.animateScale?.call(target, zoomPosition);
    onScaleUpdate(target);
    isLongPressing = true;
  }

  @override
  void handleLongPressUp(Offset location) {
    if (!appdata.settings['enableLongPressToZoom']) {
      return;
    }
    double target = photoViewController.getInitialScale!.call()!;
    photoViewController.animateScale?.call(target);
    onScaleUpdate(target);
    isLongPressing = false;
  }

  @override
  void toPage(int page) {
    var index = _waterfallIndexOfChapterPage(reader.chapter, page) ?? page;
    itemScrollController.jumpTo(index: index);
    _futurePosition = null;
  }

  @override
  void toVisualEnd() => toPage(reader.maxPage);

  @override
  bool toChapter(int chapter, {bool toLastPage = false}) {
    if (!crossChapter) return false;
    _navigateToWaterfallChapter(chapter, toLastPage: toLastPage);
    return true;
  }

  @override
  bool toNextPage() => false;

  @override
  bool toPrevPage() => false;

  @override
  bool isAtLastVisualPartOfSource() => true;

  @override
  bool isCurrentSourceSizeResolved() => true;

  @override
  bool isReadyForChapter(int chapter) => mounted;
  @override
  void handleKeyEvent(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.controlLeft ||
        event.logicalKey == LogicalKeyboardKey.controlRight) {
      setState(() {
        if (event is KeyDownEvent) {
          isCTRLPressed = true;
        } else if (event is KeyUpEvent) {
          isCTRLPressed = false;
        }
      });
    }
    if (event is KeyUpEvent) {
      return;
    }
    bool? forward;
    if (reader.mode == ReaderMode.continuousLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = true;
    } else if (reader.mode == ReaderMode.continuousRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = true;
    } else if (reader.mode.isTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      forward = true;
    } else if (reader.mode.isTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      forward = false;
    } else if (reader.mode == ReaderMode.continuousLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = false;
    } else if (reader.mode == ReaderMode.continuousRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = false;
    }
    if (forward == true) {
      scrollController.animateTo(
        scrollController.offset + context.height * 0.25,
        duration: const Duration(milliseconds: 200),
        curve: Curves.ease,
      );
    } else if (forward == false) {
      scrollController.animateTo(
        scrollController.offset - context.height * 0.25,
        duration: const Duration(milliseconds: 200),
        curve: Curves.ease,
      );
    }
  }

  @override
  bool handleOnTap(Offset location) {
    if (delayedIsScrolling) {
      return true;
    }
    return false;
  }

  @override
  Future<Uint8List?> getImageByOffset(Offset offset) async {
    var imageKey = getImageKeyByOffset(offset);
    if (imageKey == null) return null;
    if (imageKey.startsWith("file://")) {
      return await File(imageKey.substring(7)).readAsBytes();
    } else {
      return (await CacheManager().findCache(
        "$imageKey@${context.reader.type.sourceKey}@${context.reader.cid}@${context.reader.eid}",
      ))!.readAsBytes();
    }
  }

  @override
  String? getImageKeyByOffset(Offset offset) {
    String? imageKey;
    for (var imageState in imageStates) {
      if ((imageState as ComicImageState).containsPoint(offset)) {
        imageKey = (imageState.widget.image as ReaderImageProvider).imageKey;
      }
    }
    return imageKey;
  }
}

ImageProvider _createImageProviderFromKey(
  String imageKey,
  BuildContext context,
  int page,
) {
  var reader = context.reader;
  return ReaderImageProvider(
    imageKey,
    reader.type.comicSource?.key,
    reader.cid,
    reader.eid,
    page,
    enableResize: reader
        .mode
        .isContinuous, // For continuous mode, we need to resize the image to improve performance
  );
}

ImageProvider _createImageProviderFromRef(
  WaterfallImageRef imageRef,
  BuildContext context,
) {
  var reader = context.reader;
  return ReaderImageProvider(
    imageRef.imageKey,
    reader.type.comicSource?.key,
    reader.cid,
    imageRef.eid,
    imageRef.page,
    enableResize: reader.mode.isContinuous,
  );
}

ImageProvider _createImageProvider(int page, BuildContext context) {
  var reader = context.reader;
  var imageKey = reader.images![page - 1];
  return _createImageProviderFromKey(imageKey, context, page);
}

/// [_precacheImage] is used to precache the image for the given page.
/// The image is cached using the flutter's [precacheImage] method.
/// The image will be downloaded and decoded into memory.
void _precacheImage(int page, BuildContext context) {
  if (page <= 0 || page > context.reader.images!.length) {
    return;
  }
  precacheImage(_createImageProvider(page, context), context);
}

/// [_preDownloadImage] is used to download the image for the given page.
/// The image is downloaded using the [CacheManager] and saved to the local storage.
void _preDownloadImage(int page, BuildContext context) {
  if (page <= 0 || page > context.reader.images!.length) {
    return;
  }
  var reader = context.reader;
  var imageKey = reader.images![page - 1];
  if (imageKey.startsWith("file://")) {
    return;
  }
  var cid = reader.cid;
  var eid = reader.eid;
  var sourceKey = reader.type.comicSource?.key;
  ImageDownloader.loadComicImage(imageKey, sourceKey, cid, eid);
}

void _preDownloadImageRef(WaterfallImageRef imageRef, BuildContext context) {
  if (imageRef.imageKey.startsWith("file://")) {
    return;
  }
  var reader = context.reader;
  var sourceKey = reader.type.comicSource?.key;
  ImageDownloader.loadComicImage(
    imageRef.imageKey,
    sourceKey,
    reader.cid,
    imageRef.eid,
  );
}

class _SwipeChangeChapterProgress extends StatefulWidget {
  const _SwipeChangeChapterProgress({this.controller, required this.isPrev});

  final ScrollController? controller;

  final bool isPrev;

  @override
  State<_SwipeChangeChapterProgress> createState() =>
      _SwipeChangeChapterProgressState();
}

class _SwipeChangeChapterProgressState
    extends State<_SwipeChangeChapterProgress> {
  double value = 0;

  late final isPrev = widget.isPrev;

  ScrollController? controller;

  @override
  void initState() {
    super.initState();
    if (widget.controller != null) {
      controller = widget.controller;
      controller!.addListener(onScroll);
    }
  }

  @override
  void didUpdateWidget(covariant _SwipeChangeChapterProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      controller?.removeListener(onScroll);
      controller = widget.controller;
      controller?.addListener(onScroll);
      if (value != 0) {
        setState(() {
          value = 0;
        });
      }
    }
  }

  @override
  void dispose() {
    super.dispose();
    controller?.removeListener(onScroll);
  }

  void onScroll() {
    var position = controller!.position.pixels;
    var offset = isPrev
        ? controller!.position.minScrollExtent - position
        : position - controller!.position.maxScrollExtent;
    var newValue = offset / _kChangeChapterOffset;
    newValue = newValue.clamp(0.0, 1.0);
    if (newValue != value) {
      setState(() {
        value = newValue;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final msg = widget.isPrev
        ? "Swipe down for previous chapter".tl
        : "Swipe up for next chapter".tl;

    return CustomPaint(
      painter: _ProgressPainter(
        value: value,
        backgroundColor: context.colorScheme.surfaceContainerLow,
        color: context.colorScheme.surfaceContainerHighest,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            widget.isPrev ? Icons.arrow_downward : Icons.arrow_upward,
            color: context.colorScheme.onSurface,
            size: 16,
          ),
          const SizedBox(width: 4),
          Text(msg),
        ],
      ).paddingVertical(6).paddingHorizontal(16),
    );
  }
}

class _ProgressPainter extends CustomPainter {
  final double value;

  final Color backgroundColor;

  final Color color;

  const _ProgressPainter({
    required this.value,
    required this.backgroundColor,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromLTRBR(0, 0, size.width, size.height, Radius.circular(16)),
      paint,
    );

    paint.color = color;
    canvas.drawRRect(
      RRect.fromLTRBR(
        0,
        0,
        size.width * value,
        size.height,
        Radius.circular(16),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return oldDelegate is! _ProgressPainter ||
        oldDelegate.value != value ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.color != color;
  }
}
