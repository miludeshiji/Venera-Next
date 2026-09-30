import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/app_dio.dart';
import 'package:venera_next/network/webdav.dart';

void main() {
  late bool wasInitialized;
  late bool wasMuted;

  setUp(() {
    wasInitialized = App.isInitialized;
    wasMuted = Log.isMuted;
    App.isInitialized = false;
    Log.isMuted = false;
    Log.clear();
  });

  tearDown(() {
    Log.clear();
    Log.isMuted = wasMuted;
    App.isInitialized = wasInitialized;
  });

  test('records directory 404 before the WebDAV SDK throws', () async {
    final client = WebDavEndpoint(
      url: 'https://example.com/dav/VeneraNext',
      user: 'account-secret',
      password: 'password-secret',
    ).createClient(logRequests: true);
    client.c.httpClientAdapter = _DiagnosticAdapter(
      response: ResponseBody.fromString('body-secret', 404),
    );
    addTearDown(() => client.c.close(force: true));

    await expectLater(
      client.readDir('/'),
      throwsA(
        isA<DioException>().having(
          (error) => error.response?.statusCode,
          'status',
          404,
        ),
      ),
    );

    final entries = Log.logs.where((entry) => entry.title == 'WebDAV').toList();
    expect(entries, hasLength(2));
    expect(
      entries.first.content,
      contains('Request: PROPFIND https://example.com/dav/VeneraNext/'),
    );
    expect(entries.first.content, contains('Platform:'));
    expect(entries.first.content, contains('App: ${App.version}'));
    expect(
      entries.last.content,
      contains('Response to: PROPFIND https://example.com/dav/VeneraNext/'),
    );
    expect(entries.last.content, contains('HTTP status: 404'));
    expect(
      entries.map((entry) => entry.content).join(),
      isNot(contains('secret')),
    );
  });

  test('redacts URL secrets and payloads without modifying traffic', () async {
    final client = WebDavEndpoint(
      url: 'https://example.com/dav/',
      user: '',
      password: '',
    ).createClient(logRequests: true);
    final adapter = _DiagnosticAdapter(
      response: ResponseBody.fromString(
        'response-secret',
        302,
        headers: {
          'location': [
            'https://redirect-user:redirect-pass@example.org/Remote/VeneraNext'
                '?token=redirect-query#redirect-fragment',
          ],
          'set-cookie': ['cookie-secret'],
        },
      ),
    );
    client.c.httpClientAdapter = adapter;
    addTearDown(() => client.c.close(force: true));
    const url =
        'https://url-user:url-pass@example.com/dav/VeneraNext/%E4%B9%A6'
        '?token=query-secret#fragment-secret';
    final response = await client.c.request<String>(
      url,
      data: 'body-secret',
      options: Options(
        method: 'PUT',
        headers: {'Authorization': 'auth-secret'},
      ),
    );

    final log = Log.logs.map((entry) => entry.content).join('\n');
    expect(log, contains('PUT https://example.com/dav/VeneraNext/%E4%B9%A6'));
    expect(log, contains('Location: https://example.org/Remote/VeneraNext'));
    for (final secret in [
      'url-user',
      'url-pass',
      'query-secret',
      'fragment-secret',
      'body-secret',
      'auth-secret',
      'response-secret',
      'cookie-secret',
      'redirect-user',
      'redirect-pass',
      'redirect-query',
      'redirect-fragment',
    ]) {
      expect(log, isNot(contains(secret)), reason: secret);
    }
    expect(adapter.request!.uri.toString(), url);
    expect(adapter.request!.headers['Authorization'], 'auth-secret');
    expect(adapter.request!.data, 'body-secret');
    expect(response.statusCode, 302);
    expect(response.data, 'response-secret');
    expect(response.headers['location']!.single, contains('redirect-query'));
  });

  test(
    'records transport failure without logging raw exception secrets',
    () async {
      final client = WebDavEndpoint(
        url: 'https://example.com/dav/VeneraNext',
        user: '',
        password: '',
      ).createClient(logRequests: true);
      client.c.httpClientAdapter = _DiagnosticAdapter(fail: true);
      addTearDown(() => client.c.close(force: true));

      await expectLater(client.readDir('/'), throwsA(isA<DioException>()));

      final log = Log.logs.map((entry) => entry.content).join('\n');
      expect(
        log,
        contains(
          'Request failed: PROPFIND https://example.com/dav/VeneraNext/',
        ),
      );
      expect(log, contains('Error type: connectionError'));
      expect(log, isNot(contains('exception-secret')));
    },
  );

  test(
    'invalid URLs fail without breaking the diagnostic interceptor',
    () async {
      final client = WebDavEndpoint(
        url: 'https://[invalid-secret',
        user: '',
        password: '',
      ).createClient(logRequests: true);
      client.c.httpClientAdapter = _DiagnosticAdapter(fail: true);
      addTearDown(() => client.c.close(force: true));

      await expectLater(
        client.c.request(
          'https://[invalid-secret',
          options: Options(method: 'PROPFIND'),
        ),
        throwsA(isA<DioException>()),
      );

      final log = Log.logs.map((entry) => entry.content).join('\n');
      expect(log, contains('[invalid URL]'));
      expect(log, isNot(contains('invalid-secret')));
    },
  );

  test('request diagnostics are opt-in for other WebDAV consumers', () async {
    final client = WebDavEndpoint(
      url: 'https://example.com/dav/VeneraNext',
      user: '',
      password: '',
    ).createClient();
    client.c.httpClientAdapter = _DiagnosticAdapter(
      response: ResponseBody.fromString('', 200),
    );
    addTearDown(() => client.c.close(force: true));

    await client.ping();

    expect(Log.logs, isEmpty);
  });
}

class _DiagnosticAdapter implements HttpClientAdapter {
  _DiagnosticAdapter({this.response, this.fail = false});

  final ResponseBody? response;
  final bool fail;
  RequestOptions? request;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    await requestStream?.drain<void>();
    if (fail) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        message: 'exception-secret',
      );
    }
    return response!;
  }

  @override
  void close({bool force = false}) {}
}
