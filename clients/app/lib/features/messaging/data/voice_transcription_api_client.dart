import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../auth/data/auth_api_client.dart' show normalizeAuthOrigin;
import '../../auth/data/auth_http_client.dart';
import 'messaging_api_client.dart';

enum VoiceTranscriptionStatus { pending, running, completed, failed }

final class VoiceTranscriptionResult {
  const VoiceTranscriptionResult({
    required this.id,
    required this.messageId,
    required this.status,
    required this.retryable,
    required this.attempts,
    this.transcript = '',
    this.language = '',
    this.model = '',
    this.errorCategory = '',
  });

  factory VoiceTranscriptionResult.fromJson(Map<String, dynamic> json) {
    final rawStatus = json['status']?.toString().toUpperCase() ?? '';
    final status = switch (rawStatus) {
      'PENDING' => VoiceTranscriptionStatus.pending,
      'RUNNING' => VoiceTranscriptionStatus.running,
      'COMPLETED' => VoiceTranscriptionStatus.completed,
      'FAILED' => VoiceTranscriptionStatus.failed,
      _ => throw const FormatException('语音转文字状态格式错误。'),
    };
    return VoiceTranscriptionResult(
      id: json['id']?.toString() ?? '',
      messageId: json['messageId']?.toString() ?? '',
      status: status,
      transcript: json['transcript']?.toString() ?? '',
      language: json['language']?.toString() ?? '',
      model: json['model']?.toString() ?? '',
      errorCategory: json['errorCategory']?.toString() ?? '',
      retryable: json['retryable'] == true,
      attempts: json['attempts'] is int ? json['attempts'] as int : 0,
    );
  }

  final String id;
  final String messageId;
  final VoiceTranscriptionStatus status;
  final String transcript;
  final String language;
  final String model;
  final String errorCategory;
  final bool retryable;
  final int attempts;

  bool get isTerminal =>
      status == VoiceTranscriptionStatus.completed ||
      status == VoiceTranscriptionStatus.failed;
}

final class VoiceTranscriptionPreferences {
  const VoiceTranscriptionPreferences({
    required this.autoTranscribeEnabled,
    required this.providerAvailable,
  });

  factory VoiceTranscriptionPreferences.fromJson(Map<String, dynamic> json) =>
      VoiceTranscriptionPreferences(
        autoTranscribeEnabled: json['autoTranscribeEnabled'] == true,
        providerAvailable: json['providerAvailable'] == true,
      );

  final bool autoTranscribeEnabled;
  final bool providerAvailable;
}

final class VoiceTranscriptionApiClient {
  VoiceTranscriptionApiClient({http.Client? httpClient})
      : _client = httpClient ?? createAuthHttpClient();

  final http.Client _client;

  Future<VoiceTranscriptionResult> request({
    required Uri origin,
    required String accessToken,
    required String messageId,
  }) async {
    final response = await _client.post(
      normalizeAuthOrigin(origin).resolve(
        '/api/v1/messages/${Uri.encodeComponent(messageId)}/transcription',
      ),
      headers: _authHeaders(accessToken),
    );
    return VoiceTranscriptionResult.fromJson(
      _decodeData(response, const {200, 202}),
    );
  }

  Future<VoiceTranscriptionResult> get({
    required Uri origin,
    required String accessToken,
    required String messageId,
  }) async {
    final response = await _client.get(
      normalizeAuthOrigin(origin).resolve(
        '/api/v1/messages/${Uri.encodeComponent(messageId)}/transcription',
      ),
      headers: _authHeaders(accessToken),
    );
    return VoiceTranscriptionResult.fromJson(_decodeData(response, const {200}));
  }

  Future<VoiceTranscriptionPreferences> getPreferences({
    required Uri origin,
    required String accessToken,
  }) async {
    final response = await _client.get(
      normalizeAuthOrigin(origin).resolve('/api/v1/voice-transcription/preferences'),
      headers: _authHeaders(accessToken),
    );
    return VoiceTranscriptionPreferences.fromJson(
      _decodeData(response, const {200}),
    );
  }

  Future<VoiceTranscriptionPreferences> updatePreferences({
    required Uri origin,
    required String accessToken,
    required bool autoTranscribeEnabled,
  }) async {
    final response = await _client.patch(
      normalizeAuthOrigin(origin).resolve('/api/v1/voice-transcription/preferences'),
      headers: {
        ..._authHeaders(accessToken),
        'Content-Type': 'application/json; charset=utf-8',
      },
      body: jsonEncode({'autoTranscribeEnabled': autoTranscribeEnabled}),
    );
    return VoiceTranscriptionPreferences.fromJson(
      _decodeData(response, const {200}),
    );
  }

  Map<String, String> _authHeaders(String accessToken) => {
    'Authorization': 'Bearer $accessToken',
    'Accept': 'application/json',
  };

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
      final error = decoded is Map ? decoded['error'] : null;
      throw MessagingApiException(
        statusCode: response.statusCode,
        code: error is Map && error['code'] is String
            ? error['code'] as String
            : 'VOICE_TRANSCRIPTION_REQUEST_FAILED',
        message: error is Map && error['message'] is String
            ? error['message'] as String
            : '语音转文字请求失败（HTTP ${response.statusCode}）。',
        requestId: error is Map && error['requestId'] is String
            ? error['requestId'] as String
            : null,
      );
    }
    final data = decoded is Map ? decoded['data'] : null;
    if (data is! Map<String, dynamic>) {
      throw const FormatException('语音转文字 API 返回格式错误。');
    }
    return data;
  }

  void close() => _client.close();
}
