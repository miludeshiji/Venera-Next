import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show immutable, visibleForTesting;
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/consts.dart';
import 'package:venera_next/foundation/image_processing.dart';

import 'app_dio.dart';

typedef ThumbnailLoadingConfigResolver =
    FutureOr<Map<String, dynamic>> Function(String sourceKey, String url);

typedef ThumbnailCoverResolver =
    FutureOr<String?> Function(String sourceKey, String cid);

enum ComicImageTargetFit {
  contain,
  fitWidth,
  fitHeight;

  static ComicImageTargetFit fromString(String? value) {
    return switch (value) {
      'fitWidth' => ComicImageTargetFit.fitWidth,
      'fitHeight' => ComicImageTargetFit.fitHeight,
      _ => ComicImageTargetFit.contain,
    };
  }
}

@immutable
class ComicImageLoadTarget {
  final double? logicalWidth;
  final double? logicalHeight;
  final double devicePixelRatio;
  final ComicImageTargetFit fit;
  final bool splitWideImage;

  ComicImageLoadTarget({
    double? logicalWidth,
    double? logicalHeight,
    double devicePixelRatio = 1.0,
    this.fit = ComicImageTargetFit.contain,
    this.splitWideImage = false,
  }) : logicalWidth =
           (logicalWidth != null && logicalWidth.isFinite && logicalWidth > 0)
           ? logicalWidth
           : null,
       logicalHeight =
           (logicalHeight != null &&
               logicalHeight.isFinite &&
               logicalHeight > 0)
           ? logicalHeight
           : null,
       devicePixelRatio = (devicePixelRatio.isFinite && devicePixelRatio > 0)
           ? devicePixelRatio
           : 1.0;

  const ComicImageLoadTarget.raw({
    this.logicalWidth,
    this.logicalHeight,
    this.devicePixelRatio = 1.0,
    this.fit = ComicImageTargetFit.contain,
    this.splitWideImage = false,
  });

  double get normalizedDevicePixelRatio =>
      (devicePixelRatio.isFinite && devicePixelRatio > 0)
      ? devicePixelRatio
      : 1.0;

  int? get physicalWidth {
    final w = logicalWidth;
    if (w == null || !w.isFinite || w <= 0) {
      return null;
    }
    final pw = (w * normalizedDevicePixelRatio).round();
    return pw > 0 ? pw : null;
  }

  int? get physicalHeight {
    final h = logicalHeight;
    if (h == null || !h.isFinite || h <= 0) {
      return null;
    }
    final ph = (h * normalizedDevicePixelRatio).round();
    return ph > 0 ? ph : null;
  }

  String get cacheIdentity {
    final pw = physicalWidth;
    final ph = physicalHeight;
    final wStr = pw != null ? 'w$pw' : 'wnull';
    final hStr = ph != null ? 'h$ph' : 'hnull';
    return '$wStr-$hStr-dpr$normalizedDevicePixelRatio-${fit.name}-split$splitWideImage';
  }

  Map<String, dynamic> toJson() {
    final w =
        (logicalWidth != null && logicalWidth!.isFinite && logicalWidth! > 0)
        ? logicalWidth
        : null;
    final h =
        (logicalHeight != null && logicalHeight!.isFinite && logicalHeight! > 0)
        ? logicalHeight
        : null;
    return {
      'logicalWidth': w,
      'logicalHeight': h,
      'devicePixelRatio': normalizedDevicePixelRatio,
      'fit': fit.name,
      'splitWideImage': splitWideImage,
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ComicImageLoadTarget &&
        physicalWidth == other.physicalWidth &&
        physicalHeight == other.physicalHeight &&
        normalizedDevicePixelRatio == other.normalizedDevicePixelRatio &&
        fit == other.fit &&
        splitWideImage == other.splitWideImage;
  }

  @override
  int get hashCode {
    return Object.hash(
      physicalWidth,
      physicalHeight,
      normalizedDevicePixelRatio,
      fit,
      splitWideImage,
    );
  }

  @override
  String toString() =>
      'ComicImageLoadTarget(physical: ${physicalWidth}x$physicalHeight, dpr: $normalizedDevicePixelRatio, fit: ${fit.name}, split: $splitWideImage)';
}

typedef ComicImageLoadingConfigResolver =
    FutureOr<Map<String, dynamic>> Function(
      String sourceKey,
      String imageKey,
      String cid,
      String eid, {
      ComicImageLoadTarget? target,
    });

typedef ComicImageDebugLoader =
    Stream<ImageDownloadProgress> Function(
      String imageKey,
      String? sourceKey,
      String cid,
      String eid, {
      ComicImageLoadTarget? target,
    });
typedef ComicImageTransport =
    FutureOr<dynamic> Function(String url, Map<String, dynamic> configs);

abstract class ImageDownloader {
  static ThumbnailLoadingConfigResolver? _thumbnailLoadingConfigResolver;

  static ThumbnailCoverResolver? _thumbnailCoverResolver;

  static ComicImageLoadingConfigResolver? _comicImageLoadingConfigResolver;

  static void configureSourceImageLoading({
    ThumbnailLoadingConfigResolver? thumbnailLoadingConfig,
    ThumbnailCoverResolver? thumbnailCover,
    ComicImageLoadingConfigResolver? comicImageLoadingConfig,
  }) {
    _thumbnailLoadingConfigResolver = thumbnailLoadingConfig;
    _thumbnailCoverResolver = thumbnailCover;
    _comicImageLoadingConfigResolver = comicImageLoadingConfig;
  }

  @visibleForTesting
  static void debugResetSourceImageLoading() {
    configureSourceImageLoading();
    _debugLoadComicImageUnwrapped = null;
    _debugComicImageTransport = null;
  }

  static ComicImageTransport? _debugComicImageTransport;

  @visibleForTesting
  static ComicImageTransport? get debugComicImageTransport =>
      _debugComicImageTransport;

  @visibleForTesting
  static set debugComicImageTransport(ComicImageTransport? transport) {
    _debugComicImageTransport = transport;
  }

  static ComicImageDebugLoader? _debugLoadComicImageUnwrapped;

  @visibleForTesting
  static ComicImageDebugLoader? get debugLoadComicImageUnwrapped =>
      _debugLoadComicImageUnwrapped;

  @visibleForTesting
  static set debugLoadComicImageUnwrapped(ComicImageDebugLoader? loader) {
    _debugLoadComicImageUnwrapped = loader;
  }

  /// Generate a stable cache key for comic images.
  /// Used for active deduplication and disk cache.
  static String getComicImageCacheKey(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    ComicImageLoadTarget? target,
  }) {
    final base = "$imageKey@$sourceKey@$cid@$eid";
    if (target != null) {
      return "$base@${target.cacheIdentity}";
    }
    return base;
  }

  /// Alias for building comic image cache key.
  static String buildComicImageCacheKey(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    ComicImageLoadTarget? target,
  }) => getComicImageCacheKey(imageKey, sourceKey, cid, eid, target: target);

  @visibleForTesting
  static bool debugShouldRetryImageLoad({
    required int retriesRemaining,
    required bool hasOnLoadFailed,
  }) {
    return _shouldRetryImageLoad(
      retriesRemaining: retriesRemaining,
      hasOnLoadFailed: hasOnLoadFailed,
    );
  }

  static bool _shouldRetryImageLoad({
    required int retriesRemaining,
    required bool hasOnLoadFailed,
  }) {
    return retriesRemaining > 0 && hasOnLoadFailed;
  }

  @visibleForTesting
  static Future<List<int>> debugApplyImageResponseCallback(
    JSInvokable onResponse,
    List<int> buffer,
  ) {
    return _applyImageResponseCallback(onResponse, buffer);
  }

  static Future<List<int>> _applyImageResponseCallback(
    JSInvokable onResponse,
    List<int> buffer,
  ) async {
    try {
      dynamic result = onResponse([Uint8List.fromList(buffer)]);
      if (result is Future) {
        result = await result;
      }
      if (result is List<int>) {
        return result;
      }
      throw "Error: Invalid onResponse result.";
    } finally {
      onResponse.free();
    }
  }

  @visibleForTesting
  static Future<Map<String, dynamic>?> debugResolveImageLoadFailure(
    JSInvokable onLoadFailed,
  ) {
    return _resolveImageLoadFailure(onLoadFailed);
  }

  static Future<Map<String, dynamic>?> _resolveImageLoadFailure(
    JSInvokable onLoadFailed,
  ) async {
    try {
      dynamic result = onLoadFailed([]);
      if (result is Future) {
        result = await result;
      }
      return _normalizeImageLoadConfig(result);
    } finally {
      onLoadFailed.free();
    }
  }

  static Map<String, dynamic>? _normalizeImageLoadConfig(dynamic result) {
    if (result is! Map) {
      return null;
    }
    final config = <String, dynamic>{};
    for (final entry in result.entries) {
      final key = entry.key;
      if (key is! String) {
        return null;
      }
      config[key] = entry.value;
    }
    return config;
  }

  @visibleForTesting
  static Map<String, dynamic> debugResolveImageHeaders(
    Map<String, dynamic> configs,
  ) {
    return _resolveImageHeaders(configs['headers']);
  }

  static Map<String, dynamic> _resolveImageHeaders(dynamic rawHeaders) {
    if (rawHeaders == null) {
      return <String, dynamic>{'user-agent': webUA};
    }
    if (rawHeaders is! Map) {
      throw ArgumentError(
        'Invalid image headers: expected Map<String, dynamic>?, got ${rawHeaders.runtimeType}',
      );
    }
    final headers = <String, dynamic>{};
    var hasUserAgent = false;
    for (final entry in rawHeaders.entries) {
      final key = entry.key;
      if (key is! String) {
        throw ArgumentError(
          'Invalid header key: expected String, got $key (${key.runtimeType})',
        );
      }
      if (key.toLowerCase() == 'user-agent') {
        hasUserAgent = true;
      }
      headers[key] = entry.value;
    }
    if (!hasUserAgent) {
      headers['user-agent'] = webUA;
    }
    return headers;
  }

  static Stream<ImageDownloadProgress> loadThumbnail(
    String url,
    String? sourceKey, [
    String? cid,
  ]) async* {
    final cacheKey = "$url@$sourceKey${cid != null ? '@$cid' : ''}";
    final cache = await CacheManager().findCache(cacheKey);

    if (cache != null) {
      var data = await cache.readAsBytes();
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: data.length,
        imageBytes: data,
      );
    }

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      configs =
          await _thumbnailLoadingConfigResolver?.call(sourceKey, url) ?? {};
    }
    final headers = _resolveImageHeaders(configs['headers']);

    if (((configs['url'] as String?) ?? url).startsWith('cover.') &&
        sourceKey != null &&
        cid != null) {
      final coverUrl = await _thumbnailCoverResolver?.call(sourceKey, cid);
      if (coverUrl != null) {
        yield* loadThumbnail(coverUrl, sourceKey);
        return;
      }
    }

    var dio = AppDio(
      BaseOptions(
        headers: headers,
        method: configs['method'] ?? 'GET',
        responseType: ResponseType.stream,
      ),
    );

    String requestUrl = configs['url'] ?? url;
    if (requestUrl.startsWith('//')) {
      requestUrl = 'https:$requestUrl';
    }
    var req = await dio.request<ResponseBody>(
      requestUrl,
      data: configs['data'],
    );
    var stream = req.data?.stream ?? (throw "Error: Empty response body.");
    int? expectedBytes = req.data!.contentLength;
    if (expectedBytes == -1) {
      expectedBytes = null;
    }
    var buffer = <int>[];
    await for (var data in stream) {
      buffer.addAll(data);
      if (expectedBytes != null) {
        yield ImageDownloadProgress(
          currentBytes: buffer.length,
          totalBytes: expectedBytes,
        );
      }
    }

    if (configs['onResponse'] is JSInvokable) {
      buffer = await _applyImageResponseCallback(
        configs['onResponse'] as JSInvokable,
        buffer,
      );
    }

    await CacheManager().writeCache(cacheKey, buffer);
    yield ImageDownloadProgress(
      currentBytes: buffer.length,
      totalBytes: buffer.length,
      imageBytes: Uint8List.fromList(buffer),
    );
  }

  static final _loadingImages =
      <String, _StreamWrapper<ImageDownloadProgress>>{};

  /// Cancel all loading images.
  static void cancelAllLoadingImages() {
    for (var wrapper in _loadingImages.values.toList()) {
      wrapper.cancel();
    }
    _loadingImages.clear();
  }

  /// Preload a comic image from the network or cache.
  ///
  /// Consumes the shared stream from [loadComicImage] so that the active
  /// stream is not cancelled when UI listeners unmount or cancel.
  static Future<void> preloadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    ComicImageLoadTarget? target,
  }) async {
    await for (final _ in loadComicImage(
      imageKey,
      sourceKey,
      cid,
      eid,
      target: target,
    )) {
      // Consume the shared stream until completion.
    }
  }

  /// Load comic image bytes from the network or cache.
  ///
  /// Consumes the shared stream from [loadComicImage] and returns the
  /// final non-null [Uint8List]. Throws a [StateError] if the stream
  /// finishes without delivering image bytes.
  static Future<Uint8List> loadComicImageBytes(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    ComicImageLoadTarget? target,
  }) async {
    Uint8List? result;
    await for (final progress in loadComicImage(
      imageKey,
      sourceKey,
      cid,
      eid,
      target: target,
    )) {
      if (progress.imageBytes != null) {
        result = progress.imageBytes;
      }
    }
    if (result != null) {
      return result;
    }
    throw StateError(
      'Comic image stream finished without delivering image bytes for $imageKey',
    );
  }

  /// Load a comic image from the network or cache.
  /// The function will prevent multiple requests for the same image.
  static Stream<ImageDownloadProgress> loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    ComicImageLoadTarget? target,
  }) {
    final cacheKey = getComicImageCacheKey(
      imageKey,
      sourceKey,
      cid,
      eid,
      target: target,
    );
    final activeStream = _loadingImages[cacheKey];
    if (activeStream != null) {
      if (!activeStream.isClosed) {
        return activeStream.stream;
      }
      _loadingImages.remove(cacheKey);
    }
    final debugLoader = debugLoadComicImageUnwrapped;
    final stream = _StreamWrapper<ImageDownloadProgress>(
      debugLoader?.call(imageKey, sourceKey, cid, eid, target: target) ??
          _loadComicImage(imageKey, sourceKey, cid, eid, target: target),
      (wrapper) {
        if (identical(_loadingImages[cacheKey], wrapper)) {
          _loadingImages.remove(cacheKey);
        }
      },
    );
    _loadingImages[cacheKey] = stream;
    return stream.stream;
  }

  static Stream<ImageDownloadProgress> loadComicImageUnwrapped(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    ComicImageLoadTarget? target,
  }) {
    final debugLoader = debugLoadComicImageUnwrapped;
    if (debugLoader != null) {
      return debugLoader(imageKey, sourceKey, cid, eid, target: target);
    }
    return _loadComicImage(imageKey, sourceKey, cid, eid, target: target);
  }

  static Stream<ImageDownloadProgress> _loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    ComicImageLoadTarget? target,
  }) async* {
    final cacheKey = getComicImageCacheKey(
      imageKey,
      sourceKey,
      cid,
      eid,
      target: target,
    );
    final cache = await CacheManager().findCache(cacheKey);

    if (cache != null) {
      final data = await cache.readAsBytes();
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: data.length,
        imageBytes: data,
      );
      return;
    }

    JSInvokable? onLoadFailed;

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      configs =
          await _comicImageLoadingConfigResolver?.call(
            sourceKey,
            imageKey,
            cid,
            eid,
            target: target,
          ) ??
          {};
    }
    var retriesRemaining = 5;
    while (true) {
      try {
        final headers = _resolveImageHeaders(configs['headers']);
        final effectiveConfigs = <String, dynamic>{
          ...configs,
          'headers': headers,
        };

        final onLoadFailedConfig = effectiveConfigs['onLoadFailed'];
        onLoadFailed = onLoadFailedConfig is JSInvokable
            ? onLoadFailedConfig
            : null;

        Stream<List<int>> stream;
        int? expectedBytes;

        final transport = _debugComicImageTransport;
        if (transport != null) {
          final transportResult = await transport(
            effectiveConfigs['url'] ?? imageKey,
            effectiveConfigs,
          );
          if (transportResult is Stream<List<int>>) {
            stream = transportResult;
            expectedBytes = null;
          } else if (transportResult is List<int>) {
            stream = Stream.value(transportResult);
            expectedBytes = transportResult.length;
          } else if (transportResult is ResponseBody) {
            stream = transportResult.stream;
            expectedBytes = transportResult.contentLength == -1
                ? null
                : transportResult.contentLength;
          } else {
            throw StateError('Unsupported transport result: $transportResult');
          }
        } else {
          var dio = AppDio(
            BaseOptions(
              headers: headers,
              method: effectiveConfigs['method'] ?? 'GET',
              responseType: ResponseType.stream,
            ),
          );

          var req = await dio.request<ResponseBody>(
            effectiveConfigs['url'] ?? imageKey,
            data: effectiveConfigs['data'],
          );
          stream = req.data?.stream ?? (throw "Error: Empty response body.");
          expectedBytes = req.data!.contentLength;
          if (expectedBytes == -1) {
            expectedBytes = null;
          }
        }
        var buffer = <int>[];
        await for (var data in stream) {
          buffer.addAll(data);
          yield ImageDownloadProgress(
            currentBytes: buffer.length,
            totalBytes: expectedBytes,
          );
        }

        if (effectiveConfigs['onResponse'] is JSInvokable) {
          buffer = await _applyImageResponseCallback(
            effectiveConfigs['onResponse'] as JSInvokable,
            buffer,
          );
        }

        Uint8List data;
        if (buffer is Uint8List) {
          data = buffer;
        } else {
          data = Uint8List.fromList(buffer);
          buffer.clear();
        }

        if (effectiveConfigs['modifyImage'] != null) {
          var newData = await modifyImageWithScript(
            data,
            effectiveConfigs['modifyImage'],
          );
          data = newData;
        }

        await CacheManager().writeCache(cacheKey, data);
        yield ImageDownloadProgress(
          currentBytes: data.length,
          totalBytes: data.length,
          imageBytes: data,
        );
        return;
      } catch (e) {
        final onLoadFailedCallback = onLoadFailed;
        if (onLoadFailedCallback == null ||
            !_shouldRetryImageLoad(
              retriesRemaining: retriesRemaining,
              hasOnLoadFailed: true,
            )) {
          rethrow;
        }
        retriesRemaining--;
        onLoadFailed = null;
        var newConfig = await _resolveImageLoadFailure(onLoadFailedCallback);
        if (newConfig == null) {
          rethrow;
        }
        configs = newConfig;
      } finally {
        final onLoadFailedCallback = onLoadFailed;
        if (onLoadFailedCallback != null) {
          onLoadFailed = null;
          onLoadFailedCallback.free();
        }
      }
    }
  }
}

/// Global helper to build comic image cache key.
String buildComicImageCacheKey(
  String imageKey,
  String? sourceKey,
  String cid,
  String eid, {
  ComicImageLoadTarget? target,
}) => ImageDownloader.getComicImageCacheKey(
  imageKey,
  sourceKey,
  cid,
  eid,
  target: target,
);

/// Global helper to load comic image bytes from the shared stream.
Future<Uint8List> loadComicImageBytes(
  String imageKey,
  String? sourceKey,
  String cid,
  String eid, {
  ComicImageLoadTarget? target,
}) => ImageDownloader.loadComicImageBytes(
  imageKey,
  sourceKey,
  cid,
  eid,
  target: target,
);

/// A wrapper class for a stream that
/// allows multiple listeners to listen to the same stream.
class _StreamWrapper<T> {
  final Stream<T> _stream;

  final List<StreamController<T>> controllers = [];

  final void Function(_StreamWrapper<T> wrapper) onClosed;

  bool isClosed = false;

  StreamSubscription<T>? _subscription;

  _StreamWrapper(this._stream, this.onClosed) {
    _listen();
  }

  void _listen() {
    _subscription = _stream.listen(
      (data) {
        if (isClosed) {
          return;
        }
        for (var controller in controllers) {
          if (!controller.isClosed) {
            controller.add(data);
          }
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (isClosed) {
          return;
        }
        for (var controller in controllers) {
          if (!controller.isClosed) {
            controller.addError(error, stackTrace);
          }
        }
      },
      onDone: _close,
    );
  }

  void _close() {
    if (isClosed) {
      return;
    }
    isClosed = true;
    for (var controller in controllers) {
      if (!controller.isClosed) {
        controller.close();
      }
    }
    controllers.clear();
    _subscription = null;
    onClosed(this);
  }

  Stream<T> get stream {
    if (isClosed) {
      throw Exception('Stream is closed');
    }
    var controller = StreamController<T>();
    controllers.add(controller);
    controller.onCancel = () {
      controllers.remove(controller);
      if (controllers.isEmpty) {
        cancel();
      }
    };
    return controller.stream;
  }

  void cancel() {
    if (isClosed) {
      return;
    }
    isClosed = true;
    for (var controller in controllers) {
      if (!controller.isClosed) {
        controller.close();
      }
    }
    controllers.clear();
    final subscription = _subscription;
    _subscription = null;
    onClosed(this);
    if (subscription == null) {
      return;
    }
    unawaited(subscription.cancel());
  }
}

class ImageDownloadProgress {
  final int currentBytes;

  final int? totalBytes;

  final Uint8List? imageBytes;

  const ImageDownloadProgress({
    required this.currentBytes,
    required this.totalBytes,
    this.imageBytes,
  });
}
