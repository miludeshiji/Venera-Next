import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/js_websocket.dart';
import 'package:venera_next/foundation/log.dart';

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

  group('WebSocket lifecycle logging', () {
    test(
      'endpoint formatting strips credentials, query, fragment and normalizes empty path to /',
      () async {
        final port = server.port;
        final logs = <({LogLevel level, String content})>[];
        final testBridge = JsWebSocketBridge(
          proxyResolver: () async => null,
          lifecycleLogger: (level, content) =>
              logs.add((level: level, content: content)),
        );

        unawaited(() async {
          await WebSocketTransformer.upgrade(await server.first);
        }());

        final connected =
            await testBridge.handle({
                  'function': 'connect',
                  'url':
                      'ws://user:secret@127.0.0.1:$port?token=supersecret#frag123',
                })
                as Map<String, dynamic>;

        await testBridge.handle({'function': 'close', 'id': connected['id']});
        await testBridge.dispose();

        final expectedEndpoint = 'ws://127.0.0.1:$port/';

        expect(
          logs.any(
            (l) =>
                l.level == LogLevel.info &&
                l.content ==
                    'Connecting endpoint=$expectedEndpoint timeout=30000ms',
          ),
          isTrue,
        );
        expect(
          logs.any(
            (l) =>
                l.level == LogLevel.info &&
                l.content.startsWith(
                  'Connected id=${connected['id']} endpoint=$expectedEndpoint proxy=direct elapsed=',
                ),
          ),
          isTrue,
        );
        expect(
          logs.any(
            (l) =>
                l.level == LogLevel.info &&
                l.content ==
                    'Closed id=${connected['id']} endpoint=$expectedEndpoint direction=local code=1000 reasonPresent=false',
          ),
          isTrue,
        );

        for (final l in logs) {
          expect(l.content.contains('user:secret'), isFalse);
          expect(l.content.contains('token=supersecret'), isFalse);
          expect(l.content.contains('frag123'), isFalse);
        }
      },
    );

    test('endpoint path cap 256 truncates overly long paths', () async {
      final logs = <({LogLevel level, String content})>[];
      final testBridge = JsWebSocketBridge(
        proxyResolver: () async => null,
        lifecycleLogger: (level, content) =>
            logs.add((level: level, content: content)),
      );

      unawaited(() async {
        await WebSocketTransformer.upgrade(await server.first);
      }());

      final longPath = '/${'x' * 300}';
      final connected =
          await testBridge.handle({
                'function': 'connect',
                'url': 'ws://127.0.0.1:${server.port}$longPath',
              })
              as Map<String, dynamic>;

      await testBridge.handle({'function': 'close', 'id': connected['id']});
      await testBridge.dispose();

      final connectingLog = logs.firstWhere(
        (l) => l.content.startsWith('Connecting'),
      );
      final endpointMatch = RegExp(
        r'Connecting endpoint=(\S+) timeout=',
      ).firstMatch(connectingLog.content);
      expect(endpointMatch, isNotNull);
      final endpoint = endpointMatch!.group(1)!;
      final uri = Uri.parse(endpoint);
      expect(uri.path.length, 256);
      expect(uri.path.endsWith('...'), isTrue);
    });

    test(
      'lifecycle logging redacts secrets from URL, headers, payloads, close reason, and proxy directive',
      () async {
        final port = server.port;
        final logs = <({LogLevel level, String content})>[];
        final testBridge = JsWebSocketBridge(
          proxyResolver: () async => 'proxy-secret.internal:8888',
          connector: (url, {protocols, headers, customClient}) =>
              WebSocket.connect(url, protocols: protocols, headers: headers),
          lifecycleLogger: (level, content) =>
              logs.add((level: level, content: content)),
        );

        final serverSocketCompleter = Completer<WebSocket>();
        unawaited(() async {
          final request = await server.first;
          final socket = await WebSocketTransformer.upgrade(request);
          serverSocketCompleter.complete(socket);
          await for (final data in socket) {
            socket.add('echo:$data');
          }
        }());

        final connected =
            await testBridge.handle({
                  'function': 'connect',
                  'url':
                      'ws://user:secretpassword@127.0.0.1:$port/socket?token=supersecret#frag123',
                  'headers': {
                    'Authorization': 'Bearer supersecretjwt',
                    'X-Key': 'classifiedapikey',
                  },
                  'protocols': ['venera-test'],
                })
                as Map<String, dynamic>;

        await testBridge.handle({
          'function': 'send',
          'id': connected['id'],
          'data': 'classified_user_message_payload',
        });

        final received =
            await testBridge.handle({
                  'function': 'receive',
                  'id': connected['id'],
                })
                as Map<String, dynamic>;
        expect(received['data'], 'echo:classified_user_message_payload');

        final serverSocket = await serverSocketCompleter.future;
        await serverSocket.close(1000, 'classified_remote_close_reason');
        final closed =
            await testBridge.handle({
                  'function': 'receive',
                  'id': connected['id'],
                })
                as Map<String, dynamic>;

        expect(closed['type'], 'close');
        expect(closed['code'], 1000);
        expect(closed['reason'], 'classified_remote_close_reason');

        await testBridge.dispose();

        final forbiddenSecrets = [
          'secretpassword',
          'supersecret',
          'frag123',
          'Bearer',
          'supersecretjwt',
          'classifiedapikey',
          'classified_user_message_payload',
          'echo:classified_user_message_payload',
          'classified_remote_close_reason',
          'proxy-secret.internal',
          '8888',
        ];

        for (final log in logs) {
          for (final secret in forbiddenSecrets) {
            expect(
              log.content.contains(secret),
              isFalse,
              reason:
                  'Log "${log.content}" contains forbidden secret "$secret"',
            );
          }
        }

        final expectedEndpoint = 'ws://127.0.0.1:$port/socket';
        expect(
          logs.any(
            (l) =>
                l.level == LogLevel.info &&
                l.content ==
                    'Connecting endpoint=$expectedEndpoint timeout=30000ms',
          ),
          isTrue,
        );
        expect(
          logs.any(
            (l) =>
                l.level == LogLevel.info &&
                l.content.startsWith(
                  'Connected id=${connected['id']} endpoint=$expectedEndpoint proxy=configured elapsed=',
                ),
          ),
          isTrue,
        );
        expect(
          logs.any(
            (l) =>
                l.level == LogLevel.info &&
                l.content ==
                    'Closed id=${connected['id']} endpoint=$expectedEndpoint direction=remote code=1000 reasonPresent=true',
          ),
          isTrue,
        );
      },
    );

    test(
      'remote close: 1000 and 1001 log at info, abnormal codes log at warning with reasonPresent',
      () async {
        final port = server.port;
        final logs1 = <({LogLevel level, String content})>[];
        final bridge1 = JsWebSocketBridge(
          proxyResolver: () async => null,
          lifecycleLogger: (level, content) =>
              logs1.add((level: level, content: content)),
        );
        final s1 = Completer<WebSocket>();
        unawaited(() async {
          s1.complete(await WebSocketTransformer.upgrade(await server.first));
        }());
        final c1 = await _connect(bridge1, port);
        await (await s1.future).close(1000, 'normal_done_reason');
        await pumpEventQueue();
        await bridge1.dispose();

        final expectedEndpoint = 'ws://127.0.0.1:$port/socket';
        expect(
          logs1.any(
            (l) =>
                l.level == LogLevel.info &&
                l.content ==
                    'Closed id=${c1['id']} endpoint=$expectedEndpoint direction=remote code=1000 reasonPresent=true',
          ),
          isTrue,
        );
        expect(
          logs1.any((l) => l.content.contains('normal_done_reason')),
          isFalse,
        );

        final server2 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final port2 = server2.port;
        try {
          final logs2 = <({LogLevel level, String content})>[];
          final bridge2 = JsWebSocketBridge(
            proxyResolver: () async => null,
            lifecycleLogger: (level, content) =>
                logs2.add((level: level, content: content)),
          );
          final s2 = Completer<WebSocket>();
          unawaited(() async {
            s2.complete(
              await WebSocketTransformer.upgrade(await server2.first),
            );
          }());
          final c2 = await _connect(bridge2, port2);
          await (await s2.future).close(1001, 'going_away_reason');
          await pumpEventQueue();
          await bridge2.dispose();

          final endpoint2 = 'ws://127.0.0.1:$port2/socket';
          expect(
            logs2.any(
              (l) =>
                  l.level == LogLevel.info &&
                  l.content ==
                      'Closed id=${c2['id']} endpoint=$endpoint2 direction=remote code=1001 reasonPresent=true',
            ),
            isTrue,
          );
          expect(
            logs2.any((l) => l.content.contains('going_away_reason')),
            isFalse,
          );
        } finally {
          await server2.close(force: true);
        }

        final server3 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final port3 = server3.port;
        try {
          final logs3 = <({LogLevel level, String content})>[];
          final bridge3 = JsWebSocketBridge(
            proxyResolver: () async => null,
            lifecycleLogger: (level, content) =>
                logs3.add((level: level, content: content)),
          );
          final s3 = Completer<WebSocket>();
          unawaited(() async {
            s3.complete(
              await WebSocketTransformer.upgrade(await server3.first),
            );
          }());
          final c3 = await _connect(bridge3, port3);
          await (await s3.future).close(1002, '');
          await pumpEventQueue();
          await bridge3.dispose();

          final endpoint3 = 'ws://127.0.0.1:$port3/socket';
          expect(
            logs3.any(
              (l) =>
                  l.level == LogLevel.warning &&
                  l.content ==
                      'Closed id=${c3['id']} endpoint=$endpoint3 direction=remote code=1002 reasonPresent=false',
            ),
            isTrue,
          );
        } finally {
          await server3.close(force: true);
        }
      },
    );

    test(
      'local close logs info and only after cleanup completes, exactly once',
      () async {
        final logs = <({LogLevel level, String content})>[];
        final testBridge = JsWebSocketBridge(
          proxyResolver: () async => null,
          lifecycleLogger: (level, content) =>
              logs.add((level: level, content: content)),
        );
        unawaited(() async {
          await for (final req in server) {
            await WebSocketTransformer.upgrade(req);
          }
        }());
        final c = await _connect(testBridge, server.port);
        final expectedEndpoint = 'ws://127.0.0.1:${server.port}/socket';

        await testBridge.handle({
          'function': 'close',
          'id': c['id'],
          'code': 4000,
          'reason': 'app_specific_reason',
        });
        await testBridge.handle({
          'function': 'close',
          'id': c['id'],
          'code': 4000,
          'reason': 'app_specific_reason',
        });
        await pumpEventQueue();

        final closedLogs = logs
            .where((l) => l.content.startsWith('Closed'))
            .toList();
        expect(closedLogs.length, 1);
        expect(closedLogs.first.level, LogLevel.info);
        expect(
          closedLogs.first.content,
          'Closed id=${c['id']} endpoint=$expectedEndpoint direction=local code=4000 reasonPresent=true',
        );
        expect(
          logs.any((l) => l.content.contains('app_specific_reason')),
          isFalse,
        );

        await testBridge.dispose();
      },
    );

    test('local close after remote close logs only remote close', () async {
      final logs = <({LogLevel level, String content})>[];
      final testBridge = JsWebSocketBridge(
        proxyResolver: () async => null,
        lifecycleLogger: (level, content) =>
            logs.add((level: level, content: content)),
      );
      final s = Completer<WebSocket>();
      unawaited(() async {
        s.complete(await WebSocketTransformer.upgrade(await server.first));
      }());
      final c = await _connect(testBridge, server.port);
      await (await s.future).close(1000, 'done');
      await pumpEventQueue();

      await testBridge.handle({
        'function': 'close',
        'id': c['id'],
        'code': 1000,
      });
      await pumpEventQueue();

      final closedLogs = logs
          .where((l) => l.content.startsWith('Closed'))
          .toList();
      expect(closedLogs.length, 1);
      expect(closedLogs.first.content.contains('direction=remote'), isTrue);
      await testBridge.dispose();
    });

    test(
      'dispose logs only if active or connecting nonzero and suppresses per-connection close',
      () async {
        final logs = <({LogLevel level, String content})>[];
        final testBridge = JsWebSocketBridge(
          proxyResolver: () async => null,
          lifecycleLogger: (level, content) =>
              logs.add((level: level, content: content)),
        );
        unawaited(() async {
          await for (final req in server) {
            await WebSocketTransformer.upgrade(req);
          }
        }());
        await _connect(testBridge, server.port);
        await _connect(testBridge, server.port);
        expect(testBridge.debugConnectionCount, 2);

        await testBridge.dispose();

        final disposingLogs = logs
            .where((l) => l.content.startsWith('Disposing'))
            .toList();
        expect(disposingLogs.length, 1);
        expect(disposingLogs.first.level, LogLevel.info);
        expect(disposingLogs.first.content, 'Disposing active=2 connecting=0');

        expect(logs.where((l) => l.content.startsWith('Closed')), isEmpty);

        await testBridge.dispose();
        expect(logs.where((l) => l.content.startsWith('Disposing')).length, 1);
      },
    );

    test(
      'bridge disposed during in-flight connect does not log connect failure',
      () async {
        final logs = <({LogLevel level, String content})>[];
        final connectCompleter = Completer<WebSocket>();
        final testBridge = JsWebSocketBridge(
          proxyResolver: () async => null,
          connector: (_, {protocols, headers, customClient}) =>
              connectCompleter.future,
          lifecycleLogger: (level, content) =>
              logs.add((level: level, content: content)),
        );

        final connectAttempt = testBridge.handle({
          'function': 'connect',
          'url': 'ws://127.0.0.1:${server.port}/socket',
        });

        await pumpEventQueue();
        final disposeFuture = testBridge.dispose();
        connectCompleter.completeError(const SocketException('abort'));
        await expectLater(connectAttempt, throwsA(isA<SocketException>()));
        await disposeFuture;

        expect(
          logs.any((l) => l.content.startsWith('Connect failed')),
          isFalse,
        );
      },
    );

    test(
      'connect failure logs warning with proxy mode, elapsed, and safe error without leaking OS details',
      () async {
        final logs = <({LogLevel level, String content})>[];
        final testBridge = JsWebSocketBridge(
          proxyResolver: () async => null,
          connector: (_, {protocols, headers, customClient}) {
            return Future.error(
              const SocketException(
                'OS Error: Connection refused to internal 10.1.2.3:8080',
                osError: OSError('Connection refused', 111),
              ),
            );
          },
          lifecycleLogger: (level, content) =>
              logs.add((level: level, content: content)),
        );

        await expectLater(
          testBridge.handle({
            'function': 'connect',
            'url': 'ws://127.0.0.1:${server.port}/socket',
          }),
          throwsException,
        );

        expect(logs.length, 2);
        expect(logs[0].level, LogLevel.info);
        expect(
          logs[0].content,
          'Connecting endpoint=ws://127.0.0.1:${server.port}/socket timeout=30000ms',
        );

        final failLog = logs[1];
        expect(failLog.level, LogLevel.warning);
        expect(
          failLog.content.startsWith(
            'Connect failed endpoint=ws://127.0.0.1:${server.port}/socket proxy=direct elapsed=',
          ),
          isTrue,
        );
        expect(failLog.content.endsWith('error=socket failure'), isTrue);
        expect(failLog.content.contains('10.1.2.3'), isFalse);
        expect(failLog.content.contains('OS Error'), isFalse);
      },
    );

    test(
      'receive failure logs Receive failed at warning level with endpoint without double logging closed',
      () async {
        final logs = <({LogLevel level, String content})>[];
        final mockSocket = _MockErrorWebSocket();
        final testBridge = JsWebSocketBridge(
          proxyResolver: () async => null,
          connector: (_, {protocols, headers, customClient}) async =>
              mockSocket,
          lifecycleLogger: (level, content) =>
              logs.add((level: level, content: content)),
        );

        final connected = await _connect(testBridge, server.port);
        final receiveFuture = testBridge.handle({
          'function': 'receive',
          'id': connected['id'],
        });
        final receiveExpectation = expectLater(receiveFuture, throwsException);

        mockSocket.emitError(
          const SocketException(
            'OS Error: Broken pipe to internal 10.9.8.7',
            osError: OSError('Broken pipe', 32),
          ),
        );
        await receiveExpectation;

        final expectedEndpoint = 'ws://127.0.0.1:${server.port}/socket';
        final receiveFailedLogs = logs
            .where((l) => l.content.startsWith('Receive failed'))
            .toList();
        expect(receiveFailedLogs.length, 1);
        expect(receiveFailedLogs.first.level, LogLevel.warning);
        expect(
          receiveFailedLogs.first.content,
          'Receive failed id=${connected['id']} endpoint=$expectedEndpoint error=socket failure',
        );
        expect(logs.any((l) => l.content.contains('10.9.8.7')), isFalse);
        expect(logs.any((l) => l.content.contains('Broken pipe')), isFalse);

        final closedLogs = logs
            .where((l) => l.content.startsWith('Closed'))
            .toList();
        expect(closedLogs, isEmpty);

        await testBridge.dispose();
      },
    );

    test(
      'logger exceptions are completely isolated and never affect networking',
      () async {
        final brokenBridge = JsWebSocketBridge(
          proxyResolver: () async => null,
          lifecycleLogger: (level, content) =>
              throw Exception('Logger blew up!'),
        );

        final serverSocketCompleter = Completer<WebSocket>();
        unawaited(() async {
          final socket = await WebSocketTransformer.upgrade(await server.first);
          serverSocketCompleter.complete(socket);
          await for (final data in socket) {
            socket.add(data);
          }
        }());

        final connected = await _connect(brokenBridge, server.port);
        expect(connected['id'], isNotNull);

        await brokenBridge.handle({
          'function': 'send',
          'id': connected['id'],
          'data': 'resilient-hello',
        });

        final received =
            await brokenBridge.handle({
                  'function': 'receive',
                  'id': connected['id'],
                })
                as Map<String, dynamic>;
        expect(received['data'], 'resilient-hello');

        await brokenBridge.handle({
          'function': 'close',
          'id': connected['id'],
          'code': 1000,
          'reason': 'bye',
        });

        await brokenBridge.dispose();
      },
    );

    test(
      'send and receive message payloads are completely absent from logs',
      () async {
        final logs = <({LogLevel level, String content})>[];
        final testBridge = JsWebSocketBridge(
          proxyResolver: () async => null,
          lifecycleLogger: (level, content) =>
              logs.add((level: level, content: content)),
        );

        unawaited(() async {
          final socket = await WebSocketTransformer.upgrade(await server.first);
          await for (final data in socket) {
            socket.add(data);
          }
        }());

        final connected = await _connect(testBridge, server.port);

        const secretText = 'confidential_user_payload_string_48123';
        await testBridge.handle({
          'function': 'send',
          'id': connected['id'],
          'data': secretText,
        });

        final receivedText =
            await testBridge.handle({
                  'function': 'receive',
                  'id': connected['id'],
                })
                as Map<String, dynamic>;
        expect(receivedText['data'], secretText);

        final secretBytes = [99, 100, 101, 102];
        await testBridge.handle({
          'function': 'send',
          'id': connected['id'],
          'data': secretBytes,
        });

        final receivedBytes =
            await testBridge.handle({
                  'function': 'receive',
                  'id': connected['id'],
                })
                as Map<String, dynamic>;
        expect(receivedBytes['data'], Uint8List.fromList(secretBytes));

        await testBridge.handle({'function': 'close', 'id': connected['id']});
        await testBridge.dispose();

        for (final log in logs) {
          expect(log.content.contains(secretText), isFalse);
          expect(log.content.contains('99'), isFalse);
          expect(log.content.contains('payload'), isFalse);
          expect(log.content.contains('message'), isFalse);
        }
      },
    );
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

class _MockErrorWebSocket extends Stream<dynamic> implements WebSocket {
  final _controller = StreamController<dynamic>();

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  void emitError(Object error) => _controller.addError(error);

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => '';

  @override
  Future close([int? code, String? reason]) => _controller.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
