import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../auth/data/auth_api_client.dart' show normalizeAuthOrigin;
import '../../auth/data/auth_http_client.dart';
import '../domain/group_call_models.dart';

abstract interface class GroupCallGateway {
  Future<GroupCallJoinInfo> start({
    required Uri origin,
    required String accessToken,
    required String groupId,
    required String kind,
  });

  Future<GroupCallJoinInfo> join({
    required Uri origin,
    required String accessToken,
    required String groupId,
    required String callId,
  });

  Future<GroupCallInfo> leave({
    required Uri origin,
    required String accessToken,
    required String groupId,
    required String callId,
  });

  Future<GroupCallInfo?> active({
    required Uri origin,
    required String accessToken,
    required String groupId,
  });

  void close();
}

final class GroupCallApiException implements Exception {
  const GroupCallApiException({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  final int statusCode;
  final String code;
  final String message;

  @override
  String toString() => message;
}

final class GroupCallApiClient implements GroupCallGateway {
  GroupCallApiClient({http.Client? httpClient})
    : _client = httpClient ?? createAuthHttpClient();

  final http.Client _client;

  @override
  Future<GroupCallJoinInfo> start({
    required Uri origin,
    required String accessToken,
    required String groupId,
    required String kind,
  }) async => GroupCallJoinInfo.fromJson(
    _decodeData(
      await _client.post(
        normalizeAuthOrigin(origin).resolve('/api/v1/groups/$groupId/calls'),
        headers: _jsonHeaders(accessToken),
        body: jsonEncode({'kind': kind.toUpperCase()}),
      ),
      const {201},
    ),
  );

  @override
  Future<GroupCallJoinInfo> join({
    required Uri origin,
    required String accessToken,
    required String groupId,
    required String callId,
  }) async => GroupCallJoinInfo.fromJson(
    _decodeData(
      await _client.post(
        normalizeAuthOrigin(
          origin,
        ).resolve('/api/v1/groups/$groupId/calls/$callId/join'),
        headers: _headers(accessToken),
      ),
      const {200},
    ),
  );

  @override
  Future<GroupCallInfo> leave({
    required Uri origin,
    required String accessToken,
    required String groupId,
    required String callId,
  }) async => GroupCallInfo.fromJson(
    _decodeData(
      await _client.post(
        normalizeAuthOrigin(
          origin,
        ).resolve('/api/v1/groups/$groupId/calls/$callId/leave'),
        headers: _headers(accessToken),
      ),
      const {200},
    ),
  );

  @override
  Future<GroupCallInfo?> active({
    required Uri origin,
    required String accessToken,
    required String groupId,
  }) async {
    final response = await _client.get(
      normalizeAuthOrigin(
        origin,
      ).resolve('/api/v1/groups/$groupId/calls/active'),
      headers: _headers(accessToken),
    );
    if (response.statusCode == 404) return null;
    return GroupCallInfo.fromJson(_decodeData(response, const {200}));
  }

  Map<String, String> _headers(String token) => <String, String>{
    'Authorization': 'Bearer $token',
    'Accept': 'application/json',
  };

  Map<String, String> _jsonHeaders(String token) => <String, String>{
    ..._headers(token),
    'Content-Type': 'application/json; charset=utf-8',
  };

  Map<String, dynamic> _decodeData(
    http.Response response,
    Set<int> expected,
  ) {
    dynamic decoded;
    if (response.bodyBytes.isNotEmpty) {
      try {
        decoded = jsonDecode(utf8.decode(response.bodyBytes));
      } catch (_) {
        decoded = null;
      }
    }
    if (!expected.contains(response.statusCode)) {
      final error = decoded is Map ? decoded['error'] : null;
      throw GroupCallApiException(
        statusCode: response.statusCode,
        code: error is Map && error['code'] is String
            ? error['code'] as String
            : 'GROUP_CALL_REQUEST_FAILED',
        message: error is Map && error['message'] is String
            ? error['message'] as String
            : '群通话请求失败（HTTP ${response.statusCode}）。',
      );
    }
    final data = decoded is Map ? decoded['data'] : null;
    if (data is! Map<String, dynamic>) {
      throw const FormatException('群通话 API 返回格式错误。');
    }
    return data;
  }

  @override
  void close() => _client.close();
}
