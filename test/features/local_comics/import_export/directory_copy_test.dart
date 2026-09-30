import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/import_export/import_export.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:venera_next/foundation/log.dart';

void main() {
  test(
    'a failed import preserves existing directory and later comics still copy',
    () async {
      final root = Directory.systemTemp.createTempSync('comic-copy-');
      final muted = Log.isMuted;
      Log.isMuted = true;
      addTearDown(() {
        Log.isMuted = muted;
        root.deleteSync(recursive: true);
      });
      final bad = Directory('${root.path}/input/Bad/chapter')
        ..createSync(recursive: true);
      File('${bad.path}/page.jpg').createSync();
      final good = Directory('${root.path}/input/Good')..createSync();
      File('${good.path}/page.jpg').writeAsBytesSync([1, 2, 3]);
      final existing = Directory('${root.path}/output/Bad')
        ..createSync(recursive: true);
      File('${existing.path}/original.txt').writeAsStringSync('keep');
      final result = await ImportComic.debugCopyDirectories([
        bad.parent.path,
        good.path,
      ], existing.parent.path);
      expect(result.keys, [good.path]);
      expect(File('${existing.path}/original.txt').readAsStringSync(), 'keep');
      expect(Directory('${existing.path}/chapter').existsSync(), isFalse);
      expect(File('${result[good.path]}/page.jpg').readAsBytesSync(), [
        1,
        2,
        3,
      ]);
    },
  );

  test('empty and sanitized-name collisions have independent ownership', () {
    final root = Directory.systemTemp.createTempSync('comic-allocation-');
    addTearDown(() => root.deleteSync(recursive: true));
    final first = DocumentImportSession.allocateDirectory(
      root.path,
      'Book: One',
    );
    final second = DocumentImportSession.allocateDirectory(
      root.path,
      'Book? One',
    );
    final bytes = [1, 2, 3];
    File('${second.path}/page.jpg').writeAsBytesSync(bytes);
    first.deleteSync(recursive: true);
    expect(File('${second.path}/page.jpg').readAsBytesSync(), bytes);
  });

  test('maximum-length titles preserve a distinguishing suffix', () {
    final root = Directory.systemTemp.createTempSync('comic-long-name-');
    addTearDown(() => root.deleteSync(recursive: true));
    final title = 'B' * maxSanitizedFileNameLength;
    final first = DocumentImportSession.allocateDirectory(root.path, title);
    final second = DocumentImportSession.allocateDirectory(root.path, title);
    File('${first.path}/page.jpg').writeAsBytesSync([1]);
    File('${second.path}/page.jpg').writeAsBytesSync([2]);
    expect(File('${first.path}/page.jpg').readAsBytesSync(), [1]);
    expect(File('${second.path}/page.jpg').readAsBytesSync(), [2]);
  });

  test(
    'copy never renames or modifies another in-progress directory',
    () async {
      final root = Directory.systemTemp.createTempSync('comic-owned-copy-');
      addTearDown(() => root.deleteSync(recursive: true));
      final destination = Directory('${root.path}/library')..createSync();
      final owned = DocumentImportSession.allocateDirectory(
        destination.path,
        'Book',
      );
      final source = Directory('${root.path}/input/Book')
        ..createSync(recursive: true);
      File('${source.path}/page.jpg').writeAsBytesSync([7, 8]);
      final copied = await ImportComic.debugCopyDirectories([
        source.path,
      ], destination.path);
      owned.deleteSync(recursive: true);
      expect(File('${copied[source.path]}/page.jpg').readAsBytesSync(), [7, 8]);
      expect(File('${source.path}/page.jpg').readAsBytesSync(), [7, 8]);
    },
  );
}
