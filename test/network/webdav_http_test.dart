import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/network/webdav.dart';

void main() {
  for (final trailingSlash in ['', '/']) {
    test(
      'WebDAV preserves mixed-case paths over HTTP ($trailingSlash)',
      () async {
        final server = await _CaseSensitiveWebDav.start();
        addTearDown(server.close);
        final client = WebDavEndpoint(
          url: '${server.url}/VeneraNext$trailingSlash',
          user: '',
          password: '',
        ).createClient();
        // Exercise the real WebDAV request builder without requiring a native
        // rhttp library in CI. The server uses case-sensitive keys on every OS.
        client.c.httpClientAdapter = IOHttpClientAdapter();
        addTearDown(() => client.c.close(force: true));

        expect(await client.readDir('/'), isEmpty);
        const name = 'Snapshot.venera';
        final bytes = Uint8List.fromList(utf8.encode('test snapshot'));
        await client.write(name, bytes);
        expect(await client.read(name), bytes);
        await client.remove(name);

        expect(server.requests, [
          'PROPFIND /dav/VeneraNext/',
          'OPTIONS /dav/VeneraNext/Snapshot.venera',
          'PUT /dav/VeneraNext/Snapshot.venera',
          'OPTIONS /dav/VeneraNext/Snapshot.venera',
          'GET /dav/VeneraNext/Snapshot.venera',
          'DELETE /dav/VeneraNext/Snapshot.venera',
        ]);
        expect(server.files, isEmpty);
      },
    );
  }

  test(
    'a directory case mismatch stays an error without creating folders',
    () async {
      final server = await _CaseSensitiveWebDav.start();
      addTearDown(server.close);
      final client = WebDavEndpoint(
        url: '${server.url}/veneranext',
        user: '',
        password: '',
      ).createClient();
      client.c.httpClientAdapter = IOHttpClientAdapter();
      addTearDown(() => client.c.close(force: true));

      await expectLater(
        client.readDir('/'),
        throwsA(
          isA<DioException>().having(
            (error) => error.response?.statusCode,
            'HTTP status',
            HttpStatus.notFound,
          ),
        ),
      );
      expect(server.requests, ['PROPFIND /dav/veneranext/']);
    },
  );
}

class _CaseSensitiveWebDav {
  _CaseSensitiveWebDav(this.server);

  final HttpServer server;
  final requests = <String>[];
  final files = <String, List<int>>{};

  String get url => 'http://127.0.0.1:${server.port}/dav';

  static Future<_CaseSensitiveWebDav> start() async {
    final fixture = _CaseSensitiveWebDav(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    fixture.server.listen(fixture._handle);
    return fixture;
  }

  Future<void> close() async => server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    requests.add('${request.method} $path');
    final body = await request.fold<List<int>>(
      [],
      (buffer, chunk) => buffer..addAll(chunk),
    );
    // Existing directories can be listed and their files modified. Creating
    // any directory is denied, including attempts to recreate an existing one.
    if (request.method == 'MKCOL') {
      request.response.statusCode = HttpStatus.forbidden;
    } else if (!path.startsWith('/dav/VeneraNext/')) {
      request.response.statusCode = HttpStatus.notFound;
    } else {
      switch (request.method) {
        case 'OPTIONS':
          request.response.statusCode = HttpStatus.ok;
        case 'PROPFIND':
          request.response.statusCode = HttpStatus.multiStatus;
          request.response.headers.contentType = ContentType(
            'application',
            'xml',
          );
          request.response.write('''<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:"><D:response>
  <D:href>/dav/VeneraNext/</D:href>
  <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
</D:response></D:multistatus>''');
        case 'PUT':
          files[path] = body;
          request.response.statusCode = HttpStatus.created;
        case 'GET':
          final bytes = files[path];
          if (bytes == null) {
            request.response.statusCode = HttpStatus.notFound;
          } else {
            request.response.add(bytes);
          }
        case 'DELETE':
          files.remove(path);
          request.response.statusCode = HttpStatus.noContent;
        default:
          request.response.statusCode = HttpStatus.methodNotAllowed;
      }
    }
    await request.response.close();
  }
}
