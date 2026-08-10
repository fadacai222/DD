import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/call_session.dart';
import '../domain/call_token.dart';
import 'call_session_api.dart';

export 'call_session_api.dart';

class CallApiException implements Exception {
  const CallApiException({required this.code, required this.message});

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

class HttpCallSessionApi implements CallSessionApi {
  factory HttpCallSessionApi({
    http.Client? client,
    Future<String?> Function()? accessTokenProvider,
  }) => HttpCallSessionApi._(
    client ?? http.Client(),
    accessTokenProvider,
  );

  HttpCallSessionApi._(this._client, this._accessTokenProvider);

  final http.Client _client;
  final Future<String?> Function()? _accessTokenProvider;

  bool get _formal => _accessTokenProvider != null;

  @override
  Future<CallSession> createCall({
    required Uri apiBaseUri,
    required String callerIdentity,
    required String callerName,
    required String calleeIdentity,
    required CallKind kind,
  }) async {
    final response = await _client.post(
      _resolve(apiBaseUri, _formal ? '/api/v1/calls' : '/api/calls'),
      headers: await _jsonHeaders(),
      body: jsonEncode(
        _formal
            ? {
                'calleeUserId': calleeIdentity,
                'kind': kind.name,
              }
            : {
                'caller_identity': callerIdentity,
                'caller_name': callerName,
                'callee_identity': calleeIdentity,
                'kind': kind.name,
              },
      ),
    );
    return _decodeSessionResponse(response, expectedStatus: 201);
  }

  Future<CallSession?> activeCall({
    required Uri apiBaseUri,
    required String participantIdentity,
  }) async {
    final uri = _formal
        ? _resolve(apiBaseUri, '/api/v1/calls/active')
        : _resolve(apiBaseUri, '/api/calls/active').replace(
            queryParameters: {'participant_identity': participantIdentity},
          );
    final response = await _client.get(uri, headers: await _headers());
    if (response.statusCode == 204) return null;
    return _decodeSessionResponse(response, expectedStatus: 200);
  }

  @override
  Future<CallSession> applyAction({
    required Uri apiBaseUri,
    required String callId,
    required String participantIdentity,
    required String action,
  }) async {
    final path = _formal
        ? '/api/v1/calls/${Uri.encodeComponent(callId)}/actions'
        : '/api/calls/${Uri.encodeComponent(callId)}/actions';
    final response = await _client.post(
      _resolve(apiBaseUri, path),
      headers: await _jsonHeaders(),
      body: jsonEncode(
        _formal
            ? {'action': action}
            : {
                'participant_identity': participantIdentity,
                'action': action,
              },
      ),
    );
    return _decodeSessionResponse(response, expectedStatus: 200);
  }

  Future<CallToken> issueJoinToken({
    required Uri apiBaseUri,
    required String callId,
    required String participantIdentity,
    required String participantName,
  }) async {
    final path = _formal
        ? '/api/v1/calls/${Uri.encodeComponent(callId)}/token'
        : '/api/calls/${Uri.encodeComponent(callId)}/token';
    final response = await _client.post(
      _resolve(apiBaseUri, path),
      headers: _formal ? await _headers() : await _jsonHeaders(),
      body: _formal
          ? null
          : jsonEncode({
              'participant_identity': participantIdentity,
              'participant_name': participantName,
            }),
    );
    if (response.statusCode != 200) {
      throw _decodeApiError(response);
    }
    final raw = _decodePayload(response);
    final payload = _formal && raw['data'] is Map ? _unwrapData(raw) : raw;
    if (_formal) {
      final serverURL = Uri.tryParse(payload['server_url']?.toString() ?? '');
      final token = payload['token']?.toString() ?? '';
      final expiresIn = payload['expires_in_seconds'];
      if (serverURL == null ||
          !serverURL.isAbsolute ||
          token.isEmpty ||
          expiresIn is! num ||
          expiresIn.toInt() <= 0) {
        throw const CallApiException(
          code: 'INVALID_RESPONSE',
          message: 'Call API returned malformed join credentials.',
        );
      }
      return CallToken(
        serverUrl: serverURL,
        participantToken: token,
        expiresAt: DateTime.now().toUtc().add(Duration(seconds: expiresIn.toInt())),
      );
    }
    final serverURL = Uri.tryParse(payload['server_url']?.toString() ?? '');
    final token = payload['participant_token']?.toString() ?? '';
    final expiresAt = DateTime.tryParse(payload['expires_at']?.toString() ?? '');
    if (serverURL == null || !serverURL.isAbsolute || token.isEmpty || expiresAt == null) {
      throw const CallApiException(
        code: 'INVALID_RESPONSE',
        message: 'Legacy Call API returned malformed join credentials.',
      );
    }
    return CallToken(
      serverUrl: serverURL,
      participantToken: token,
      expiresAt: expiresAt.toUtc(),
    );
  }

  @override
  Future<CallSession?> fetchActiveCall({
    required Uri apiBaseUri,
    required String participantIdentity,
  }) => activeCall(
    apiBaseUri: apiBaseUri,
    participantIdentity: participantIdentity,
  );

  @override
  Future<CallToken> issueToken({
    required Uri apiBaseUri,
    required String callId,
    required String participantIdentity,
    required String participantName,
  }) => issueJoinToken(
    apiBaseUri: apiBaseUri,
    callId: callId,
    participantIdentity: participantIdentity,
    participantName: participantName,
  );

  Future<Map<String, String>> _headers() async {
    if (!_formal) return const {};
    final token = (await _accessTokenProvider?.call())?.trim() ?? '';
    if (token.isEmpty) {
      throw const CallApiException(
        code: 'AUTH_REQUIRED',
        message: '当前登录状态已失效，无法继续通话。',
      );
    }
    return {'Authorization': 'Bearer $token'};
  }

  Future<Map<String, String>> _jsonHeaders() async => {
    ...await _headers(),
    'Content-Type': 'application/json',
  };

  CallSession _decodeSessionResponse(
    http.Response response, {
    required int expectedStatus,
  }) {
    if (response.statusCode != expectedStatus) {
      throw _decodeApiError(response);
    }
    final raw = _decodePayload(response);
    return CallSession.fromJson(_formal ? _unwrapData(raw) : raw);
  }

  Map<String, dynamic> _unwrapData(Map<String, dynamic> payload) {
    final data = payload['data'];
    if (data is! Map) {
      throw const CallApiException(
        code: 'INVALID_RESPONSE',
        message: 'Call API returned malformed data envelope.',
      );
    }
    return data.map((key, value) => MapEntry(key.toString(), value));
  }

  CallApiException _decodeApiError(http.Response response) {
    try {
      final payload = _decodePayload(response);
      final error = payload['error'];
      if (error is Map) {
        return CallApiException(
          code: error['code']?.toString() ?? 'CALL_API_ERROR',
          message: error['message']?.toString() ??
              'Call API failed with HTTP ${response.statusCode}',
        );
      }
    } catch (_) {
      // Fall through to the stable HTTP error below.
    }
    return CallApiException(
      code: 'CALL_API_ERROR',
      message: 'Call API failed with HTTP ${response.statusCode}',
    );
  }

  Map<String, dynamic> _decodePayload(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } on FormatException {
      // Stable error below.
    }
    throw const CallApiException(
      code: 'INVALID_RESPONSE',
      message: 'Call API returned malformed JSON.',
    );
  }

  Uri _resolve(Uri base, String path) {
    var normalizedPath = base.path;
    if (normalizedPath.isEmpty) normalizedPath = '/';
    if (!normalizedPath.endsWith('/')) normalizedPath = '$normalizedPath/';
    final normalizedBase = base.replace(path: normalizedPath);
    return normalizedBase.resolve(path.replaceFirst(RegExp(r'^/+'), ''));
  }

  @override
  void close() => _client.close();
}
