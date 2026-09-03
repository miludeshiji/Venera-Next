import 'dart:convert';

import 'package:venera_next/network/app_dio.dart';
import 'package:webdav_client/webdav_client.dart';

class WebDavEndpoint {
  WebDavEndpoint({
    required String url,
    required String user,
    required this.password,
  }) : url = normalizeWebDavEndpointUrl(url),
       user = user.trim();

  final String url;
  final String user;
  final String password;

  bool get isValid => url.isNotEmpty;

  Map<String, String> get authHeaders {
    if (user.isEmpty && password.isEmpty) return const {};
    final token = base64Encode(utf8.encode('$user:$password'));
    return {'authorization': 'Basic $token'};
  }

  Client createClient() {
    return newClient(
      url,
      user: user,
      password: password,
      adapter: RHttpAdapter(),
    );
  }

  String fileUrl(String remoteFilePath) {
    final base = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    final path = remoteFilePath
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    return '$base/$path';
  }
}

String normalizeWebDavEndpointUrl(String value) {
  final trimmed = value.trim().replaceAll('\\', '/');
  if (trimmed.isEmpty) return '';
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }
  final scheme = uri.scheme.toLowerCase();
  final defaultPort =
      (scheme == 'http' && uri.port == 80) ||
      (scheme == 'https' && uri.port == 443);
  var path = uri.normalizePath().path.replaceAll(RegExp('/+'), '/');
  if (path == '/') {
    path = '';
  } else if (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return Uri(
    scheme: scheme,
    userInfo: uri.userInfo,
    host: uri.host.toLowerCase(),
    port: defaultPort || !uri.hasPort ? null : uri.port,
    path: path,
  ).toString();
}

String normalizeWebDavDirectoryPath(String path, {required String fallback}) {
  var result = path.trim().replaceAll('\\', '/');
  if (result.isEmpty) result = fallback.trim().replaceAll('\\', '/');
  final segments = result
      .split('/')
      .where((segment) => segment.isNotEmpty && segment != '.')
      .toList();
  if (segments.any((segment) => segment == '..')) {
    throw const FormatException('Invalid WebDAV directory path');
  }
  return segments.isEmpty ? '/' : '/${segments.join('/')}/';
}

String joinWebDavFilePath(String parent, String relativePath) {
  final path = normalizeWebDavRelativePath(relativePath);
  return '${_ensureTrailingSlash(parent)}$path';
}

String joinWebDavDirectoryPath(String parent, String relativePath) {
  return '${joinWebDavFilePath(parent, relativePath)}/';
}

String normalizeWebDavRelativePath(String value) {
  final segments = value
      .replaceAll('\\', '/')
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .toList();
  if (segments.isEmpty ||
      segments.any((segment) => segment == '.' || segment == '..')) {
    throw const FormatException('Invalid relative WebDAV path');
  }
  return segments.join('/');
}

String _ensureTrailingSlash(String path) {
  return path.endsWith('/') ? path : '$path/';
}
