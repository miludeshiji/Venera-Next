import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/app_dio.dart';

class _TestRequestHandler extends RequestInterceptorHandler {
  RequestOptions? result;

  @override
  void next(RequestOptions requestOptions) {
    result = requestOptions;
  }
}

class _TestResponseHandler extends ResponseInterceptorHandler {
  Response? result;

  @override
  void next(Response response) {
    result = response;
  }
}

class _TestErrorHandler extends ErrorInterceptorHandler {
  DioException? result;

  @override
  void next(DioException err) {
    result = err;
  }
}

void main() {
  late MyLogInterceptor interceptor;

  setUp(() {
    Log.clear();
    interceptor = MyLogInterceptor();
  });

  tearDown(() {
    Log.clear();
  });

  group('MyLogInterceptor - onRequest', () {
    test('masks sensitive headers by default in various cases', () {
      final handler = _TestRequestHandler();
      final options = RequestOptions(
        path: '/api/v1/profile',
        headers: {
          'Authorization': 'Bearer eyJhbGciOiJIUzI1Ni...',
          'PROXY-AUTHORIZATION': 'Basic secret',
          'Cookie': 'session=xyz',
          'x-id': 'device-123',
          'X-API-KEY': 'api-key-999',
          'x-access-token': 'secret-lowercase',
          'User-Agent': 'VeneraNext/2.0',
          'Accept': 'application/json',
        },
      );

      interceptor.onRequest(options, handler);

      expect(handler.result, isNotNull);
      // Ensure original RequestOptions headers are not mutated
      expect(options.headers['Authorization'], 'Bearer eyJhbGciOiJIUzI1Ni...');
      expect(options.headers['x-access-token'], 'secret-lowercase');

      final logContent = Log.logs.last.content;
      expect(logContent, contains('Authorization: <redacted>'));
      expect(logContent, contains('PROXY-AUTHORIZATION: <redacted>'));
      expect(logContent, contains('Cookie: <redacted>'));
      expect(logContent, contains('x-id: <redacted>'));
      expect(logContent, contains('X-API-KEY: <redacted>'));
      expect(logContent, contains('x-access-token: <redacted>'));
      expect(logContent, contains('User-Agent: VeneraNext/2.0'));
      expect(logContent, contains('Accept: application/json'));
      expect(logContent, isNot(contains('secret-lowercase')));
    });

    test('supports extra maskHeadersInLog combined with default masks', () {
      final handler = _TestRequestHandler();
      final options = RequestOptions(
        path: '/api/custom',
        headers: {
          'Authorization': 'Bearer secret',
          'X-Custom-Secret': 'custom-value-123',
          'X-Safe-Header': 'safe-value',
        },
        extra: {
          'maskHeadersInLog': ['x-custom-secret'],
        },
      );

      interceptor.onRequest(options, handler);

      final logContent = Log.logs.last.content;
      expect(logContent, contains('Authorization: <redacted>'));
      expect(logContent, contains('X-Custom-Secret: <redacted>'));
      expect(logContent, contains('X-Safe-Header: safe-value'));
      expect(logContent, isNot(contains('custom-value-123')));
    });

    test('maskHeadersInLog string value does not break request', () {
      final handler = _TestRequestHandler();
      final options = RequestOptions(
        path: '/api/string-header-mask',
        headers: {'X-Custom-Secret': 'custom-val'},
        extra: {'maskHeadersInLog': 'X-Custom-Secret'},
      );

      expect(() => interceptor.onRequest(options, handler), returnsNormally);

      final logContent = Log.logs.last.content;
      expect(logContent, contains('X-Custom-Secret: <redacted>'));
      expect(logContent, isNot(contains('custom-val')));
    });

    test(
      'recursively redacts sensitive JSON data keys at root and nested levels',
      () {
        final handler = _TestRequestHandler();
        final data = {
          'token': 'secret-token',
          'refresh_token': 'secret-refresh',
          'password': 'my-password',
          'user': {
            'name': 'alice',
            'client_secret': 'sub-secret',
            'session_id': 'sess-456',
          },
          'items': [
            {'id': 1, 'token': 'item-token'},
            {'id': 2, 'title': 'regular item'},
          ],
          'version': '1.0.0',
        };
        final options = RequestOptions(path: '/api/login', data: data);

        interceptor.onRequest(options, handler);

        // Ensure original data is not mutated
        expect(data['token'], 'secret-token');

        final logContent = Log.logs.last.content;
        expect(logContent, contains('token: <redacted>'));
        expect(logContent, contains('refresh_token: <redacted>'));
        expect(logContent, contains('password: <redacted>'));
        expect(logContent, contains('client_secret: <redacted>'));
        expect(logContent, contains('session_id: <redacted>'));
        expect(logContent, contains('name: alice'));
        expect(logContent, contains('title: regular item'));
        expect(logContent, contains('version: 1.0.0'));
        expect(logContent, isNot(contains('secret-token')));
        expect(logContent, isNot(contains('my-password')));
      },
    );

    test('redacts api key variants in request body', () {
      final handler = _TestRequestHandler();
      final options = RequestOptions(
        path: '/api/v1/auth',
        data: {
          'api_key': 'secret-1',
          'apiKey': 'secret-2',
          'apikey': 'secret-3',
          'x-api-key': 'secret-4',
          'x_api_key': 'secret-5',
        },
      );

      interceptor.onRequest(options, handler);

      final logContent = Log.logs.last.content;
      expect(logContent, contains('api_key: <redacted>'));
      expect(logContent, contains('apiKey: <redacted>'));
      expect(logContent, contains('apikey: <redacted>'));
      expect(logContent, contains('x-api-key: <redacted>'));
      expect(logContent, contains('x_api_key: <redacted>'));
      expect(logContent, isNot(contains('secret-1')));
      expect(logContent, isNot(contains('secret-2')));
      expect(logContent, isNot(contains('secret-3')));
      expect(logContent, isNot(contains('secret-4')));
      expect(logContent, isNot(contains('secret-5')));
    });

    test('redacts JSON encoded string body', () {
      final handler = _TestRequestHandler();
      final rawJson = jsonEncode({'token': 'raw-token-123', 'page': 5});
      final options = RequestOptions(path: '/api/token', data: rawJson);

      interceptor.onRequest(options, handler);

      final logContent = Log.logs.last.content;
      expect(logContent, contains('"token":"<redacted>"'));
      expect(logContent, contains('"page":5'));
      expect(logContent, isNot(contains('raw-token-123')));
    });

    test('maskDataInLog hides request data completely', () {
      final handler = _TestRequestHandler();
      final options = RequestOptions(
        path: '/api/data',
        data: {'anything': 'here'},
        extra: {'maskDataInLog': true},
      );

      interceptor.onRequest(options, handler);

      final logContent = Log.logs.last.content;
      expect(logContent, contains('data:\n<redacted>'));
      expect(logContent, isNot(contains('anything')));
    });

    test(
      'redacts sensitive query parameters while keeping normal params and connection id',
      () {
        final handler = _TestRequestHandler();
        final options = RequestOptions(
          path: 'https://example.com/hub/api',
          queryParameters: {
            'id': 'cXTkuWL94XFkD6ZqQWgNag',
            'access_token': 'secret-token-query',
            'page': '3',
            'api_key': 'key-456',
          },
        );

        interceptor.onRequest(options, handler);

        final logContent = Log.logs.last.content;
        expect(logContent, contains('id=cXTkuWL94XFkD6ZqQWgNag'));
        expect(logContent, contains('page=3'));
        expect(logContent, contains('access_token=%3Credacted%3E'));
        expect(logContent, contains('api_key=%3Credacted%3E'));
        expect(logContent, isNot(contains('secret-token-query')));
        expect(logContent, isNot(contains('key-456')));
      },
    );

    test('redacts password, secret, and session query parameters', () {
      final handler = _TestRequestHandler();
      final options = RequestOptions(
        path: 'https://example.com/api',
        queryParameters: {
          'password': 'secret-pwd',
          'client_secret': 'secret-client',
          'session_id': 'secret-sess',
          'normal': 'normal-val',
        },
      );

      interceptor.onRequest(options, handler);

      final logContent = Log.logs.last.content;
      expect(logContent, contains('password=%3Credacted%3E'));
      expect(logContent, contains('client_secret=%3Credacted%3E'));
      expect(logContent, contains('session_id=%3Credacted%3E'));
      expect(logContent, contains('normal=normal-val'));
      expect(logContent, isNot(contains('secret-pwd')));
      expect(logContent, isNot(contains('secret-client')));
      expect(logContent, isNot(contains('secret-sess')));
    });

    test('redacts FormData sensitive fields without reading files', () {
      final handler = _TestRequestHandler();
      final formData = FormData.fromMap({
        'token': 'form-token',
        'description': 'normal description',
        'file': MultipartFile.fromBytes([1, 2, 3], filename: 'avatar.png'),
      });
      final options = RequestOptions(path: '/api/upload', data: formData);

      interceptor.onRequest(options, handler);

      final logContent = Log.logs.last.content;
      expect(logContent, contains('name: token, value: <redacted>'));
      expect(
        logContent,
        contains('name: description, value: normal description'),
      );
      expect(logContent, contains('filename: avatar.png'));
      expect(logContent, isNot(contains('form-token')));
    });
  });

  group('MyLogInterceptor - onResponse', () {
    test(
      'redacts sensitive response headers (Cookie, Set-Cookie, Authorization)',
      () {
        final handler = _TestResponseHandler();
        final response = Response<dynamic>(
          requestOptions: RequestOptions(path: '/api/resp'),
          statusCode: 200,
          headers: Headers.fromMap({
            'Set-Cookie': ['session=new-sess; Path=/'],
            'Cookie': ['old-sess=abc'],
            'Authorization': ['Bearer resp-token'],
            'Content-Type': ['application/json'],
          }),
          data: {'success': true},
        );

        interceptor.onResponse(response, handler);

        final logContent = Log.logs.last.content;
        expect(logContent, contains('set-cookie: <redacted>'));
        expect(logContent, contains('cookie: <redacted>'));
        expect(logContent, contains('authorization: <redacted>'));
        expect(logContent, contains('content-type: application/json'));
        expect(logContent, isNot(contains('session=new-sess')));
      },
    );

    test('response headers respect maskHeadersInLog', () {
      final handler = _TestResponseHandler();
      final requestOptions = RequestOptions(
        path: '/api/resp-mask',
        extra: {
          'maskHeadersInLog': ['X-Custom-Resp-Header'],
        },
      );
      final response = Response<dynamic>(
        requestOptions: requestOptions,
        statusCode: 200,
        headers: Headers.fromMap({
          'X-Custom-Resp-Header': ['secret-header-val'],
        }),
        data: {'status': 'ok'},
      );

      interceptor.onResponse(response, handler);

      final logContent = Log.logs.last.content;
      expect(logContent, contains('x-custom-resp-header: <redacted>'));
      expect(logContent, isNot(contains('secret-header-val')));
    });

    test('response data respects maskDataInLog', () {
      final handler = _TestResponseHandler();
      final requestOptions = RequestOptions(
        path: '/api/secret',
        extra: {'maskDataInLog': true},
      );
      final response = Response<dynamic>(
        requestOptions: requestOptions,
        statusCode: 200,
        headers: Headers(),
        data: {'ordinaryField': 'should-not-appear'},
      );

      interceptor.onResponse(response, handler);

      final logContent = Log.logs.last.content;
      expect(logContent, contains('<redacted>'));
      expect(logContent, isNot(contains('should-not-appear')));
    });

    test('automatically detects and redacts JWT in any field', () {
      final handler = _TestResponseHandler();
      const jwtToken =
          'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c';
      final response = Response<dynamic>(
        requestOptions: RequestOptions(path: '/api/jwt'),
        statusCode: 200,
        headers: Headers(),
        data: {
          'Response': jwtToken,
          'version': '1.0.0',
          'package': 'com.example.app',
        },
      );

      interceptor.onResponse(response, handler);

      final logContent = Log.logs.last.content;
      expect(logContent, contains('Response: <redacted>'));
      // Ensure normal version strings or dot-separated text are NOT misidentified as JWT
      expect(logContent, contains('version: 1.0.0'));
      expect(logContent, contains('package: com.example.app'));
      expect(logContent, isNot(contains('eyJhbGciOiJIUzI1Ni')));
    });

    test('does not treat long dot-separated text as JWT', () {
      final handler = _TestResponseHandler();
      const value = 'verylonghostname.exampledomain.component12345';
      final response = Response<dynamic>(
        requestOptions: RequestOptions(path: '/api/domain'),
        statusCode: 200,
        headers: Headers(),
        data: {'host': value},
      );

      interceptor.onResponse(response, handler);

      final logContent = Log.logs.last.content;
      expect(logContent, contains('host: $value'));
      expect(logContent, isNot(contains('<redacted>')));
    });

    test('redacts JWT embedded in ordinary text', () {
      final handler = _TestResponseHandler();
      const jwtToken =
          'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c';
      final response = Response<dynamic>(
        requestOptions: RequestOptions(path: '/api/err'),
        statusCode: 200,
        headers: Headers(),
        data: {'message': 'Authentication failed: token=$jwtToken'},
      );

      interceptor.onResponse(response, handler);

      final logContent = Log.logs.last.content;
      expect(
        logContent,
        contains('message: Authentication failed: token=<redacted>'),
      );
      expect(logContent, isNot(contains(jwtToken)));
    });

    test(
      'handles binary List<int> without large iteration or stream consumption',
      () {
        final handler = _TestResponseHandler();
        final binaryData = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]; // JPEG magic
        final response = Response<dynamic>(
          requestOptions: RequestOptions(path: '/image.jpg'),
          statusCode: 200,
          headers: Headers(),
          data: binaryData,
        );

        interceptor.onResponse(response, handler);

        final logContent = Log.logs.last.content;
        expect(logContent, contains('<Bytes: length=6>'));
      },
    );
  });

  group('MyLogInterceptor - onError', () {
    test('sanitizes request headers, data, and response in error logs', () {
      final handler = _TestErrorHandler();
      final err = DioException(
        requestOptions: RequestOptions(
          path: 'https://example.com/api/fail?token=secret-token',
          headers: {'Authorization': 'Bearer secret-auth'},
          data: {'password': 'plain-password', 'username': 'user1'},
        ),
        response: Response(
          requestOptions: RequestOptions(path: '/api/fail'),
          statusCode: 401,
          headers: Headers.fromMap({
            'Set-Cookie': ['secret-cookie'],
          }),
          data: {'error': 'Unauthorized', 'token': 'leaked-token'},
        ),
        type: DioExceptionType.badResponse,
      );

      interceptor.onError(err, handler);

      final logContent = Log.logs.last.content;
      expect(logContent, contains('token=%3Credacted%3E'));
      expect(logContent, contains('Authorization: <redacted>'));
      expect(logContent, contains('password: <redacted>'));
      expect(logContent, contains('username: user1'));
      expect(logContent, contains('set-cookie: <redacted>'));
      expect(logContent, contains('token: <redacted>'));
      expect(logContent, contains('error: Unauthorized'));
      expect(logContent, isNot(contains('secret-auth')));
      expect(logContent, isNot(contains('plain-password')));
      expect(logContent, isNot(contains('secret-cookie')));
      expect(logContent, isNot(contains('leaked-token')));

      // Verify custom message enhancement is preserved
      expect(handler.result?.message, contains('The Request is unauthorized.'));
    });

    test('error response respects maskDataInLog', () {
      final handler = _TestErrorHandler();
      final requestOptions = RequestOptions(
        path: '/api/error-secret',
        extra: {'maskDataInLog': true},
      );
      final err = DioException(
        requestOptions: requestOptions,
        response: Response(
          requestOptions: requestOptions,
          statusCode: 500,
          headers: Headers(),
          data: {'serverErrorDetail': 'database-error-should-not-appear'},
        ),
        type: DioExceptionType.badResponse,
      );

      interceptor.onError(err, handler);

      final logContent = Log.logs.last.content;
      expect(logContent, contains('response data:\n<redacted>'));
      expect(logContent, isNot(contains('database-error-should-not-appear')));
    });
  });
}
