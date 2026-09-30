import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/local_storage_guard.dart';

void main() {
  test(
    'migration and recovery are refused while an import owns storage',
    () async {
      final guard = LocalComicStorageGuard();
      final gate = Completer<void>();
      final importing = guard.runImport(() => gate.future);
      var modified = false;
      await expectLater(
        guard.runExclusive(() async => modified = true),
        throwsA(isA<LocalComicStorageBusy>()),
      );
      expect(modified, isFalse);
      gate.complete();
      await importing;
      await guard.runExclusive(() async => modified = true);
      expect(modified, isTrue);
    },
  );

  test('imports wait until migration or recovery finishes', () async {
    final guard = LocalComicStorageGuard();
    final gate = Completer<void>();
    var converted = false;
    final migration = guard.runExclusive(() => gate.future);
    final importing = guard.runImport(() async => converted = true);
    await Future<void>.delayed(Duration.zero);
    expect(converted, isFalse);
    await expectLater(
      guard.runExclusive(() async {}),
      throwsA(isA<LocalComicStorageBusy>()),
    );
    gate.complete();
    await migration;
    await importing;
    expect(converted, isTrue);
  });

  test('failed operations release storage and wake waiting imports', () async {
    final guard = LocalComicStorageGuard();
    final gate = Completer<void>();
    final migrating = guard.runExclusive(() async {
      await gate.future;
      throw StateError('migration failed');
    });
    final failed = expectLater(migrating, throwsStateError);
    final importing = guard.runImport(() async => 'resumed');
    gate.complete();
    await failed;
    expect(await importing, 'resumed');
    await expectLater(
      guard.runImport(() async => throw StateError('import failed')),
      throwsStateError,
    );
    expect(await guard.runExclusive(() async => 'available'), 'available');
  });
}
