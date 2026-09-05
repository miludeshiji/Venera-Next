import 'dart:async';
import 'package:fake_async/fake_async.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/remote_progress.dart';
import 'package:venera_next/foundation/res.dart';

void main() {
  group('RemoteProgressTracker', () {
    test('debounces multiple rapid page updates to latest value after 450ms', () {
      fakeAsync((async) {
        final calls = <(String, String, int)>[];
        final tracker = RemoteProgressTracker(
          comicId: 'comic_1',
          onUpdateProgress: (comicId, epId, page) async {
            calls.add((comicId, epId, page));
            return const Res(true);
          },
        );

        tracker.schedule('ep_1', 1);
        async.elapse(const Duration(milliseconds: 100));
        tracker.schedule('ep_1', 2);
        async.elapse(const Duration(milliseconds: 100));
        tracker.schedule('ep_1', 3);
        async.elapse(const Duration(milliseconds: 100));
        tracker.schedule('ep_1', 4);

        // Before 450ms has elapsed since the last schedule call, no call is made
        async.elapse(const Duration(milliseconds: 400));
        expect(calls, isEmpty);

        // Once 450ms has elapsed since the last schedule call, only latest page is reported
        async.elapse(const Duration(milliseconds: 50));
        expect(calls, [('comic_1', 'ep_1', 4)]);
        expect(tracker.lastUploadedEpId, 'ep_1');
        expect(tracker.lastUploadedPage, 4);
      });
    });

    test('deduplicates already uploaded position', () {
      fakeAsync((async) {
        int callCount = 0;
        final tracker = RemoteProgressTracker(
          comicId: 'comic_1',
          onUpdateProgress: (comicId, epId, page) async {
            callCount++;
            return const Res(true);
          },
        );

        tracker.schedule('ep_1', 5);
        async.elapse(const Duration(milliseconds: 450));
        expect(callCount, 1);
        expect(tracker.lastUploadedPage, 5);

        // Scheduling the same position again does not trigger another call
        tracker.schedule('ep_1', 5);
        async.elapse(const Duration(milliseconds: 500));
        expect(callCount, 1);
        expect(tracker.hasPending, isFalse);

        // If user temporarily navigates away then back within debounce window, cancels pending
        tracker.schedule('ep_1', 6);
        expect(tracker.hasPending, isTrue);
        async.elapse(const Duration(milliseconds: 100));
        tracker.schedule('ep_1', 5);
        expect(tracker.hasPending, isFalse);
        async.elapse(const Duration(milliseconds: 500));
        expect(callCount, 1);
      });
    });

    test('serializes write requests through Future queue', () {
      fakeAsync((async) {
        final executionLog = <String>[];
        final completers = <Completer<Res<bool>>>[
          Completer<Res<bool>>(),
          Completer<Res<bool>>(),
        ];
        int index = 0;

        final tracker = RemoteProgressTracker(
          comicId: 'comic_1',
          onUpdateProgress: (comicId, epId, page) {
            final cIndex = index++;
            executionLog.add('start_$page');
            return completers[cIndex].future.then((res) {
              executionLog.add('end_$page');
              return res;
            });
          },
        );

        // Schedule first page and flush immediately to start in-flight request
        tracker.schedule('ep_1', 10);
        tracker.flush();
        async.flushMicrotasks();
        expect(executionLog, ['start_10']);

        // While request 10 is in-flight, schedule page 11 and flush
        tracker.schedule('ep_1', 11);
        tracker.flush();

        // Request 11 must NOT have started yet because request 10 is still in flight
        expect(executionLog, ['start_10']);

        // Complete request 10
        completers[0].complete(const Res(true));
        async.elapse(Duration.zero);

        // Now request 10 has ended and request 11 has started in serial order
        expect(executionLog, ['start_10', 'end_10', 'start_11']);

        // Complete request 11
        completers[1].complete(const Res(true));
        async.elapse(Duration.zero);

        expect(executionLog, ['start_10', 'end_10', 'start_11', 'end_11']);
      });
    });

    test(
      '5 -> 6 in-flight -> 5 reverts and uploads 5 afterwards ([5, 6, 5])',
      () {
        fakeAsync((async) {
          final calls = <int>[];
          final completers = <Completer<Res<bool>>>[];

          final tracker = RemoteProgressTracker(
            comicId: 'comic_1',
            onUpdateProgress: (comicId, epId, page) {
              calls.add(page);
              final c = Completer<Res<bool>>();
              completers.add(c);
              return c.future;
            },
          );

          // Initial upload 5
          tracker.schedule('ep_1', 5);
          tracker.flush();
          async.flushMicrotasks();
          expect(calls, [5]);
          completers[0].complete(const Res(true));
          async.flushMicrotasks();
          expect(tracker.lastUploadedPage, 5);

          // Start upload 6 (in-flight)
          tracker.schedule('ep_1', 6);
          tracker.flush();
          async.flushMicrotasks();
          expect(calls, [5, 6]);

          // While 6 is in-flight, navigate back to 5
          tracker.schedule('ep_1', 5);
          async.flushMicrotasks();
          expect(calls, [5, 6]);

          // Complete upload 6
          completers[1].complete(const Res(true));
          async.flushMicrotasks();

          // Desired (5) != lastUploaded (6), so tracker immediately uploads 5
          expect(calls, [5, 6, 5]);

          // Complete upload 5
          completers[2].complete(const Res(true));
          async.flushMicrotasks();

          expect(tracker.lastUploadedPage, 5);
          expect(tracker.hasPending, isFalse);
        });
      },
    );

    test('10 active with rapid 11..14 collapses to [10, 14]', () {
      fakeAsync((async) {
        final calls = <int>[];
        final completers = <Completer<Res<bool>>>[];

        final tracker = RemoteProgressTracker(
          comicId: 'comic_1',
          onUpdateProgress: (comicId, epId, page) {
            calls.add(page);
            final c = Completer<Res<bool>>();
            completers.add(c);
            return c.future;
          },
        );

        // Start write 10
        tracker.schedule('ep_1', 10);
        tracker.flush();
        async.flushMicrotasks();
        expect(calls, [10]);

        // While 10 is in flight, rapid schedules 11, 12, 13, 14
        tracker.schedule('ep_1', 11);
        async.elapse(const Duration(milliseconds: 50));
        tracker.schedule('ep_1', 12);
        async.elapse(const Duration(milliseconds: 50));
        tracker.schedule('ep_1', 13);
        async.elapse(const Duration(milliseconds: 50));
        tracker.schedule('ep_1', 14);
        async.flushMicrotasks();

        expect(calls, [10]);

        // Complete write 10
        completers[0].complete(const Res(true));
        async.flushMicrotasks();

        // Intermediate 11..13 dropped; only latest desired 14 uploaded
        expect(calls, [10, 14]);

        // Complete write 14
        completers[1].complete(const Res(true));
        async.flushMicrotasks();

        expect(tracker.lastUploadedPage, 14);
        expect(tracker.hasPending, isFalse);
      });
    });

    test('isolates errors and allows retry after failure', () {
      fakeAsync((async) {
        final errors = <Object>[];
        int attempts = 0;
        bool shouldFail = true;

        final tracker = RemoteProgressTracker(
          comicId: 'comic_1',
          onUpdateProgress: (comicId, epId, page) async {
            attempts++;
            if (shouldFail) {
              return const Res.error('Network timeout');
            }
            return const Res(true);
          },
          onError: (error, stackTrace) => errors.add(error),
        );

        tracker.schedule('ep_1', 8);
        tracker.flush();
        async.elapse(Duration.zero);

        // Attempt failed, error is captured without bubbling to caller
        expect(attempts, 1);
        expect(errors, ['Network timeout']);
        expect(tracker.lastUploadedPage, isNull);

        // Because it failed, scheduling page 8 again is NOT deduplicated and can be retried
        shouldFail = false;
        tracker.schedule('ep_1', 8);
        tracker.flush();
        async.elapse(Duration.zero);

        expect(attempts, 2);
        expect(tracker.lastUploadedPage, 8);
      });
    });

    test(
      'failed write does not infinite loop on completion, but retries on flush',
      () {
        fakeAsync((async) {
          int attempts = 0;
          bool shouldFail = true;
          final errors = <Object>[];

          final tracker = RemoteProgressTracker(
            comicId: 'comic_1',
            onUpdateProgress: (comicId, epId, page) async {
              attempts++;
              if (shouldFail) {
                return const Res.error('Network failed');
              }
              return const Res(true);
            },
            onError: (error, stackTrace) => errors.add(error),
          );

          tracker.schedule('ep_1', 20);
          tracker.flush();
          async.elapse(Duration.zero);

          expect(attempts, 1);
          expect(errors, ['Network failed']);
          expect(tracker.lastUploadedPage, isNull);
          expect(tracker.desiredPage, 20);
          expect(tracker.hasPending, isTrue);

          // Completion callback respects failure latch; no automatic retry storm occurs
          async.elapse(const Duration(seconds: 5));
          expect(attempts, 1);

          // External flush unlatches failure and retries
          shouldFail = false;
          tracker.flush();
          async.elapse(Duration.zero);

          expect(attempts, 2);
          expect(tracker.lastUploadedPage, 20);
          expect(tracker.hasPending, isFalse);
        });
      },
    );

    test(
      'flush waits for active write and subsequent latest desired to complete',
      () {
        fakeAsync((async) {
          final completers = <Completer<Res<bool>>>[];
          final calls = <int>[];

          final tracker = RemoteProgressTracker(
            comicId: 'comic_1',
            onUpdateProgress: (comicId, epId, page) {
              calls.add(page);
              final c = Completer<Res<bool>>();
              completers.add(c);
              return c.future;
            },
          );

          tracker.schedule('ep_1', 1);
          final flushFuture = tracker.flush();
          async.flushMicrotasks();
          expect(calls, [1]);

          bool flushCompleted = false;
          flushFuture.then((_) => flushCompleted = true);

          // While 1 is active, schedule 2
          tracker.schedule('ep_1', 2);
          async.flushMicrotasks();

          // Complete write 1
          completers[0].complete(const Res(true));
          async.flushMicrotasks();

          // Write 2 has started; flushFuture must still be waiting
          expect(calls, [1, 2]);
          expect(flushCompleted, isFalse);

          // Complete write 2
          completers[1].complete(const Res(true));
          async.flushMicrotasks();

          // flushFuture is completed now that latest desired has drained
          expect(flushCompleted, isTrue);
          expect(tracker.lastUploadedPage, 2);
        });
      },
    );

    test(
      'dispose stops new schedules but drains active write and existing desired',
      () {
        fakeAsync((async) {
          final completers = <Completer<Res<bool>>>[];
          final calls = <int>[];

          final tracker = RemoteProgressTracker(
            comicId: 'comic_1',
            onUpdateProgress: (comicId, epId, page) {
              calls.add(page);
              final c = Completer<Res<bool>>();
              completers.add(c);
              return c.future;
            },
          );

          tracker.schedule('ep_1', 30);
          tracker.flush();
          async.flushMicrotasks();
          expect(calls, [30]);

          // Schedule 31 before dispose
          tracker.schedule('ep_1', 31);

          bool disposeCompleted = false;
          final disposeFuture = tracker.dispose();
          disposeFuture.then((_) => disposeCompleted = true);

          // Schedule after dispose is ignored
          tracker.schedule('ep_1', 32);
          expect(tracker.isDisposed, isTrue);

          // Complete write 30
          completers[0].complete(const Res(true));
          async.flushMicrotasks();

          // 31 is drained, 32 is not
          expect(calls, [30, 31]);
          expect(disposeCompleted, isFalse);

          // Complete write 31
          completers[1].complete(const Res(true));
          async.flushMicrotasks();

          expect(disposeCompleted, isTrue);
          expect(tracker.lastUploadedPage, 31);
          expect(calls, [30, 31]);
        });
      },
    );

    test(
      'catches thrown exceptions and does not break subsequent queued writes',
      () {
        fakeAsync((async) {
          final errors = <Object>[];
          final completedPages = <int>[];

          final tracker = RemoteProgressTracker(
            comicId: 'comic_1',
            onUpdateProgress: (comicId, epId, page) async {
              if (page == 1) {
                throw Exception('Server 500 error');
              }
              completedPages.add(page);
              return const Res(true);
            },
            onError: (error, stackTrace) => errors.add(error),
          );

          tracker.schedule('ep_1', 1);
          tracker.flush();
          tracker.schedule('ep_1', 2);
          tracker.flush();
          async.elapse(Duration.zero);

          expect(errors.length, 1);
          expect(errors.first.toString(), contains('Server 500 error'));
          // Subsequent write for page 2 still succeeded despite page 1 throwing
          expect(completedPages, [2]);
          expect(tracker.lastUploadedPage, 2);
        });
      },
    );

    test(
      'flush submits pending progress immediately without waiting for timer',
      () {
        fakeAsync((async) {
          final calls = <(String, String, int)>[];
          final tracker = RemoteProgressTracker(
            comicId: 'comic_1',
            onUpdateProgress: (comicId, epId, page) async {
              calls.add((comicId, epId, page));
              return const Res(true);
            },
          );

          tracker.schedule('ep_1', 15);
          expect(calls, isEmpty);

          tracker.flush();
          async.elapse(Duration.zero);
          expect(calls, [('comic_1', 'ep_1', 15)]);

          // Consecutive flush when nothing pending is idempotent
          tracker.flush();
          async.elapse(Duration.zero);
          expect(calls.length, 1);
        });
      },
    );

    test(
      'dispose flushes pending progress and ignores further schedule calls',
      () {
        fakeAsync((async) {
          final calls = <(String, String, int)>[];
          final tracker = RemoteProgressTracker(
            comicId: 'comic_1',
            onUpdateProgress: (comicId, epId, page) async {
              calls.add((comicId, epId, page));
              return const Res(true);
            },
          );

          tracker.schedule('ep_1', 20);
          expect(tracker.isDisposed, isFalse);

          tracker.dispose();
          async.elapse(Duration.zero);
          expect(tracker.isDisposed, isTrue);
          expect(calls, [('comic_1', 'ep_1', 20)]);

          // Scheduling after dispose is ignored
          tracker.schedule('ep_1', 21);
          async.elapse(const Duration(seconds: 1));
          expect(calls, [('comic_1', 'ep_1', 20)]);
        });
      },
    );

    test(
      'schedule ignores empty or invalid epId and non-positive page numbers',
      () {
        fakeAsync((async) {
          final calls = <(String, String, int)>[];
          final tracker = RemoteProgressTracker(
            comicId: 'comic_1',
            onUpdateProgress: (comicId, epId, page) async {
              calls.add((comicId, epId, page));
              return const Res(true);
            },
          );

          tracker.schedule('', 1);
          tracker.schedule('ep_1', 0);
          tracker.schedule('ep_1', -1);
          tracker.flush();
          async.elapse(const Duration(seconds: 1));

          expect(calls, isEmpty);
          expect(tracker.hasPending, isFalse);
          expect(tracker.desiredEpId, isNull);
          expect(tracker.desiredPage, isNull);
        });
      },
    );
  });
}
