import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/call_session.dart';
import '../domain/call_token.dart';

abstract interface class CallSessionApi {
  Future<CallSession> createCall({
    required Uri apiBaseUri,
    required String callerIdentity,
    required String callerName,
    required String calleeIdentity,
    required CallKind kind,
  });

  Future<CallSession?> fetchActiveCall({
    required Uri apiBaseUri,
    required String participantIdentity,
  });

  Future<CallSession> applyAction({
    required Uri apiBaseUri,
    required String callId,
    required String participantIdentity,
    required String action,
  });

  Future<CallToken> issueToken({
    required Uri apiBaseUri,
    required String callId,
    required String participantIdentity,
    required String participantName,
  });

  void close();
}

final class HttpCallSessionApi implements CallSessionApi {
  HttpCallSessionApi({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  @override
  Future<CallSession> createCall({
    required Uri apiBaseUri,
    required String callerIdentity,
    required String callerName,
    required String calleeIdentity,
    required CallKind kind,
  }) async {
    final response = await _client.post(
      apiBaseUri.resolve('/api/calls'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'caller_identity': callerIdentity,
        'caller_name': callerName,
        'callee_identity': calleeIdentity,
        'kind': kind.name,
      }),
    );
    return _decodeCall(response, expectedStatus: 201);
  }

  @override
  Future<CallSession?> fetchActiveCall({
    required Uri apiBaseUri,
    required String participantIdentity,
  }) async {
    final uri = apiBaseUri
        .resolve('/api/calls/active')
        .replace(
          queryParameters: {'participant_identity': participantIdentity},
        );
    final response = await _client.get(uri);
    if (response.statusCode == 204) return null;
    return _decodeCall(response, expectedStatus: 200);
  }

  @override
  Future<CallSession> applyAction({
    required Uri apiBaseUri,
    required String callId,
    required String participantIdentity,
    required String action,
  }) async {
    final response = await _client.post(
      apiBaseUri.resolve('/api/calls/$callId/actions'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'participant_identity': participantIdentity,
        'action': action,
      }),
    );
    return _decodeCall(response, expectedStatus: 200);
  }

  @override
  Future<CallToken> issueToken({
    required Uri apiBaseUri,
    required String callId,
    required String participantIdentity,
    required String participantName,
  }) async {
    final response = await _client.post(
      apiBaseUri.resolve('/api/calls/$callId/token'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'participant_identity': participantIdentity,
        'participant_name': participantName,
      }),
    );
    final decoded = _decodeObject(response, expectedStatus: 200);
    final rawServerUrl = decoded['server_url'];
    final rawToken = decoded['participant_token'];
    final rawExpiresAt = decoded['expires_at'];
    if (rawServerUrl is! String ||
        rawToken is! String ||
        rawExpiresAt is! String) {
      throw const FormatException('Call token response is invalid');
    }
    final serverUrl = Uri.parse(rawServerUrl);
    if (!serverUrl.isAbsolute ||
        (serverUrl.scheme != 'ws' && serverUrl.scheme != 'wss') ||
        rawToken.isEmpty) {
      throw const FormatException('Call token credentials are invalid');
    }
    return CallToken(
      serverUrl: serverUrl,
      participantToken: rawToken,
      expiresAt: DateTime.parse(rawExpiresAt),
    );
  }

  CallSession _decodeCall(
    http.Response response, {
    required int expectedStatus,
  }) {
    return CallSession.fromJson(
      _decodeObject(response, expectedStatus: expectedStatus),
    );
  }

  Map<String, dynamic> _decodeObject(
    http.Response response, {
    required int expectedStatus,
  }) {
    final dynamic decoded = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body);
    if (response.statusCode != expectedStatus) {
      if (decoded is Map<String, dynamic>) {
        final rawError = decoded['error'];
        if (rawError is Map<String, dynamic>) {
          final code = rawError['code'] as String? ?? 'CALL_API_ERROR';
          final message = rawError['message'] as String? ?? 'Call API failed';
          throw CallApiException(code: code, message: message);
        }
      }
      throw CallApiException(
        code: 'HTTP_${response.statusCode}',
        message: 'Call API failed with HTTP ${response.statusCode}',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Call API response must be a JSON object');
    }
    return decoded;
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }
}

final class CallApiException implements Exception {
  const CallApiException({required this.code, required this.message});

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}
