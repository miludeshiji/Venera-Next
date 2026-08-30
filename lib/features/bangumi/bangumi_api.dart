import 'package:venera_next/features/bangumi/bangumi_models.dart';
import 'package:venera_next/network/app_dio.dart';

abstract interface class BangumiGateway {
  Future<BangumiUser> currentUser();
  Future<List<BangumiSubject>> searchSubjects(String keyword);
  Future<BangumiSubject> getSubject(int subjectId);
  Future<BangumiCollection?> getCollection(String username, int subjectId);
  Future<void> createCollection(int subjectId, Map<String, dynamic> fields);
  Future<void> patchCollection(int subjectId, Map<String, dynamic> fields);
}

class BangumiApiException implements Exception {
  const BangumiApiException(this.statusCode, this.message);

  final int? statusCode;
  final String message;

  bool get isRetryable =>
      statusCode == null ||
      statusCode == 408 ||
      statusCode == 429 ||
      (statusCode != null && statusCode! >= 500);

  @override
  String toString() => message;
}

class BangumiApi implements BangumiGateway {
  BangumiApi({required String token, Dio? dio})
    : _dio = dio ?? AppDio(BaseOptions(baseUrl: 'https://api.bgm.tv')),
      _token = token;

  final Dio _dio;
  final String _token;

  @override
  Future<BangumiUser> currentUser() async {
    final response = await _get('/v0/me');
    return BangumiUser.fromJson(_jsonMap(response.data));
  }

  @override
  Future<List<BangumiSubject>> searchSubjects(String keyword) async {
    final response = await _post('/v0/search/subjects', {
      'keyword': keyword,
      'sort': 'match',
      'filter': {
        'type': [1],
        'nsfw': true,
      },
    });
    final data = _jsonMap(response.data)['data'];
    if (data is! List) {
      return [];
    }
    return data
        .whereType<Map>()
        .map((item) => BangumiSubject.fromJson(_jsonMap(item)))
        .where(
          (subject) => subject.platform == null || subject.platform == '漫画',
        )
        .toList();
  }

  @override
  Future<BangumiSubject> getSubject(int subjectId) async {
    final response = await _get('/v0/subjects/$subjectId');
    return BangumiSubject.fromJson(_jsonMap(response.data));
  }

  @override
  Future<BangumiCollection?> getCollection(
    String username,
    int subjectId,
  ) async {
    final response = await _request(
      'GET',
      '/v0/users/${Uri.encodeComponent(username)}/collections/$subjectId',
      allowNotFound: true,
    );
    if (response.statusCode == 404) {
      return null;
    }
    return BangumiCollection.fromJson(_jsonMap(response.data));
  }

  @override
  Future<void> createCollection(
    int subjectId,
    Map<String, dynamic> fields,
  ) async {
    await _post('/v0/users/-/collections/$subjectId', fields);
  }

  @override
  Future<void> patchCollection(
    int subjectId,
    Map<String, dynamic> fields,
  ) async {
    await _request('PATCH', '/v0/users/-/collections/$subjectId', data: fields);
  }

  Future<Response<dynamic>> _get(String path) => _request('GET', path);

  Future<Response<dynamic>> _post(String path, Object data) =>
      _request('POST', path, data: data);

  Future<Response<dynamic>> _request(
    String method,
    String path, {
    Object? data,
    bool allowNotFound = false,
  }) async {
    final Response<dynamic> response;
    try {
      response = await _dio.request<dynamic>(
        path,
        data: data,
        options: Options(
          method: method,
          headers: {
            'Authorization': 'Bearer $_token',
            'Accept': 'application/json',
          },
          validateStatus: (_) => true,
          extra: {
            'maskHeadersInLog': ['Authorization'],
          },
        ),
      );
    } on DioException catch (error) {
      throw BangumiApiException(null, _transportMessage(error));
    }

    final statusCode = response.statusCode;
    if (statusCode != null && statusCode >= 200 && statusCode < 300) {
      return response;
    }
    if (allowNotFound && statusCode == 404) {
      return response;
    }
    throw BangumiApiException(statusCode, _errorMessage(response));
  }

  static Map<String, dynamic> _jsonMap(Object? data) {
    if (data == null ||
        (data is String && data.isEmpty) ||
        (data is List<int> && data.isEmpty)) {
      return const {};
    }
    return Map<String, dynamic>.from(data as Map);
  }

  static String _errorMessage(Response<dynamic> response) {
    final data = response.data;
    if (data is Map) {
      for (final key in ['title', 'description', 'details']) {
        final value = data[key];
        if (value is String && value.trim().isNotEmpty) {
          return value;
        }
      }
    }
    return 'HTTP ${response.statusCode}';
  }

  static String _transportMessage(DioException error) {
    final message = error.message;
    if (message != null && message.isNotEmpty) {
      return message;
    }
    return error.error?.toString() ?? 'Network request failed';
  }
}
