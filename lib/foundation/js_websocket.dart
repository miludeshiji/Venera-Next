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

class JsWebSocketBridge {
  JsWebSocketBridge({
    JsWebSocketConnector? connector,
    JsWebSocketProxyResolver? proxyResolver,
    JsWebSocketClientFactory? clientFactory,
  }) : _connector = connector ?? WebSocket.connect,
       _proxyResolver = proxyResolver ?? getProxy,
       _clientFactory = clientFactory ?? HttpClient.new;

  final JsWebSocketConnector _connector;
  final JsWebSocketProxyResolver _proxyResolver;
  final JsWebSocketClientFactory _clientFactory;
  final Map<int, _JsWebSocketConnection> _connections = {};
  final Set<int> _closedConnectionIds = {};
  final Set<HttpClient> _connectingClients = {};
  int _nextId = 1;
  bool _disposed = false;

  @visibleForTesting
  int get debugConnectionCount => _connections.length;

  Future<Object?> handle(Map<String, dynamic> message) async {
    if (_disposed) {
      throw StateError('WebSocket Bridge Disposed');
    }
    switch (message['function']) {
      case 'connect':
        return await _connect(message);
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
    try {
      final proxy = await _proxyResolver().timeout(timeout);
      if (_disposed) {
        throw StateError('WebSocket Bridge Disposed');
      }
      client.findProxy = (_) => proxy == null ? 'DIRECT' : 'PROXY $proxy';
      client.connectionTimeout = timeout;
      final socket = await _connector(
        url,
        protocols: protocols,
        headers: headers,
        customClient: client,
      ).timeout(timeout);
      if (_disposed) {
        await socket.close(WebSocketStatus.goingAway, 'Bridge disposed');
        throw StateError('WebSocket Bridge Disposed');
      }
      final id = _nextId++;
      late final _JsWebSocketConnection connection;
      connection = _JsWebSocketConnection(
        id: id,
        socket: socket,
        client: client,
        onTerminated: () {
          _connections.remove(id);
          _closedConnectionIds.add(id);
        },
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
    final connection = _getConnection(message['id']);
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
    final connection = _getConnection(message['id']);
    try {
      return await connection.receive();
    } on StateError {
      rethrow;
    } catch (error) {
      throw Exception('WebSocket Receive Error: ${_safeError(error)}');
    }
  }

  Future<void> _close(Map<String, dynamic> message) async {
    final id = _parseId(message['id']);
    final connection = _connections[id];
    if (connection == null) {
      if (_closedConnectionIds.contains(id)) return;
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
    _connections.remove(id);
    _closedConnectionIds.add(id);
  }

  _JsWebSocketConnection _getConnection(Object? rawId) {
    final id = _parseId(rawId);
    final connection = _connections[id];
    if (connection != null) return connection;
    if (_closedConnectionIds.contains(id)) {
      throw StateError('WebSocket Closed Connection: $id');
    }
    throw StateError('WebSocket Unknown Connection ID: $id');
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
    _connectingClients.clear();
    final connections = _connections.values.toList(growable: false);
    _connections.clear();
    await Future.wait(connections.map((connection) => connection.dispose()));
    _closedConnectionIds.clear();
  }
}

class _JsWebSocketConnection {
  _JsWebSocketConnection({
    required this.id,
    required this.socket,
    required this.client,
    required this.onTerminated,
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
  final void Function() onTerminated;
  final Queue<Map<String, dynamic>> _events = Queue();
  late final StreamSubscription<dynamic> _subscription;
  Completer<Map<String, dynamic>>? _waitingReceiver;
  bool _closed = false;
  bool _disposed = false;
  bool _closeDelivered = false;
  Future<void>? _closeFuture;

  void send(Object data) {
    if (_closed || _disposed || socket.readyState != WebSocket.open) {
      throw StateError('WebSocket Closed Connection: $id');
    }
    socket.add(data);
  }

  Future<Map<String, dynamic>> receive() {
    if (_events.isNotEmpty) {
      final event = _events.removeFirst();
      _afterEventDelivered(event);
      if (!_closed && !_disposed) {
        _subscription.resume();
      }
      return Future.value(event);
    }
    if (_closed || _disposed) {
      throw StateError('WebSocket Closed Connection: $id');
    }
    if (_waitingReceiver != null) {
      throw StateError('Only one WebSocket receiver is allowed');
    }
    _subscription.resume();
    final completer = Completer<Map<String, dynamic>>();
    _waitingReceiver = completer;
    return completer.future;
  }

  void _onMessage(dynamic data) {
    if (_closed || _disposed) return;
    final normalized = data is List<int> && data is! Uint8List
        ? Uint8List.fromList(data)
        : data;
    _emit({'type': 'message', 'data': normalized});
  }

  void _onError(Object error, StackTrace stackTrace) {
    if (_disposed) return;
    _closed = true;
    final receiver = _waitingReceiver;
    _waitingReceiver = null;
    if (receiver != null && !receiver.isCompleted) {
      receiver.completeError(
        Exception('WebSocket Receive Error: ${_safeError(error)}'),
        stackTrace,
      );
    }
    unawaited(_release(removeFromRegistry: true));
  }

  void _onDone() {
    if (_disposed || _closeDelivered) return;
    _closed = true;
    _emit({
      'type': 'close',
      'code': socket.closeCode,
      'reason': socket.closeReason ?? '',
    });
    unawaited(_release(removeFromRegistry: false));
  }

  void _emit(Map<String, dynamic> event) {
    final receiver = _waitingReceiver;
    if (receiver != null) {
      _waitingReceiver = null;
      if (!receiver.isCompleted) receiver.complete(event);
      _afterEventDelivered(event);
    } else {
      _events.add(event);
      _subscription.pause();
    }
  }

  void _afterEventDelivered(Map<String, dynamic> event) {
    if (event['type'] == 'close') {
      _closeDelivered = true;
      onTerminated();
    }
  }

  Future<void> close(int code, String reason) {
    return _closeFuture ??= _close(code, reason);
  }

  Future<void> _close(int code, String reason) async {
    if (_disposed) return;
    _closed = true;
    final receiver = _waitingReceiver;
    _waitingReceiver = null;
    if (receiver != null && !receiver.isCompleted) {
      receiver.completeError(StateError('WebSocket Closed Connection: $id'));
    }
    try {
      await socket.close(code, reason);
    } finally {
      await _release(removeFromRegistry: false);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _closed = true;
    final receiver = _waitingReceiver;
    _waitingReceiver = null;
    if (receiver != null && !receiver.isCompleted) {
      receiver.completeError(StateError('WebSocket Bridge Disposed'));
    }
    try {
      await socket.close(WebSocketStatus.goingAway, 'Bridge disposed');
    } finally {
      await _release(removeFromRegistry: false);
    }
  }

  Future<void> _release({required bool removeFromRegistry}) async {
    try {
      await _subscription.cancel();
    } finally {
      client.close(force: true);
      if (removeFromRegistry) onTerminated();
    }
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
