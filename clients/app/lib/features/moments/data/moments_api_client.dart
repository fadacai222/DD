import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../auth/data/auth_api_client.dart' show normalizeAuthOrigin;
import '../../auth/data/auth_http_client.dart';
import '../domain/moment_models.dart';

abstract interface class MomentsGateway {
  Future<List<MomentItem>> listFeed({
    required Uri origin,
    required String accessToken,
    String? before,
    String? authorId,
    int limit = 30,
  });

  Future<MomentItem> createMoment({
    required Uri origin,
    required String accessToken,
    required String text,
    required List<String> mediaIds,
    required String visibility,
    required List<String> visibilityUserIds,
  });

  Future<MomentItem> getMoment({
    required Uri origin,
    required String accessToken,
    required String momentId,
  });

  Future<void> deleteMoment({
    required Uri origin,
    required String accessToken,
    required String momentId,
  });

  Future<MomentItem> setLike({
    required Uri origin,
    required String accessToken,
    required String momentId,
    required bool liked,
  });

  Future<MomentItem> addComment({
    required Uri origin,
    required String accessToken,
    required String momentId,
    required String text,
    String? replyToCommentId,
  });

  Future<MomentItem> deleteComment({
    required Uri origin,
    required String accessToken,
    required String momentId,
    required String commentId,
  });

  Future<List<MomentPreference>> listPreferences({
    required Uri origin,
    required String accessToken,
  });

  Future<MomentPreference> setPreference({
    required Uri origin,
    required String accessToken,
    required String userId,
    required bool hideTarget,
    required bool hideFromTarget,
  });

  void close();
}

final class MomentsApiClient implements MomentsGateway {
  MomentsApiClient({http.Client? httpClient})
    : _client = httpClient ?? createAuthHttpClient(),
      _ownsClient = httpClient == null;

  final http.Client _client;
  final bool _ownsClient;

  @override
  Future<List<MomentItem>> listFeed({
    required Uri origin,
    required String accessToken,
    String? before,
    String? authorId,
    int limit = 30,
  }) async {
    final query = <String, String>{'limit': '$limit'};
    if (before != null && before.trim().isNotEmpty) query['before'] = before.trim();
    if (authorId != null && authorId.trim().isNotEmpty) {
      query['authorId'] = authorId.trim();
    }
    final endpoint = normalizeAuthOrigin(origin)
        .resolve('/api/v1/moments')
        .replace(queryParameters: query);
    final data = _decodeData(
      await _client.get(endpoint, headers: _headers(accessToken)),
      const {200},
    );
    final items = data['items'];
    if (items is! List<dynamic>) {
      throw const FormatException('朋友圈列表格式错误。');
    }
    return items
        .whereType<Map<String, dynamic>>()
        .map(MomentItem.fromJson)
        .toList(growable: false);
  }

  @override
  Future<MomentItem> createMoment({
    required Uri origin,
    required String accessToken,
    required String text,
    required List<String> mediaIds,
    required String visibility,
    required List<String> visibilityUserIds,
  }) async {
    final response = await _client.post(
      normalizeAuthOrigin(origin).resolve('/api/v1/moments'),
      headers: _jsonHeaders(accessToken),
      body: jsonEncode({
        'text': text,
        'mediaIds': mediaIds,
        'visibility': visibility,
        'visibilityUserIds': visibilityUserIds,
      }),
    );
    return MomentItem.fromJson(_decodeData(response, const {201}));
  }

  @override
  Future<MomentItem> getMoment({
    required Uri origin,
    required String accessToken,
    required String momentId,
  }) async => MomentItem.fromJson(
    _decodeData(
      await _client.get(
        normalizeAuthOrigin(origin).resolve('/api/v1/moments/$momentId'),
        headers: _headers(accessToken),
      ),
      const {200},
    ),
  );

  @override
  Future<void> deleteMoment({
    required Uri origin,
    required String accessToken,
    required String momentId,
  }) async {
    _decodeData(
      await _client.delete(
        normalizeAuthOrigin(origin).resolve('/api/v1/moments/$momentId'),
        headers: _headers(accessToken),
      ),
      const {200},
    );
  }

  @override
  Future<MomentItem> setLike({
    required Uri origin,
    required String accessToken,
    required String momentId,
    required bool liked,
  }) async {
    final endpoint = normalizeAuthOrigin(
      origin,
    ).resolve('/api/v1/moments/$momentId/like');
    final response = liked
        ? await _client.put(endpoint, headers: _headers(accessToken))
        : await _client.delete(endpoint, headers: _headers(accessToken));
    return MomentItem.fromJson(_decodeData(response, const {200}));
  }

  @override
  Future<MomentItem> addComment({
    required Uri origin,
    required String accessToken,
    required String momentId,
    required String text,
    String? replyToCommentId,
  }) async => MomentItem.fromJson(
    _decodeData(
      await _client.post(
        normalizeAuthOrigin(origin).resolve('/api/v1/moments/$momentId/comments'),
        headers: _jsonHeaders(accessToken),
        body: jsonEncode({
          'text': text,
          ...replyToCommentId == null
              ? const <String, String>{}
              : {'replyToCommentId': replyToCommentId},
        }),
      ),
      const {201},
    ),
  );

  @override
  Future<MomentItem> deleteComment({
    required Uri origin,
    required String accessToken,
    required String momentId,
    required String commentId,
  }) async => MomentItem.fromJson(
    _decodeData(
      await _client.delete(
        normalizeAuthOrigin(
          origin,
        ).resolve('/api/v1/moments/$momentId/comments/$commentId'),
        headers: _headers(accessToken),
      ),
      const {200},
    ),
  );

  @override
  Future<List<MomentPreference>> listPreferences({
    required Uri origin,
    required String accessToken,
  }) async {
    final data = _decodeData(
      await _client.get(
        normalizeAuthOrigin(origin).resolve('/api/v1/moment-preferences'),
        headers: _headers(accessToken),
      ),
      const {200},
    );
    final items = data['items'];
    if (items is! List<dynamic>) {
      throw const FormatException('朋友圈隐私设置格式错误。');
    }
    return items
        .whereType<Map<String, dynamic>>()
        .map(MomentPreference.fromJson)
        .toList(growable: false);
  }

  @override
  Future<MomentPreference> setPreference({
    required Uri origin,
    required String accessToken,
    required String userId,
    required bool hideTarget,
    required bool hideFromTarget,
  }) async => MomentPreference.fromJson(
    _decodeData(
      await _client.patch(
        normalizeAuthOrigin(origin).resolve('/api/v1/moment-preferences/$userId'),
        headers: _jsonHeaders(accessToken),
        body: jsonEncode({
          'hideTarget': hideTarget,
          'hideFromTarget': hideFromTarget,
        }),
      ),
      const {200},
    ),
  );

  Map<String, dynamic> _decodeData(http.Response response, Set<int> expected) {
    dynamic decoded;
    if (response.bodyBytes.isNotEmpty) {
      try {
        decoded = jsonDecode(utf8.decode(response.bodyBytes));
      } catch (_) {
        decoded = null;
      }
    }
    if (!expected.contains(response.statusCode)) {
      var code = 'MOMENTS_HTTP_${response.statusCode}';
      var message = '朋友圈服务请求失败（HTTP ${response.statusCode}）。';
      if (decoded is Map<String, dynamic>) {
        final rawError = decoded['error'];
        if (rawError is Map<String, dynamic>) {
          code = rawError['code'] as String? ?? code;
          message = rawError['message'] as String? ?? message;
        }
      }
      throw MomentsApiException(
        statusCode: response.statusCode,
        code: code,
        message: message,
      );
    }
    if (decoded is! Map<String, dynamic> || decoded['data'] is! Map<String, dynamic>) {
      throw const FormatException('朋友圈服务响应格式错误。');
    }
    return decoded['data'] as Map<String, dynamic>;
  }

  Map<String, String> _headers(String token) => {
    'Authorization': 'Bearer $token',
    'Accept': 'application/json',
  };

  Map<String, String> _jsonHeaders(String token) => {
    ..._headers(token),
    'Content-Type': 'application/json; charset=utf-8',
  };

  @override
  void close() {
    if (_ownsClient) _client.close();
  }
}

final class MomentsApiException implements Exception {
  const MomentsApiException({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  final int statusCode;
  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}
