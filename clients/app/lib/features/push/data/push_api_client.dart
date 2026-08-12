import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../auth/data/auth_api_client.dart';
import '../application/push_endpoint_lifecycle.dart';

final class PushPreferences {
  const PushPreferences({
    required this.pushEnabled,
    required this.previewMode,
  });

  factory PushPreferences.fromJson(Map<String, dynamic> json) => PushPreferences(
        pushEnabled: json['pushEnabled'] != false,
        previewMode: json['previewMode']?.toString() ?? 'SENDER_ONLY',
      );

  final bool pushEnabled;
  final String previewMode;
}

final class PushApiClient implements PushEndpointGateway {
  PushApiClient({http.Client? client})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  Future<PushPreferences> getPreferences({
    required Uri origin,
    required String accessToken,
  }) async {
    final data = _decodeData(
      await _client.get(
        normalizeAuthOrigin(origin).resolve('/api/v1/push/preferences'),
        headers: _headers(accessToken),
      ),
      const {200},
    );
    return PushPreferences.fromJson(data);
  }

  Future<PushPreferences> updatePreferences({
    required Uri origin,
    required String accessToken,
    required bool pushEnabled,
    required String previewMode,
  }) async {
    final data = _decodeData(
      await _client.put(
        normalizeAuthOrigin(origin).resolve('/api/v1/push/preferences'),
        headers: _jsonHeaders(accessToken),
        body: jsonEncode({
          'pushEnabled': pushEnabled,
          'previewMode': previewMode,
        }),
      ),
      const {200},
    );
    return PushPreferences.fromJson(data);
  }

  @override
  Future<void> registerEndpoint({
    required Uri origin,
    required String accessToken,
    required String provider,
    required String endpoint,
    required String appId,
    required String environment,
  }) async {
    _decodeData(
      await _client.put(
        normalizeAuthOrigin(origin).resolve('/api/v1/push/endpoints'),
        headers: _jsonHeaders(accessToken),
        body: jsonEncode({
          'provider': provider,
          'endpoint': endpoint,
          'appId': appId,
          'environment': environment,
        }),
      ),
      const {200},
    );
  }

  @override
  Future<void> deleteEndpoint({
    required Uri origin,
    required String accessToken,
    required String provider,
  }) async {
    final response = await _client.delete(
      normalizeAuthOrigin(origin).resolve('/api/v1/push/endpoints/$provider'),
      headers: _headers(accessToken),
    );
    if (response.statusCode == 404) return;
    _decodeData(response, const {200});
  }

  Future<void> enqueueTest({
    required Uri origin,
    required String accessToken,
  }) async {
    _decodeData(
      await _client.post(
        normalizeAuthOrigin(origin).resolve('/api/v1/push/test'),
        headers: _headers(accessToken),
      ),
      const {202},
    );
  }

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
      var code = 'PUSH_HTTP_${response.statusCode}';
      var message = '推送服务请求失败（HTTP ${response.statusCode}）。';
      if (decoded is Map<String, dynamic>) {
        final rawError = decoded['error'];
        if (rawError is Map<String, dynamic>) {
          code = rawError['code']?.toString() ?? code;
          message = rawError['message']?.toString() ?? message;
        }
      }
      throw PushApiException(
        statusCode: response.statusCode,
        code: code,
        message: message,
      );
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['data'] is! Map<String, dynamic>) {
      throw const FormatException('推送服务响应格式错误。');
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

  void close() {
    if (_ownsClient) _client.close();
  }
}

final class PushApiException implements Exception {
  const PushApiException({
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
