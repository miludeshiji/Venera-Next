import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:venera_next/network/proxy.dart';

typedef JsWebSocketConnector =
    Future<WebSocket> Function(
      String url, {
      Iterable<String>? protocols,
      Map<String, dynamic>? headers,
      HttpClient? customClient,
    });
typedef JsWebSocketProxyResolver = Future<String?> Function();
typedef JsWebSocketClientFactory = HttpClient Function();
typedef JsWebSocketProxyApplied = void Function(String directive);

class JsWebSocketBridge {
  JsWebSocketBridge({
    JsWebSocketConnector? connector,
    JsWebSocketProxyResolver? proxyResolver,
    JsWebSocketClientFactory? clientFactory,
    JsWebSocketProxyApplied? onProxyApplied,
    Duration terminalStateTtl = const Duration(minutes: 1),
    int maxTerminalStates = 128,
    Duration closeTimeout = const Duration(seconds: 2),
  }) : _connector = connector ?? WebSocket.connect,
       _proxyResolver = proxyResolver ?? getProxy,
       _clientFactory = clientFactory ?? HttpClient.new,
       _onProxyApplied = onProxyApplied,
       _terminalStateTtl = terminalStateTtl,
       _maxTerminalStates = maxTerminalStates,
       _closeTimeout = closeTimeout {
    if (terminalStateTtl <= Duration.zero) {
      throw ArgumentError.value(terminalStateTtl, 'terminalStateTtl');
    }
    if (maxTerminalStates <= 0) {
      throw ArgumentError.value(maxTerminalStates, 'maxTerminalStates');
    }
    if (closeTimeout <= Duration.zero) {
      throw ArgumentError.value(closeTimeout, 'closeTimeout');
    }
  }

  final JsWebSocketConnector _connector;
  final JsWebSocketProxyResolver _proxyResolver;
  final JsWebSocketClientFactory _clientFactory;
  final JsWebSocketProxyApplied? _onProxyApplied;
  final Duration _terminalStateTtl;
  final int _maxTerminalStates;
  final Duration _closeTimeout;
  final Map<int, _JsWebSocketConnection> _connections = {};
  final LinkedHashMap<int, _JsWebSocketTerminalState> _terminalStates =
      LinkedHashMap();
  final Set<HttpClient> _connectingClients = {};
  final Set<Future<void>> _connectingAttempts = {};
  int _nextId = 1;
  bool _disposed = false;

  @visibleForTesting
  int get debugConnectionCount => _connections.length;

  @visibleForTesting
  int get debugTerminalStateCount {
    _purgeExpiredTerminalStates();
    return _terminalStates.length;
  }

  Future<Object?> handle(Map<String, dynamic> message) async {
    if (_disposed) throw StateError('WebSocket Bridge Disposed');
    _purgeExpiredTerminalStates();
    switch (message['function']) {
      case 'connect':
        final attempt = _connect(message);
        final settled = attempt.then<void>((_) {}, onError: (_) {});
        _connectingAttempts.add(settled);
        unawaited(
          settled.whenComplete(() => _connectingAttempts.remove(settled)),
        );
        return await attempt;
      case 'send':
        await _send(message);
        return null;
      case 'receive':
        return await _receive(message);
      case 'close':
        await _close(message);
        return null;
      default:
        throw ArgumentError('WebSocket Invalid Argument: function');
    }
  }

  Future<Map<String, dynamic>> _connect(Map<String, dynamic> message) async {
    final url = message['url'];
    if (url is! String) {
      throw ArgumentError('WebSocket Invalid Argument: url must be a string');
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'ws' && uri.scheme != 'wss')) {
      throw ArgumentError('WebSocket Invalid Argument: url must use ws or wss');
    }
    final headers = _parseHeaders(message['headers']);
    final protocols = _parseProtocols(message['protocols']);
    final timeoutMs = message['connectTimeoutMs'] ?? 30000;
    if (timeoutMs is! int || timeoutMs <= 0) {
      throw ArgumentError(
        'WebSocket Invalid Argument: connectTimeoutMs must be a positive integer',
      );
    }

    final client = _clientFactory();
    _connectingClients.add(client);
    final timeout = Duration(milliseconds: timeoutMs);
    final stopwatch = Stopwatch()..start();
    try {
      final proxy = await _proxyResolver().timeout(timeout);
      if (_disposed) throw StateError('WebSocket Bridge Disposed');
      final remaining = timeout - stopwatch.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('WebSocket connection timed out');
      }
      final proxyDirective = proxy == null ? 'DIRECT' : 'PROXY $proxy';
      client.findProxy = (_) => proxyDirective;
      _onProxyApplied?.call(proxyDirective);
      client.connectionTimeout = remaining;
      final socket = await _connector(
        url,
        protocols: protocols,
        headers: headers,
        customClient: client,
      ).timeout(remaining);
      if (_disposed) {
        await _boundedSocketClose(
          socket,
          WebSocketStatus.goingAway,
          'Bridge disposed',
        );
        throw StateError('WebSocket Bridge Disposed');
      }
      final id = _nextId++;
      final connection = _JsWebSocketConnection(
        id: id,
        socket: socket,
        client: client,
        closeTimeout: _closeTimeout,
        onTerminal: (terminal) => _recordTerminalState(id, terminal),
      );
      _connections[id] = connection;
      return {'id': id, 'protocol': socket.protocol ?? ''};
    } catch (error) {
      client.close(force: true);
      if (error is ArgumentError ||
          error is StateError && error.message == 'WebSocket Bridge Disposed') {
        rethrow;
      }
      throw Exception('WebSocket Connect Error: ${_safeError(error)}');
    } finally {
      _connectingClients.remove(client);
    }
  }

  Future<void> _send(Map<String, dynamic> message) async {
    final connection = _activeConnection(message['id']);
    final data = message['data'];
    Object payload;
    if (data is String) {
      payload = data;
    } else if (data is Uint8List) {
      payload = data;
    } else if (data is List &&
        data.every((value) => value is int && value >= 0 && value <= 255)) {
      payload = Uint8List.fromList(data.cast<int>());
    } else {
      throw ArgumentError(
        'WebSocket Invalid Argument: data must be a string or byte array',
      );
    }
    try {
      connection.send(payload);
    } on StateError {
      rethrow;
    } catch (error) {
      throw Exception('WebSocket Send Error: ${_safeError(error)}');
    }
  }

  Future<Map<String, dynamic>> _receive(Map<String, dynamic> message) async {
    final id = _parseId(message['id']);
    final connection = _connections[id];
    if (connection != null) {
      try {
        return await connection.receive();
      } on StateError {
        rethrow;
      } catch (error) {
        throw Exception('WebSocket Receive Error: ${_safeError(error)}');
      }
    }
    final terminal = _terminalStates[id];
    if (terminal != null) {
      if (terminal.closeEvent != null) {
        final event = Map<String, dynamic>.from(terminal.closeEvent!);
        terminal.closeEvent = null;
        return event;
      }
      _terminalStates.remove(id);
      throw StateError('WebSocket Closed Connection: $id');
    }
    throw StateError('WebSocket Unknown Connection ID: $id');
  }

  Future<void> _close(Map<String, dynamic> message) async {
    final id = _parseId(message['id']);
    final connection = _connections[id];
    if (connection == null) {
      if (_terminalStates.containsKey(id)) return;
      throw StateError('WebSocket Unknown Connection ID: $id');
    }
    final code = message['code'] ?? WebSocketStatus.normalClosure;
    final reason = message['reason'] ?? '';
    if (code is! int || !_isValidCloseCode(code)) {
      throw ArgumentError('WebSocket Invalid Argument: invalid close code');
    }
    if (reason is! String) {
      throw ArgumentError(
        'WebSocket Invalid Argument: reason must be a string',
      );
    }
    if (utf8.encode(reason).length > 123) {
      throw ArgumentError(
        'WebSocket Invalid Argument: close reason is too long',
      );
    }
    await connection.close(code, reason);
  }

  _JsWebSocketConnection _activeConnection(Object? rawId) {
    final id = _parseId(rawId);
    final connection = _connections[id];
    if (connection != null) return connection;
    if (_terminalStates.containsKey(id)) {
      throw StateError('WebSocket Closed Connection: $id');
    }
    throw StateError('WebSocket Unknown Connection ID: $id');
  }

  void _recordTerminalState(int id, _JsWebSocketTerminalState terminal) {
    if (_connections.remove(id) == null || _disposed) return;
    _terminalStates.remove(id);
    _terminalStates[id] = terminal;
    _purgeExpiredTerminalStates();
    while (_terminalStates.length > _maxTerminalStates) {
      _terminalStates.remove(_terminalStates.keys.first);
    }
  }

  void _purgeExpiredTerminalStates() {
    final cutoff = DateTime.now().subtract(_terminalStateTtl);
    while (_terminalStates.isNotEmpty &&
        !_terminalStates.values.first.createdAt.isAfter(cutoff)) {
      _terminalStates.remove(_terminalStates.keys.first);
    }
  }

  int _parseId(Object? value) {
    if (value is! int || value <= 0) {
      throw ArgumentError(
        'WebSocket Invalid Argument: id must be a positive integer',
      );
    }
    return value;
  }

  Map<String, dynamic> _parseHeaders(Object? value) {
    if (value == null) return {};
    if (value is! Map) {
      throw ArgumentError(
        'WebSocket Invalid Argument: headers must be an object',
      );
    }
    final result = <String, dynamic>{};
    for (final entry in value.entries) {
      if (entry.key is! String ||
          entry.value is! String &&
              !(entry.value is List &&
                  entry.value.every((item) => item is String))) {
        throw ArgumentError(
          'WebSocket Invalid Argument: headers must contain string values',
        );
      }
      result[entry.key as String] = entry.value;
    }
    return result;
  }

  List<String> _parseProtocols(Object? value) {
    if (value == null) return const [];
    if (value is! List || value.any((item) => item is! String)) {
      throw ArgumentError(
        'WebSocket Invalid Argument: protocols must be a string array',
      );
    }
    return value.cast<String>();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final client in _connectingClients.toList(growable: false)) {
      client.close(force: true);
    }
    if (_connectingAttempts.isNotEmpty) {
      await Future.wait(_connectingAttempts.toList(growable: false));
    }
    _connectingClients.clear();
    final connections = _connections.values.toList(growable: false);
    _connections.clear();
    await Future.wait(connections.map((connection) => connection.dispose()));
    _terminalStates.clear();
  }
}

class _JsWebSocketTerminalState {
  _JsWebSocketTerminalState({this.closeEvent}) : createdAt = DateTime.now();

  Map<String, dynamic>? closeEvent;
  final DateTime createdAt;
}

class _JsWebSocketConnection {
  _JsWebSocketConnection({
    required this.id,
    required this.socket,
    required this.client,
    required this.closeTimeout,
    required this.onTerminal,
  }) {
    _subscription = socket.listen(
      _onMessage,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: false,
    );
  }

  final int id;
  final WebSocket socket;
  final HttpClient client;
  final Duration closeTimeout;
  final void Function(_JsWebSocketTerminalState terminal) onTerminal;
  final Queue<Map<String, dynamic>> _events = Queue();
  late final StreamSubscription<dynamic> _subscription;
  Completer<Map<String, dynamic>>? _waitingReceiver;
  bool _terminated = false;
  Future<void>? _releaseFuture;
  Future<void>? _closeFuture;

  void send(Object data) {
    if (_terminated || socket.readyState != WebSocket.open) {
      throw StateError('WebSocket Closed Connection: $id');
    }
    socket.add(data);
  }

  Future<Map<String, dynamic>> receive() {
    if (_events.isNotEmpty) {
      final event = _events.removeFirst();
      if (!_terminated) _subscription.resume();
      return Future.value(event);
    }
    if (_terminated) throw StateError('WebSocket Closed Connection: $id');
    if (_waitingReceiver != null) {
      throw StateError('Only one WebSocket receiver is allowed');
    }
    _subscription.resume();
    final completer = Completer<Map<String, dynamic>>();
    _waitingReceiver = completer;
    return completer.future;
  }

  void _onMessage(dynamic data) {
    if (_terminated) return;
    final normalized = data is List<int> && data is! Uint8List
        ? Uint8List.fromList(data)
        : data;
    final event = <String, dynamic>{'type': 'message', 'data': normalized};
    final receiver = _waitingReceiver;
    if (receiver != null) {
      _waitingReceiver = null;
      receiver.complete(event);
    } else {
      _events.add(event);
      _subscription.pause();
    }
  }

  void _onError(Object error, StackTrace stackTrace) {
    unawaited(
      _terminate(
        error: Exception('WebSocket Receive Error: ${_safeError(error)}'),
        stackTrace: stackTrace,
      ),
    );
  }

  void _onDone() {
    unawaited(
      _terminate(
        closeEvent: {
          'type': 'close',
          'code': socket.closeCode,
          'reason': socket.closeReason ?? '',
        },
      ),
    );
  }

  Future<void> close(int code, String reason) {
    return _closeFuture ??= _close(code, reason);
  }

  Future<void> _close(int code, String reason) async {
    if (_terminated) return;
    final receiver = _waitingReceiver;
    _waitingReceiver = null;
    receiver?.completeError(StateError('WebSocket Closed Connection: $id'));
    await _terminate(closeSocket: true, closeCode: code, closeReason: reason);
  }

  Future<void> dispose() async {
    if (_terminated) return _release();
    final receiver = _waitingReceiver;
    _waitingReceiver = null;
    receiver?.completeError(StateError('WebSocket Bridge Disposed'));
    await _terminate(
      closeSocket: true,
      closeCode: WebSocketStatus.goingAway,
      closeReason: 'Bridge disposed',
      recordTerminal: false,
    );
  }

  Future<void> _terminate({
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? closeEvent,
    bool closeSocket = false,
    int? closeCode,
    String? closeReason,
    bool recordTerminal = true,
  }) async {
    if (_terminated) return _release();
    _terminated = true;
    final receiver = _waitingReceiver;
    _waitingReceiver = null;
    Map<String, dynamic>? terminalCloseEvent = closeEvent;
    if (error != null) {
      receiver?.completeError(error, stackTrace);
    } else if (closeEvent != null) {
      if (receiver != null) {
        receiver.complete(closeEvent);
        terminalCloseEvent = null;
      }
    }
    _events.clear();
    if (recordTerminal) {
      onTerminal(_JsWebSocketTerminalState(closeEvent: terminalCloseEvent));
    }
    try {
      if (closeSocket) {
        await _boundedSocketClose(
          socket,
          closeCode ?? WebSocketStatus.normalClosure,
          closeReason ?? '',
          timeout: closeTimeout,
        );
      }
    } finally {
      await _release();
    }
  }

  Future<void> _release() => _releaseFuture ??= _doRelease();

  Future<void> _doRelease() async {
    try {
      await _subscription.cancel();
    } finally {
      client.close(force: true);
    }
  }
}

Future<void> _boundedSocketClose(
  WebSocket socket,
  int code,
  String reason, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  try {
    await socket.close(code, reason).timeout(timeout);
  } catch (_) {
    // The owning HttpClient is force-closed by the caller's release path.
  }
}

bool _isValidCloseCode(int code) {
  return code == WebSocketStatus.normalClosure ||
      code == WebSocketStatus.goingAway ||
      code == WebSocketStatus.protocolError ||
      code == WebSocketStatus.unsupportedData ||
      code == WebSocketStatus.invalidFramePayloadData ||
      code == WebSocketStatus.policyViolation ||
      code == WebSocketStatus.messageTooBig ||
      code == WebSocketStatus.missingMandatoryExtension ||
      code == WebSocketStatus.internalServerError ||
      code >= 3000 && code <= 4999;
}

String _safeError(Object error) {
  if (error is TimeoutException) return 'connection timed out';
  if (error is SocketException) {
    return error.osError?.message ?? 'socket failure';
  }
  if (error is WebSocketException) {
    return error.httpStatusCode == null
        ? 'websocket handshake failed'
        : 'websocket handshake failed (HTTP ${error.httpStatusCode})';
  }
  return error.runtimeType.toString();
}
