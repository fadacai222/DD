import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/call_token.dart';

final class HttpCallTokenProvider implements CallTokenProvider {
  HttpCallTokenProvider({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  @override
  Future<CallToken> issue({
    required Uri apiBaseUri,
    required String roomName,
    required String participantIdentity,
    required String participantName,
  }) async {
    final endpoint = apiBaseUri.resolve('/api/calls/token');
    final response = await _client
        .post(
          endpoint,
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'room_name': roomName,
            'participant_identity': participantIdentity,
            'participant_name': participantName,
          }),
        )
        .timeout(const Duration(seconds: 10));

    final decoded = _decodeObject(response.body);
    if (response.statusCode != 200) {
      final error = decoded['error'];
      final message = error is Map<String, dynamic>
          ? error['message']?.toString()
          : null;
      throw StateError(
        message ?? 'Token request failed with HTTP ${response.statusCode}',
      );
    }

    final serverUrl = Uri.tryParse(decoded['server_url']?.toString() ?? '');
    final participantToken = decoded['participant_token']?.toString() ?? '';
    final expiresAt = DateTime.tryParse(
      decoded['expires_at']?.toString() ?? '',
    );
    if (serverUrl == null ||
        !serverUrl.isAbsolute ||
        (serverUrl.scheme != 'ws' && serverUrl.scheme != 'wss') ||
        participantToken.isEmpty ||
        expiresAt == null) {
      throw const FormatException('Token response is missing required fields');
    }

    return CallToken(
      serverUrl: serverUrl,
      participantToken: participantToken,
      expiresAt: expiresAt,
    );
  }

  @override
  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }

  static Map<String, dynamic> _decodeObject(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Token response must be a JSON object');
    }
    return decoded;
  }
}
