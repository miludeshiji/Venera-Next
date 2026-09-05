import 'dart:async';

import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/log.dart';

typedef RemoteProgressErrorHandler =
    void Function(Object error, StackTrace? stackTrace);

/// Single-direction remote reading progress synchronization scheduler.
///
/// Encapsulates:
/// - 450ms debounce
/// - At most one active write + latest desired position (latest-wins)
/// - Deduplication against last successfully uploaded position
/// - Failure target latch preventing automatic retry storms while retaining desired position
/// - Error isolation (failures are caught and never bubble up to Reader)
/// - Drain Future for flush and dispose awaiting in-flight and latest desired updates
class RemoteProgressTracker {
  RemoteProgressTracker({
    required this.comicId,
    required UpdateReadProgressFunc onUpdateProgress,
    Duration debounceDuration = const Duration(milliseconds: 450),
    RemoteProgressErrorHandler? onError,
  }) : _onUpdateProgress = onUpdateProgress,
       _debounceDuration = debounceDuration,
       _onError = onError;

  final String comicId;
  final UpdateReadProgressFunc _onUpdateProgress;
  final Duration _debounceDuration;
  final RemoteProgressErrorHandler? _onError;

  Timer? _debounceTimer;

  String? _desiredEpId;
  int? _desiredPage;

  String? _lastUploadedEpId;
  int? _lastUploadedPage;

  String? _failedEpId;
  int? _failedPage;

  Future<void>? _activeWrite;
  Completer<void>? _drainCompleter;

  bool _disposed = false;

  bool get isDisposed => _disposed;
  bool get hasPending =>
      _desiredEpId != null &&
      _desiredPage != null &&
      !(_lastUploadedEpId == _desiredEpId && _lastUploadedPage == _desiredPage);
  String? get desiredEpId => _desiredEpId;
  int? get desiredPage => _desiredPage;
  String? get pendingEpId => hasPending ? _desiredEpId : null;
  int? get pendingPage => hasPending ? _desiredPage : null;
  String? get lastUploadedEpId => _lastUploadedEpId;
  int? get lastUploadedPage => _lastUploadedPage;
  bool get isWriting => _activeWrite != null;

  /// Schedules a 1-based page progress update.
  ///
  /// Ignored if disposed, if [epId] is empty, or if [page] <= 0.
  void schedule(String epId, int page) {
    if (_disposed || epId.isEmpty || page <= 0) {
      return;
    }

    _desiredEpId = epId;
    _desiredPage = page;
    // External schedule unlatches any prior failure latch.
    _failedEpId = null;
    _failedPage = null;

    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDuration, () {
      _debounceTimer = null;
      _tryStartWrite();
    });
  }

  /// Flushes any pending debounced progress immediately.
  ///
  /// Unlatches prior failures and returns a Future that completes when
  /// the active write and any subsequent latest desired update have finished.
  Future<void> flush() {
    if (_disposed) {
      if (_activeWrite == null) {
        return Future.value();
      }
      _drainCompleter ??= Completer<void>();
      return _drainCompleter!.future;
    }

    _debounceTimer?.cancel();
    _debounceTimer = null;

    // External flush unlatches prior failure latch to allow retry.
    _failedEpId = null;
    _failedPage = null;

    _tryStartWrite();

    if (_activeWrite == null) {
      return Future.value();
    }

    _drainCompleter ??= Completer<void>();
    return _drainCompleter!.future;
  }

  /// Disposes the tracker, preventing new schedules while draining the latest desired update.
  ///
  /// Returns a Future that completes when all writes for existing desired progress have finished.
  Future<void> dispose() {
    if (_disposed) {
      if (_activeWrite == null) {
        return Future.value();
      }
      _drainCompleter ??= Completer<void>();
      return _drainCompleter!.future;
    }

    _disposed = true;

    _debounceTimer?.cancel();
    _debounceTimer = null;

    // External dispose unlatches prior failure latch.
    _failedEpId = null;
    _failedPage = null;

    _tryStartWrite();

    if (_activeWrite == null) {
      return Future.value();
    }

    _drainCompleter ??= Completer<void>();
    return _drainCompleter!.future;
  }

  void _tryStartWrite() {
    if (_activeWrite != null) {
      return;
    }

    final epId = _desiredEpId;
    final page = _desiredPage;

    if (epId == null || page == null) {
      _checkDrainComplete();
      return;
    }

    if (_lastUploadedEpId == epId && _lastUploadedPage == page) {
      _checkDrainComplete();
      return;
    }

    // Failure latch: prevent automatic retry storm if this exact target just failed
    if (_failedEpId == epId && _failedPage == page) {
      _checkDrainComplete();
      return;
    }

    _debounceTimer?.cancel();
    _debounceTimer = null;

    late final Future<void> writeFuture;

    writeFuture = _write(epId, page).whenComplete(() {
      if (identical(_activeWrite, writeFuture)) {
        _activeWrite = null;
      }
      _tryStartWrite();
    });

    _activeWrite = writeFuture;
  }

  Future<void> _write(String epId, int page) async {
    try {
      final res = await _onUpdateProgress(comicId, epId, page);
      if (res.success) {
        _lastUploadedEpId = epId;
        _lastUploadedPage = page;
        _failedEpId = null;
        _failedPage = null;
      } else {
        _failedEpId = epId;
        _failedPage = page;
        final errMsg =
            res.errorMessage ?? 'Remote progress update returned error';
        if (_onError != null) {
          _onError(errMsg, null);
        } else {
          Log.warning(
            'Reader',
            'Failed to update remote read progress ($comicId, $epId, $page): $errMsg',
          );
        }
      }
    } catch (error, stackTrace) {
      _failedEpId = epId;
      _failedPage = page;
      if (_onError != null) {
        _onError(error, stackTrace);
      } else {
        Log.error(
          'Reader',
          'Exception updating remote read progress ($comicId, $epId, $page): $error',
          stackTrace,
        );
      }
    }
  }

  void _checkDrainComplete() {
    if (_activeWrite == null && _drainCompleter != null) {
      final completer = _drainCompleter!;
      _drainCompleter = null;
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
  }
}
