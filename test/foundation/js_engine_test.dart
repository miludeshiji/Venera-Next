import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/js_websocket.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:venera_next/foundation/log.dart';

void main() {
  test('read-only source retry recognizes malformed JSON responses', () {
    expect(
      JsEngine.debugIsRetryableReadError(
        Exception('SyntaxError: unexpected token < in JSON'),
      ),
      isTrue,
    );
    expect(
      JsEngine.debugIsRetryableReadError(
        Exception('JSException: Syntax error: unexpected end of input'),
      ),
      isTrue,
    );
  });

  test('read-only source retry recognizes transient network failures', () {
    for (final message in [
      'Connection timed out',
      'Connection reset by peer',
      'Connection terminated during handshake',
      'Response ended prematurely',
      'HTTP/2 stream was reset',
    ]) {
      expect(JsEngine.debugIsRetryableReadError(Exception(message)), isTrue);
    }
  });

  test('read-only source retry ignores unrelated failures', () {
    expect(
      JsEngine.debugIsRetryableReadError(
        Exception('SyntaxError: missing ) after argument list'),
      ),
      isFalse,
    );
    expect(
      JsEngine.debugIsRetryableReadError(Exception('Invalid Status Code: 403')),
      isFalse,
    );
  });
  test('reset waits for the old WebSocket bridge to dispose', () async {
    final disposeStarted = Completer<void>();
    final allowDispose = Completer<void>();
    var created = 0;
    JsEngine.cacheJsInit(Uint8List(0));
    Log.isMuted = true;
    JsEngine.debugCreateWebSocketBridge = () {
      created++;
      return created == 1
          ? _BlockingWebSocketBridge(disposeStarted, allowDispose)
          : JsWebSocketBridge();
    };
    addTearDown(() async {
      if (!allowDispose.isCompleted) allowDispose.complete();
      Log.isMuted = false;
      await JsEngine().dispose();
      JsEngine.debugResetWebSocketBridgeFactory();
    });

    await JsEngine().init();
    final reset = JsEngine.reset();
    await disposeStarted.future;
    expect(created, 1);

    allowDispose.complete();
    await reset;
    expect(created, 2);
  });

  test(
    'QuickJS Network.WebSocket wrapper maps Promise operations',
    () async {
      final initScript = await File('assets/init.js').readAsBytes();
      final calls = <Map<String, dynamic>>[];
      final bridge = _RecordingWebSocketBridge(calls);
      JsEngine.cacheJsInit(initScript);
      JsEngine.debugCreateWebSocketBridge = () => bridge;
      addTearDown(() async {
        await JsEngine().dispose();
        JsEngine.debugResetWebSocketBridgeFactory();
      });

      await JsEngine().init();
      final result = await JsEngine().runCode(r'''
      (async () => {
        const socket = await Network.WebSocket.connect(
          "wss://example.com/socket",
          {"X-Test": "yes"},
          {protocols: ["test"], connectTimeoutMs: 50}
        );
        await socket.send(new Uint8Array([1, 2, 3]));
        const message = await socket.receive();
        const beforeClose = socket.closed;
        await socket.close();
        await socket.close();
        return {
          id: socket.id,
          protocol: socket.protocol,
          message,
          beforeClose,
          afterClose: socket.closed
        };
      })()
    ''');

      expect(result['id'], 7);
      expect(result['protocol'], 'test');
      expect(result['message'], {'type': 'message', 'data': 'hello'});
      expect(result['beforeClose'], isFalse);
      expect(result['afterClose'], isTrue);
      expect(calls.map((call) => call['function']), [
        'connect',
        'send',
        'receive',
        'close',
      ]);
      expect(calls[1]['data'], isA<Uint8List>());
      expect(calls[1]['data'], Uint8List.fromList([1, 2, 3]));
    },
    skip: _qjsAvailable() ? false : 'flutter_qjs native library is unavailable',
  );

  group('JsEngine gzip _convert', () {
    test('normal gzip roundtrip preserves bytes and returns Uint8List', () {
      final original = Uint8List.fromList([1, 2, 3, 4, 5, 255, 0, 128]);
      final encoded = JsEngine.debugConvert({
        'type': 'gzip',
        'value': original,
        'isEncode': true,
      });
      expect(encoded, isA<Uint8List>());
      expect((encoded as Uint8List).length, greaterThan(0));

      final decoded = JsEngine.debugConvert({
        'type': 'gzip',
        'value': encoded,
        'isEncode': false,
      });
      expect(decoded, isA<Uint8List>());
      expect(decoded, equals(original));
    });

    test('compatible with generic List<int> and List input', () {
      final listInt = <int>[10, 20, 30, 40];
      final encoded = JsEngine.debugConvert({
        'type': 'gzip',
        'value': listInt,
        'isEncode': true,
      });
      expect(encoded, isA<Uint8List>());

      final genericList = <dynamic>[...encoded as Uint8List];
      final decoded = JsEngine.debugConvert({
        'type': 'gzip',
        'value': genericList,
        'isEncode': false,
      });
      expect(decoded, isA<Uint8List>());
      expect(decoded, equals(Uint8List.fromList(listInt)));
    });

    test('Unicode text utf8 bytes roundtrip via gzip', () {
      const text = '你好，世界！🚀 Gzip 编解码测试 12345 \u0000 \u{1F600}';
      final utf8Bytes = Uint8List.fromList(utf8.encode(text));
      final compressed =
          JsEngine.debugConvert({
                'type': 'gzip',
                'value': utf8Bytes,
                'isEncode': true,
              })
              as Uint8List;
      final decompressed =
          JsEngine.debugConvert({
                'type': 'gzip',
                'value': compressed,
                'isEncode': false,
              })
              as Uint8List;
      expect(utf8.decode(decompressed), equals(text));
    });

    test('empty buffer gzip roundtrip', () {
      final empty = Uint8List(0);
      final encoded =
          JsEngine.debugConvert({
                'type': 'gzip',
                'value': empty,
                'isEncode': true,
              })
              as Uint8List;
      expect(encoded.length, greaterThan(0));

      final decoded =
          JsEngine.debugConvert({
                'type': 'gzip',
                'value': encoded,
                'isEncode': false,
              })
              as Uint8List;
      expect(decoded.length, equals(0));
    });

    test(
      'decoding empty or non-gzip or corrupted input returns null without crash',
      () {
        Log.isMuted = true;
        addTearDown(() => Log.isMuted = false);

        expect(
          JsEngine.debugConvert({
            'type': 'gzip',
            'value': Uint8List.fromList([1, 2, 3, 4, 5]),
            'isEncode': false,
          }),
          isNull,
        );

        final validGzip = Uint8List.fromList(
          gzip.encode(List<int>.generate(128, (index) => index)),
        );
        validGzip[validGzip.length - 1] ^= 0xff;
        final truncated = validGzip;
        expect(
          JsEngine.debugConvert({
            'type': 'gzip',
            'value': truncated,
            'isEncode': false,
          }),
          isNull,
        );
      },
    );

    test('large payload roundtrip', () {
      final largeBytes = Uint8List.fromList(
        List.generate(100000, (i) => i % 256),
      );
      final encoded =
          JsEngine.debugConvert({
                'type': 'gzip',
                'value': largeBytes,
                'isEncode': true,
              })
              as Uint8List;
      final decoded =
          JsEngine.debugConvert({
                'type': 'gzip',
                'value': encoded,
                'isEncode': false,
              })
              as Uint8List;
      expect(decoded, equals(largeBytes));
    });

    test('invalid input value type returns null', () {
      Log.isMuted = true;
      addTearDown(() => Log.isMuted = false);

      expect(
        JsEngine.debugConvert({
          'type': 'gzip',
          'value': 'not a byte buffer',
          'isEncode': true,
        }),
        isNull,
      );
      expect(
        JsEngine.debugConvert({
          'type': 'gzip',
          'value': null,
          'isEncode': true,
        }),
        isNull,
      );
    });
  });

  test(
    'QuickJS Convert.encodeGzip and Convert.decodeGzip normal, Unicode, empty, corrupt, large payload and error handling',
    () async {
      final initScript = await File('assets/init.js').readAsBytes();
      JsEngine.cacheJsInit(initScript);
      addTearDown(() async {
        await JsEngine().dispose();
      });

      await JsEngine().init();

      final result = await JsEngine().runCode(r'''
      (() => {
        // 1. Normal roundtrip
        const rawStr = "Hello Gzip World!";
        const utf8Buf = Convert.encodeUtf8(rawStr);
        const gzipped = Convert.encodeGzip(utf8Buf);
        const unzipped = Convert.decodeGzip(gzipped);
        const restored = Convert.decodeUtf8(unzipped);

        // 2. Byte array roundtrip
        const sampleBytes = new Uint8Array([10, 20, 30, 40, 50, 255, 0, 128]);
        const sampleGzip = Convert.encodeGzip(sampleBytes.buffer);
        const sampleRestored = new Uint8Array(Convert.decodeGzip(sampleGzip));
        let sampleMatch = sampleBytes.length === sampleRestored.length;
        for (let i = 0; i < sampleBytes.length; i++) {
          if (sampleBytes[i] !== sampleRestored[i]) {
            sampleMatch = false;
            break;
          }
        }

        // 3. Unicode roundtrip
        const unicodeStr = "你好，世界！🚀 QuickJS Gzip 测试 漢字 12345 \u0000 \u{1F600}";
        const unicodeUtf8 = Convert.encodeUtf8(unicodeStr);
        const unicodeGzip = Convert.encodeGzip(unicodeUtf8);
        const unicodeUnzipped = Convert.decodeGzip(unicodeGzip);
        const unicodeRestored = Convert.decodeUtf8(unicodeUnzipped);

        // 4. Empty buffer roundtrip and empty decode error
        const emptyBuf = new ArrayBuffer(0);
        const emptyGzip = Convert.encodeGzip(emptyBuf);
        const emptyUnzipped = Convert.decodeGzip(emptyGzip);
        let emptyDecodeThrew = false;
        try {
          Convert.decodeGzip(new ArrayBuffer(0));
        } catch (e) {
          emptyDecodeThrew = true;
        }

        // 5. Non-gzip / corrupted input throws
        let nonGzipThrew = false;
        try {
          Convert.decodeGzip(new Uint8Array([1, 2, 3, 4, 5]).buffer);
        } catch (e) {
          nonGzipThrew = true;
        }

        let corruptedThrew = false;
        try {
          const valid = Convert.encodeGzip(Convert.encodeUtf8("some long text for testing"));
          const truncated = valid.slice(0, Math.floor(valid.byteLength / 2));
          Convert.decodeGzip(truncated);
        } catch (e) {
          corruptedThrew = true;
        }

        // 6. Large payload
        const largeStr = "ABCDEF1234567890".repeat(5000);
        const largeUtf8 = Convert.encodeUtf8(largeStr);
        const largeGzip = Convert.encodeGzip(largeUtf8);
        const largeUnzipped = Convert.decodeGzip(largeGzip);
        const largeRestored = Convert.decodeUtf8(largeUnzipped);

        // 7. Bridge exception / invalid input error throwing
        let bridgeEncodeNullThrew = false;
        try {
          Convert.encodeGzip(null);
        } catch (e) {
          bridgeEncodeNullThrew = true;
        }

        let bridgeDecodeNullThrew = false;
        try {
          Convert.decodeGzip(null);
        } catch (e) {
          bridgeDecodeNullThrew = true;
        }

        return {
          restored,
          sampleMatch,
          unicodeRestored,
          emptyGzipLen: emptyGzip.byteLength,
          emptyUnzippedLen: emptyUnzipped.byteLength,
          emptyDecodeThrew,
          nonGzipThrew,
          corruptedThrew,
          largeMatch: largeRestored === largeStr,
          largeCompressedSmaller: largeGzip.byteLength < largeUtf8.byteLength,
          bridgeEncodeNullThrew,
          bridgeDecodeNullThrew
        };
      })()
    ''');

      expect(result['restored'], equals('Hello Gzip World!'));
      expect(result['sampleMatch'], isTrue);
      expect(
        result['unicodeRestored'],
        equals('你好，世界！🚀 QuickJS Gzip 测试 漢字 12345 \u0000 \u{1F600}'),
      );
      expect(result['emptyGzipLen'], greaterThan(0));
      expect(result['emptyUnzippedLen'], equals(0));
      expect(result['emptyDecodeThrew'], isTrue);
      expect(result['nonGzipThrew'], isTrue);
      expect(result['corruptedThrew'], isTrue);
      expect(result['largeMatch'], isTrue);
      expect(result['largeCompressedSmaller'], isTrue);
      expect(result['bridgeEncodeNullThrew'], isTrue);
      expect(result['bridgeDecodeNullThrew'], isTrue);
    },
    skip: _qjsAvailable() ? false : 'flutter_qjs native library is unavailable',
  );

  test(
    'QuickJS Comment constructor supports userId, replyToId, replyToUserName with backward compatibility',
    () async {
      final initScript = await File('assets/init.js').readAsBytes();
      JsEngine.cacheJsInit(initScript);
      addTearDown(() async {
        await JsEngine().dispose();
      });

      await JsEngine().init();

      final result = await JsEngine().runCode(r'''
      (() => {
        const fullComment = new Comment({
          userName: "alice",
          avatar: "https://example.com/avatar.png",
          content: "great comic",
          time: "2026-09-05 12:00:00",
          replyCount: 5,
          id: "1001",
          isLiked: true,
          score: 42,
          voteStatus: 1,
          userId: "user_001",
          replyToId: "999",
          replyToUserName: "bob"
        });

        const legacyComment = new Comment({
          userName: "charlie",
          content: "legacy comment without reply fields"
        });

        return {
          full: {
            userName: fullComment.userName,
            avatar: fullComment.avatar,
            content: fullComment.content,
            time: fullComment.time,
            replyCount: fullComment.replyCount,
            id: fullComment.id,
            isLiked: fullComment.isLiked,
            score: fullComment.score,
            voteStatus: fullComment.voteStatus,
            userId: fullComment.userId,
            replyToId: fullComment.replyToId,
            replyToUserName: fullComment.replyToUserName
          },
          legacy: {
            userName: legacyComment.userName,
            content: legacyComment.content,
            userId: legacyComment.userId,
            replyToId: legacyComment.replyToId,
            replyToUserName: legacyComment.replyToUserName
          }
        };
      })()
    ''');

      expect(
        result['full'],
        equals({
          'userName': 'alice',
          'avatar': 'https://example.com/avatar.png',
          'content': 'great comic',
          'time': '2026-09-05 12:00:00',
          'replyCount': 5,
          'id': '1001',
          'isLiked': true,
          'score': 42,
          'voteStatus': 1,
          'userId': 'user_001',
          'replyToId': '999',
          'replyToUserName': 'bob',
        }),
      );

      expect(result['legacy']['userName'], equals('charlie'));
      expect(
        result['legacy']['content'],
        equals('legacy comment without reply fields'),
      );
      expect(result['legacy']['userId'], isNull);
      expect(result['legacy']['replyToId'], isNull);
      expect(result['legacy']['replyToUserName'], isNull);
    },
    skip: _qjsAvailable() ? false : 'flutter_qjs native library is unavailable',
  );
}

class _BlockingWebSocketBridge extends JsWebSocketBridge {
  _BlockingWebSocketBridge(this.started, this.release);

  final Completer<void> started;
  final Completer<void> release;

  @override
  Future<void> dispose() async {
    started.complete();
    await release.future;
    await super.dispose();
  }
}

class _RecordingWebSocketBridge extends JsWebSocketBridge {
  _RecordingWebSocketBridge(this.calls);

  final List<Map<String, dynamic>> calls;

  @override
  Future<Object?> handle(Map<String, dynamic> message) async {
    calls.add(Map<String, dynamic>.from(message));
    return switch (message['function']) {
      'connect' => {'id': 7, 'protocol': 'test'},
      'receive' => {'type': 'message', 'data': 'hello'},
      'send' || 'close' => null,
      _ => throw StateError('unexpected operation'),
    };
  }
}

bool _qjsAvailable() {
  try {
    final engine = FlutterQjs();
    engine.evaluate('1 + 1');
    engine.close();
    return true;
  } catch (_) {
    return false;
  }
}
