import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/cache.dart';
import 'package:venera_next/network/proxy.dart';

import '../foundation/app.dart';
import 'cloudflare.dart';
import 'cookie_jar.dart';

export 'package:dio/dio.dart';

bool isMalformedExpectedJsonResponse(Response<dynamic> response) {
  final statusCode = response.statusCode;
  if (statusCode == 204 || statusCode == 205) {
    return false;
  }

  final requestHeaders = response.requestOptions.headers;
  final accept = requestHeaders.entries
      .where((entry) => entry.key.toLowerCase() == 'accept')
      .map((entry) => entry.value.toString())
      .join(',')
      .toLowerCase();
  final contentType = response.headers
      .value(Headers.contentTypeHeader)
      ?.toLowerCase();
  final expectsJson =
      accept.contains('json') ||
      (contentType?.contains('json') ?? false) ||
      response.requestOptions.uri.path.toLowerCase().endsWith('.json');
  if (!expectsJson) {
    return false;
  }

  final data = response.data;
  if (data is Map || data is num || data is bool) {
    return false;
  }
  if (data is List && data is! List<int>) {
    return false;
  }

  try {
    final String text;
    if (data is String) {
      text = data;
    } else if (data is List<int>) {
      text = utf8.decode(data, allowMalformed: false);
    } else {
      return true;
    }
    jsonDecode(text);
    return false;
  } catch (_) {
    return true;
  }
}

class MyLogInterceptor extends Interceptor {
  static const String _redacted = '<redacted>';

  static const Set<String> _sensitiveHeaderNames = {
    'authorization',
    'proxyauthorization',
    'cookie',
    'setcookie',
    'xapikey',
    'apikey',
    'xauthtoken',
    'xaccesstoken',
    'xid',
  };

  static const Set<String> _sensitiveFieldNames = {
    'token',
    'accesstoken',
    'refreshtoken',
    'idtoken',
    'password',
    'passwd',
    'pwd',
    'secret',
    'clientsecret',
    'authorization',
    'cookie',
    'session',
    'sessionid',
    'deviceid',
    'apikey',
    'xapikey',
  };

  static const Set<String> _sensitiveQueryNames = {
    'token',
    'accesstoken',
    'refreshtoken',
    'idtoken',
    'apikey',
    'xapikey',
    'key',
    'auth',
    'signature',
    'sig',
    'password',
    'passwd',
    'pwd',
    'secret',
    'clientsecret',
    'session',
    'sessionid',
  };

  static final RegExp _jwtCandidatePattern = RegExp(
    r'[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+',
  );

  static String _normalizeSensitiveName(String name) {
    return name.toLowerCase().replaceAll('_', '').replaceAll('-', '');
  }

  static Iterable<String> _getExtraMaskedHeaders(RequestOptions options) {
    final value = options.extra['maskHeadersInLog'];
    if (value is String) {
      return [value];
    }
    if (value is Iterable) {
      return value.map((e) => e.toString());
    }
    return const <String>[];
  }

  static bool _shouldMaskData(RequestOptions options) {
    return options.extra['maskDataInLog'] == true;
  }

  static bool _looksLikeJwt(String value) {
    final trimmed = value.trim();
    final parts = trimmed.split('.');
    if (parts.length != 3 || parts.any((part) => part.isEmpty)) {
      return false;
    }

    final base64UrlRegex = RegExp(r'^[A-Za-z0-9_-]+$');
    if (!parts.every((part) => base64UrlRegex.hasMatch(part))) {
      return false;
    }

    try {
      final headerBytes = base64Url.decode(base64Url.normalize(parts[0]));
      final headerJson = jsonDecode(utf8.decode(headerBytes));
      if (headerJson is! Map) {
        return false;
      }
      return headerJson.containsKey('alg') || headerJson['typ'] == 'JWT';
    } catch (_) {
      return false;
    }
  }

  static String _sanitizeString(String value) {
    if (_looksLikeJwt(value)) {
      return _redacted;
    }
    var result = value;
    result = result.replaceAll(
      RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
      'Bearer $_redacted',
    );
    result = result.replaceAllMapped(_jwtCandidatePattern, (match) {
      final candidate = match.group(0)!;
      return _looksLikeJwt(candidate) ? _redacted : candidate;
    });
    return result;
  }

  static Uri _sanitizeUri(Uri uri) {
    if (uri.queryParameters.isEmpty) {
      return uri;
    }
    final sanitized = <String, dynamic>{};
    uri.queryParametersAll.forEach((key, values) {
      if (_sensitiveQueryNames.contains(_normalizeSensitiveName(key))) {
        sanitized[key] = values.map((_) => _redacted).toList();
      } else {
        sanitized[key] = values.map((v) => _sanitizeString(v)).toList();
      }
    });
    return uri.replace(queryParameters: sanitized);
  }

  static Map<String, dynamic> _sanitizeHeaders(
    Map<dynamic, dynamic> headers, {
    Iterable<String> extraMaskedHeaders = const [],
  }) {
    final maskedNames = <String>{
      ..._sensitiveHeaderNames,
      ...extraMaskedHeaders.map(_normalizeSensitiveName),
    };

    final result = <String, dynamic>{};
    headers.forEach((rawKey, rawValue) {
      final key = rawKey.toString();
      final normalizedKey = _normalizeSensitiveName(key);
      if (maskedNames.contains(normalizedKey)) {
        result[key] = _redacted;
      } else if (rawValue is List) {
        result[key] = rawValue
            .map((item) => _sanitizeString(item.toString()))
            .toList();
      } else if (rawValue is String) {
        result[key] = _sanitizeString(rawValue);
      } else {
        result[key] = rawValue;
      }
    });
    return result;
  }

  static Object? _sanitizeData(Object? data) {
    if (data == null) {
      return null;
    }

    if (data is FormData) {
      return {
        'fields': [
          for (final field in data.fields)
            {
              'name': field.key,
              'value':
                  _sensitiveFieldNames.contains(
                    _normalizeSensitiveName(field.key),
                  )
                  ? _redacted
                  : _sanitizeData(field.value),
            },
        ],
        'files': [
          for (final file in data.files)
            {
              'field': file.key,
              'filename': file.value.filename,
              'length': file.value.length,
              'contentType': file.value.contentType?.toString(),
            },
        ],
      };
    }

    if (data is List<int>) {
      try {
        final decoded = utf8.decode(data, allowMalformed: false);
        return _sanitizeData(decoded);
      } catch (_) {
        return '<Bytes: length=${data.length}>';
      }
    }

    if (data is Map) {
      final result = <Object?, Object?>{};
      for (final entry in data.entries) {
        final key = entry.key;
        final normalizedKey = _normalizeSensitiveName(key.toString());

        if (_sensitiveFieldNames.contains(normalizedKey)) {
          result[key] = _redacted;
        } else {
          result[key] = _sanitizeData(entry.value);
        }
      }
      return result;
    }

    if (data is List) {
      return data.map(_sanitizeData).toList();
    }

    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map || decoded is List) {
          return jsonEncode(_sanitizeData(decoded));
        }
      } catch (_) {
        // Not JSON string, fall through to sanitize string
      }
      return _sanitizeString(data);
    }

    return data;
  }

  static const errorMessages = <int, String>{
    400: "The Request is invalid.",
    401: "The Request is unauthorized.",
    403: "No permission to access the resource. Check your account or network.",
    404: "Not found.",
    429: "Too many requests. Please try again later.",
  };

  String _getStatusCodeInfo(int? statusCode) {
    if (statusCode != null && statusCode >= 500) {
      return "This is server-side error, please try again later. "
          "Do not report this issue.";
    } else {
      return errorMessages[statusCode] ?? "";
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final request = err.requestOptions;

    final safeRequestHeaders = _sanitizeHeaders(
      request.headers,
      extraMaskedHeaders: _getExtraMaskedHeaders(request),
    );

    final safeRequestData = _shouldMaskData(request)
        ? _redacted
        : _sanitizeData(request.data);

    final safeResponseHeaders = err.response == null
        ? null
        : _sanitizeHeaders(
            err.response!.headers.map.map(
              (key, value) => MapEntry(
                key.toLowerCase(),
                value.length == 1 ? value.first : value.toString(),
              ),
            ),
            extraMaskedHeaders: _getExtraMaskedHeaders(request),
          );

    final safeResponseData = err.response == null
        ? null
        : _shouldMaskData(request)
        ? _redacted
        : _sanitizeData(err.response?.data);

    Log.error(
      'Network',
      '${request.method} ${_sanitizeUri(request.uri)}\n'
          'status: ${err.response?.statusCode}\n'
          'type: ${err.type}\n'
          'message: ${_sanitizeString(err.message ?? '')}\n'
          'request headers:\n$safeRequestHeaders\n'
          'request data:\n$safeRequestData\n'
          'response headers:\n$safeResponseHeaders\n'
          'response data:\n$safeResponseData',
    );

    switch (err.type) {
      case DioExceptionType.badResponse:
        var statusCode = err.response?.statusCode;
        if (statusCode != null) {
          err = err.copyWith(
            message:
                "Invalid Status Code: $statusCode. "
                "${_getStatusCodeInfo(statusCode)}",
          );
        }
      case DioExceptionType.connectionTimeout:
        err = err.copyWith(message: "Connection Timeout");
      case DioExceptionType.receiveTimeout:
        err = err.copyWith(
          message:
              "Receive Timeout: "
              "This indicates that the server is too busy to respond",
        );
      case DioExceptionType.unknown:
        if (err.toString().contains("Connection terminated during handshake")) {
          err = err.copyWith(
            message:
                "Connection terminated during handshake: "
                "This may be caused by the firewall blocking the connection "
                "or your requests are too frequent.",
          );
        } else if (err.toString().contains("Connection reset by peer")) {
          err = err.copyWith(
            message:
                "Connection reset by peer: "
                "The error is unrelated to app, please check your network.",
          );
        }
      default:
        {}
    }
    handler.next(err);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final requestOptions = response.requestOptions;

    final safeHeaders = _sanitizeHeaders(
      response.headers.map.map(
        (key, value) => MapEntry(
          key.toLowerCase(),
          value.length == 1 ? value.first : value.toString(),
        ),
      ),
      extraMaskedHeaders: _getExtraMaskedHeaders(requestOptions),
    );

    final safeData = _shouldMaskData(requestOptions)
        ? _redacted
        : _sanitizeData(response.data);

    Log.addLog(
      (response.statusCode != null && response.statusCode! < 400)
          ? LogLevel.info
          : LogLevel.error,
      'Network',
      'Response ${_sanitizeUri(response.realUri)} ${response.statusCode}\n'
          'headers:\n$safeHeaders\n$safeData',
    );
    handler.next(response);
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final extraMaskedHeaders = _getExtraMaskedHeaders(options);

    final safeHeaders = _sanitizeHeaders(
      options.headers,
      extraMaskedHeaders: extraMaskedHeaders,
    );

    final Object? safeData;
    if (_shouldMaskData(options)) {
      safeData = _redacted;
    } else {
      safeData = _sanitizeData(options.data);
    }

    Log.info(
      'Network',
      '${options.method} ${_sanitizeUri(options.uri)}\n'
          'headers:\n$safeHeaders\n'
          'data:\n$safeData',
    );

    options.connectTimeout = const Duration(seconds: 15);
    options.receiveTimeout = const Duration(seconds: 15);
    options.sendTimeout = const Duration(seconds: 15);
    handler.next(options);
  }
}

class AppDio with DioMixin {
  AppDio([BaseOptions? options]) {
    this.options = options ?? BaseOptions();
    httpClientAdapter = RHttpAdapter();
    if (App.isInitialized) {
      interceptors.add(
        CookieManagerSql.dynamic(() => SingleInstanceCookieJar.instance),
      );
      interceptors.add(NetworkCacheManager());
      interceptors.add(CloudflareInterceptor());
      interceptors.add(MyLogInterceptor());
    }
  }

  static final Map<String, Future<void>> _requestTails = {};

  @override
  Future<Response<T>> request<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    Options? options,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) async {
    Completer<void>? requestCompleter;
    if (options?.headers?['prevent-parallel'] == 'true') {
      final previousRequest = _requestTails[path];
      requestCompleter = Completer<void>();
      _requestTails[path] = requestCompleter.future;
      options!.headers!.remove('prevent-parallel');
      if (previousRequest != null) {
        await previousRequest;
      }
    }
    try {
      return await super.request<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        cancelToken: cancelToken,
        options: options,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
      );
    } finally {
      if (requestCompleter != null) {
        if (identical(_requestTails[path], requestCompleter.future)) {
          _requestTails.remove(path);
        }
        requestCompleter.complete();
      }
    }
  }
}

class RHttpAdapter implements HttpClientAdapter {
  Future<rhttp.ClientSettings> get settings async {
    var proxy = await getProxy();

    return rhttp.ClientSettings(
      proxySettings: proxy == null
          ? const rhttp.ProxySettings.noProxy()
          : rhttp.ProxySettings.proxy(proxy),
      redirectSettings: const rhttp.RedirectSettings.limited(5),
      timeoutSettings: const rhttp.TimeoutSettings(
        connectTimeout: Duration(seconds: 15),
        keepAliveTimeout: Duration(seconds: 60),
        keepAlivePing: Duration(seconds: 30),
      ),
      throwOnStatusCode: false,
      dnsSettings: rhttp.DnsSettings.static(overrides: _getOverrides()),
      tlsSettings: rhttp.TlsSettings(
        sni: appdata.settings['sni'] != false,
        verifyCertificates: appdata.settings['ignoreBadCertificate'] != true,
      ),
    );
  }

  static Map<String, List<String>> _getOverrides() {
    if (!appdata.settings['enableDnsOverrides'] == true) {
      return {};
    }
    var config = appdata.settings["dnsOverrides"];
    var result = <String, List<String>>{};
    if (config is Map) {
      for (var entry in config.entries) {
        if (entry.key is String && entry.value is String) {
          result[entry.key] = [entry.value];
        }
      }
    }
    return result;
  }

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.headers['User-Agent'] == null &&
        options.headers['user-agent'] == null) {
      options.headers['User-Agent'] = "VeneraNext/v${App.version}";
    }

    var res = await rhttp.Rhttp.request(
      method: rhttp.HttpMethod(options.method),
      url: options.uri.toString(),
      settings: await settings,
      expectBody: rhttp.HttpExpectBody.stream,
      body: requestStream == null ? null : rhttp.HttpBody.stream(requestStream),
      headers: rhttp.HttpHeaders.rawMap(
        Map.fromEntries(
          options.headers.entries.map(
            (e) => MapEntry(e.key, e.value.toString().trim()),
          ),
        ),
      ),
    );
    if (res is! rhttp.HttpStreamResponse) {
      throw Exception("Invalid response type: ${res.runtimeType}");
    }
    var headers = <String, List<String>>{};
    for (var entry in res.headers) {
      var key = entry.$1.toLowerCase();
      headers[key] ??= [];
      headers[key]!.add(entry.$2);
    }
    return ResponseBody(
      res.body,
      res.statusCode,
      statusMessage: _getStatusMessage(res.statusCode),
      isRedirect: false,
      headers: headers,
    );
  }

  static String _getStatusMessage(int statusCode) {
    return switch (statusCode) {
      200 => "OK",
      201 => "Created",
      202 => "Accepted",
      204 => "No Content",
      206 => "Partial Content",
      301 => "Moved Permanently",
      302 => "Found",
      400 => "Invalid Status Code 400: The Request is invalid.",
      401 => "Invalid Status Code 401: The Request is unauthorized.",
      403 =>
        "Invalid Status Code 403: No permission to access the resource. Check your account or network.",
      404 => "Invalid Status Code 404: Not found.",
      429 =>
        "Invalid Status Code 429: Too many requests. Please try again later.",
      _ => "Invalid Status Code $statusCode",
    };
  }
}
