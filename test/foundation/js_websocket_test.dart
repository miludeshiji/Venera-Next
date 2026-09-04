import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/js_websocket.dart';

void main() {
  late HttpServer server;
  late JsWebSocketBridge bridge;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    bridge = JsWebSocketBridge(proxyResolver: () async => null);
  });

  tearDown(() async {
    await bridge.dispose();
    await server.close(force: true);
  });

  test('connect forwards headers and protocol and exchanges text', () async {
    final requestSeen = Completer<HttpRequest>();
    unawaited(() async {
      final request = await server.first;
      requestSeen.complete(request);
      final socket = await WebSocketTransformer.upgrade(
        request,
        protocolSelector: (protocols) => protocols.first,
      );
      await for (final data in socket) {
        socket.add(data);
      }
    }());

    final connected =
        await bridge.handle({
              'function': 'connect',
              'url': 'ws://127.0.0.1:${server.port}/socket',
              'headers': {'X-Test': 'bridge'},
              'protocols': ['venera-test'],
            })
            as Map<String, dynamic>;

    expect((await requestSeen.future).headers.value('x-test'), 'bridge');
    expect(connected['protocol'], 'venera-test');
    await bridge.handle({
      'function': 'send',
      'id': connected['id'],
      'data': 'hello',
    });
    expect(
      await bridge.handle({'function': 'receive', 'id': connected['id']}),
      {'type': 'message', 'data': 'hello'},
    );
  });

  test('binary frames cross the bridge without data loss', () async {
    unawaited(() async {
      final socket = await WebSocketTransformer.upgrade(await server.first);
      await for (final data in socket) {
        socket.add(data);
      }
    }());
    final connected = await _connect(bridge, server.port);
    await bridge.handle({
      'function': 'send',
      'id': connected['id'],
      'data': [0, 127, 255],
    });
    final event =
        await bridge.handle({'function': 'receive', 'id': connected['id']})
            as Map<String, dynamic>;
    expect(event['type'], 'message');
    expect(event['data'], Uint8List.fromList([0, 127, 255]));
  });

  test('queued and pending receives preserve message order', () async {
    final serverSocket = Completer<WebSocket>();
    unawaited(() async {
      serverSocket.complete(
        await WebSocketTransformer.upgrade(await server.first),
      );
    }());
    final connected = await _connect(bridge, server.port);
    final socket = await serverSocket.future;
    socket.add('first');
    await pumpEventQueue();
    expect(
      await bridge.handle({'function': 'receive', 'id': connected['id']}),
      {'type': 'message', 'data': 'first'},
    );
    final waiting = bridge.handle({
      'function': 'receive',
      'id': connected['id'],
    });
    socket.add('second');
    expect(await waiting, {'type': 'message', 'data': 'second'});
  });

  test('only one receive may wait per connection', () async {
    unawaited(() async {
      await WebSocketTransformer.upgrade(await server.first);
    }());
    final connected = await _connect(bridge, server.port);
    final first = bridge.handle({'function': 'receive', 'id': connected['id']});
    final firstError = expectLater(first, throwsA(isA<StateError>()));
    expect(
      () => bridge.handle({'function': 'receive', 'id': connected['id']}),
      throwsA(isA<StateError>()),
    );
    await bridge.handle({'function': 'close', 'id': connected['id']});
    await firstError;
  });

  test('remote close is observable once and then removed', () async {
    final serverSocket = Completer<WebSocket>();
    unawaited(() async {
      serverSocket.complete(
        await WebSocketTransformer.upgrade(await server.first),
      );
    }());
    final connected = await _connect(bridge, server.port);
    await (await serverSocket.future).close(1001, 'away');
    expect(
      await bridge.handle({'function': 'receive', 'id': connected['id']}),
      {'type': 'close', 'code': 1001, 'reason': 'away'},
    );
    expect(bridge.debugConnectionCount, 0);
    await expectLater(
      bridge.handle({'function': 'receive', 'id': connected['id']}),
      throwsA(isA<StateError>()),
    );
  });
  test('close after a remote close remains idempotent', () async {
    final serverSocket = Completer<WebSocket>();
    unawaited(() async {
      serverSocket.complete(
        await WebSocketTransformer.upgrade(await server.first),
      );
    }());
    final connected = await _connect(bridge, server.port);
    await (await serverSocket.future).close(1000, 'done');
    await bridge.handle({'function': 'receive', 'id': connected['id']});
    await bridge.handle({'function': 'close', 'id': connected['id']});
  });

  test('local close is idempotent and blocks later sends', () async {
    unawaited(() async {
      await WebSocketTransformer.upgrade(await server.first);
    }());
    final connected = await _connect(bridge, server.port);
    final close = {'function': 'close', 'id': connected['id']};
    await bridge.handle(close);
    await bridge.handle(close);
    expect(
      () => bridge.handle({
        'function': 'send',
        'id': connected['id'],
        'data': 'late',
      }),
      throwsA(isA<StateError>()),
    );
  });
  test('invalid close frame leaves the connection usable', () async {
    unawaited(() async {
      final socket = await WebSocketTransformer.upgrade(await server.first);
      await for (final data in socket) {
        socket.add(data);
      }
    }());
    final connected = await _connect(bridge, server.port);
    expect(
      () => bridge.handle({
        'function': 'close',
        'id': connected['id'],
        'code': 1006,
      }),
      throwsA(isA<ArgumentError>()),
    );
    await bridge.handle({
      'function': 'send',
      'id': connected['id'],
      'data': 'still-open',
    });
    expect(
      await bridge.handle({'function': 'receive', 'id': connected['id']}),
      {'type': 'message', 'data': 'still-open'},
    );
  });

  test('dispose closes all connections and pending receives', () async {
    unawaited(() async {
      await for (final request in server) {
        await WebSocketTransformer.upgrade(request);
      }
    }());
    final first = await _connect(bridge, server.port);
    await _connect(bridge, server.port);
    final receive = bridge.handle({'function': 'receive', 'id': first['id']});
    final receiveError = expectLater(receive, throwsA(isA<StateError>()));
    expect(bridge.debugConnectionCount, 2);
    await bridge.dispose();
    expect(bridge.debugConnectionCount, 0);
    await receiveError;
  });
  test('connection timeout includes proxy resolution', () async {
    bridge = JsWebSocketBridge(
      proxyResolver: () => Completer<String?>().future,
    );
    await expectLater(
      bridge.handle({
        'function': 'connect',
        'url': 'ws://127.0.0.1:${server.port}/socket',
        'connectTimeoutMs': 20,
      }),
      throwsA(
        predicate(
          (error) => error.toString().contains(
            'WebSocket Connect Error: connection timed out',
          ),
        ),
      ),
    );
  });

  test('connection timeout includes the connector', () async {
    bridge = JsWebSocketBridge(
      proxyResolver: () async => null,
      connector: (_, {protocols, headers, customClient}) =>
          Completer<WebSocket>().future,
    );
    await expectLater(
      bridge.handle({
        'function': 'connect',
        'url': 'ws://127.0.0.1:${server.port}/socket',
        'connectTimeoutMs': 20,
      }),
      throwsA(
        predicate(
          (error) => error.toString().contains(
            'WebSocket Connect Error: connection timed out',
          ),
        ),
      ),
    );
  });

  test('proxy resolver configures the HttpClient proxy callback', () async {
    String? directProxy;
    bridge = JsWebSocketBridge(
      proxyResolver: () async => null,
      onProxyApplied: (proxy) => directProxy = proxy,
      connector: (_, {protocols, headers, customClient}) {
        return Future.error(const WebSocketException('stop'));
      },
    );
    await expectLater(
      bridge.handle({'function': 'connect', 'url': 'wss://example.com/socket'}),
      throwsException,
    );
    expect(directProxy, 'DIRECT');

    String? manualProxy;
    bridge = JsWebSocketBridge(
      proxyResolver: () async => '127.0.0.1:7890',
      onProxyApplied: (proxy) => manualProxy = proxy,
      connector: (_, {protocols, headers, customClient}) {
        return Future.error(const WebSocketException('stop'));
      },
    );
    await expectLater(
      bridge.handle({'function': 'connect', 'url': 'wss://example.com/socket'}),
      throwsException,
    );
    expect(manualProxy, 'PROXY 127.0.0.1:7890');
  });

  test(
    'unconsumed remote close releases active connection and expires',
    () async {
      final serverSocket = Completer<WebSocket>();
      bridge = JsWebSocketBridge(
        proxyResolver: () async => null,
        terminalStateTtl: const Duration(milliseconds: 20),
      );
      unawaited(() async {
        serverSocket.complete(
          await WebSocketTransformer.upgrade(await server.first),
        );
      }());
      await _connect(bridge, server.port);
      await (await serverSocket.future).close(1000, 'done');
      await pumpEventQueue();
      expect(bridge.debugConnectionCount, 0);
      expect(bridge.debugTerminalStateCount, 1);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(bridge.debugTerminalStateCount, 0);
    },
  );

  test('terminal states are capacity bounded', () async {
    bridge = JsWebSocketBridge(
      proxyResolver: () async => null,
      maxTerminalStates: 2,
    );
    unawaited(() async {
      await for (final request in server) {
        final socket = await WebSocketTransformer.upgrade(request);
        await socket.close(1000, 'done');
      }
    }());
    await _connect(bridge, server.port);
    await _connect(bridge, server.port);
    await _connect(bridge, server.port);
    await pumpEventQueue();
    expect(bridge.debugConnectionCount, 0);
    expect(bridge.debugTerminalStateCount, 2);
  });

  test('invalid arguments and unknown IDs fail explicitly', () async {
    expect(
      () =>
          bridge.handle({'function': 'connect', 'url': 'https://example.com'}),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => bridge.handle({'function': 'receive', 'id': 999}),
      throwsA(isA<StateError>()),
    );
  });
  test('pending receive observes remote close exactly once', () async {
    final serverSocket = Completer<WebSocket>();
    unawaited(() async {
      serverSocket.complete(
        await WebSocketTransformer.upgrade(await server.first),
      );
    }());
    final connected = await _connect(bridge, server.port);
    final receive = bridge.handle({
      'function': 'receive',
      'id': connected['id'],
    });
    await (await serverSocket.future).close(1000, 'done');
    expect(await receive, {'type': 'close', 'code': 1000, 'reason': 'done'});
    expect(bridge.debugConnectionCount, 0);
    expect(bridge.debugTerminalStateCount, 1);
    await expectLater(
      bridge.handle({'function': 'receive', 'id': connected['id']}),
      throwsA(isA<StateError>()),
    );
    expect(bridge.debugTerminalStateCount, 0);
  });
}

Future<Map<String, dynamic>> _connect(
  JsWebSocketBridge bridge,
  int port,
) async {
  return await bridge.handle({
        'function': 'connect',
        'url': 'ws://127.0.0.1:$port/socket',
      })
      as Map<String, dynamic>;
}
