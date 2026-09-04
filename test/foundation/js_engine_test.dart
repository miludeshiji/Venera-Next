import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/js_websocket.dart';

import 'dart:async';
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
