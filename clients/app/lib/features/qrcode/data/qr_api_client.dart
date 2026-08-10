import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../auth/data/auth_api_client.dart';
import '../../auth/data/auth_http_client.dart';
import '../../auth/domain/auth_session.dart';
import '../../groups/domain/group_models.dart';

final class QrPayloadData {
  const QrPayloadData({required this.type, required this.value});

  factory QrPayloadData.fromJson(Map<String, dynamic> json) => QrPayloadData(
    type: json['type'] as String? ?? '',
    value: json['value'] as String? ?? '',
  );

  final String type;
  final String value;
}

final class GroupQrInviteData {
  const GroupQrInviteData({
    required this.id,
    required this.groupId,
    required this.payload,
    required this.createdAt,
    required this.expiresAt,
    required this.useCount,
    this.maxUses,
  });

  factory GroupQrInviteData.fromJson(Map<String, dynamic> json) =>
      GroupQrInviteData(
        id: json['id'] as String? ?? '',
        groupId: json['groupId'] as String? ?? '',
        payload: json['payload'] as String? ?? '',
        createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
        expiresAt: DateTime.parse(json['expiresAt'] as String).toUtc(),
        useCount: (json['useCount'] as num?)?.toInt() ?? 0,
        maxUses: (json['maxUses'] as num?)?.toInt(),
      );

  final String id;
  final String groupId;
  final String payload;
  final DateTime createdAt;
  final DateTime expiresAt;
  final int useCount;
  final int? maxUses;
}

final class QrLoginState {
  const QrLoginState({
    required this.status,
    required this.device,
    required this.expiresAt,
    this.nonce,
    this.payload,
    this.scannedAt,
    this.confirmedAt,
  });

  factory QrLoginState.fromJson(Map<String, dynamic> json) => QrLoginState(
    status: json['status'] as String? ?? '',
    device: AuthDeviceInput.fromJson(json['device'] as Map<String, dynamic>),
    nonce: json['nonce'] as String?,
    payload: json['payload'] as String?,
    expiresAt: DateTime.parse(json['expiresAt'] as String).toUtc(),
    scannedAt: json['scannedAt'] == null
        ? null
        : DateTime.parse(json['scannedAt'] as String).toUtc(),
    confirmedAt: json['confirmedAt'] == null
        ? null
        : DateTime.parse(json['confirmedAt'] as String).toUtc(),
  );

  final String status;
  final AuthDeviceInput device;
  final String? nonce;
  final String? payload;
  final DateTime expiresAt;
  final DateTime? scannedAt;
  final DateTime? confirmedAt;
}

abstract interface class QrGateway {
  Future<QrPayloadData> myQr({
    required Uri origin,
    required String accessToken,
  });

  Future<GroupQrInviteData> createGroupInvite({
    required Uri origin,
    required String accessToken,
    required String groupId,
    int expiresInSeconds = 86400,
    int? maxUses,
  });

  Future<void> revokeGroupInvite({
    required Uri origin,
    required String accessToken,
    required String inviteId,
  });

  Future<GroupInfo> redeemGroupInvite({
    required Uri origin,
    required String accessToken,
    required String nonce,
  });

  Future<QrLoginState> createLogin({
    required Uri origin,
    required AuthDeviceInput device,
  });

  Future<QrLoginState> loginStatus({
    required Uri origin,
    required String nonce,
  });

  Future<QrLoginState> scanLogin({
    required Uri origin,
    required String accessToken,
    required String nonce,
  });

  Future<QrLoginState> confirmLogin({
    required Uri origin,
    required String accessToken,
    required String nonce,
    required bool approved,
  });

  Future<AuthSession> consumeLogin({
    required Uri origin,
    required String nonce,
  });

  void close();
}

final class QrApiClient implements QrGateway {
  QrApiClient({http.Client? httpClient})
    : _client = httpClient ?? createAuthHttpClient(),
      _ownsClient = httpClient == null;

  final http.Client _client;
  final bool _ownsClient;

  @override
  Future<QrPayloadData> myQr({
    required Uri origin,
    required String accessToken,
  }) async => QrPayloadData.fromJson(
    _decodeData(
      await _client.get(
        normalizeAuthOrigin(origin).resolve('/api/v1/qr/me'),
        headers: _headers(accessToken),
      ),
      const {200},
    ),
  );

  @override
  Future<GroupQrInviteData> createGroupInvite({
    required Uri origin,
    required String accessToken,
    required String groupId,
    int expiresInSeconds = 86400,
    int? maxUses,
  }) async => GroupQrInviteData.fromJson(
    _decodeData(
      await _client.post(
        normalizeAuthOrigin(origin).resolve('/api/v1/group-qr-invites'),
        headers: _jsonHeaders(accessToken),
        body: jsonEncode({
          'groupId': groupId,
          'expiresInSeconds': expiresInSeconds,
          'maxUses': ?maxUses,
        }),
      ),
      const {201},
    ),
  );

  @override
  Future<void> revokeGroupInvite({
    required Uri origin,
    required String accessToken,
    required String inviteId,
  }) async {
    _decodeData(
      await _client.delete(
        normalizeAuthOrigin(
          origin,
        ).resolve('/api/v1/group-qr-invites/$inviteId'),
        headers: _headers(accessToken),
      ),
      const {200},
    );
  }

  @override
  Future<GroupInfo> redeemGroupInvite({
    required Uri origin,
    required String accessToken,
    required String nonce,
  }) async {
    final data = _decodeData(
      await _client.post(
        normalizeAuthOrigin(origin).resolve('/api/v1/group-qr/redeem'),
        headers: _jsonHeaders(accessToken),
        body: jsonEncode({'nonce': nonce}),
      ),
      const {200},
    );
    final group = data['group'];
    if (group is! Map<String, dynamic>) {
      throw const FormatException('群二维码响应格式错误。');
    }
    return GroupInfo.fromJson(group);
  }

  @override
  Future<QrLoginState> createLogin({
    required Uri origin,
    required AuthDeviceInput device,
  }) async => QrLoginState.fromJson(
    _decodeData(
      await _client.post(
        normalizeAuthOrigin(origin).resolve('/api/v1/qr-login'),
        headers: const {'Content-Type': 'application/json; charset=utf-8'},
        body: jsonEncode({'device': device.toJson()}),
      ),
      const {201},
    ),
  );

  @override
  Future<QrLoginState> loginStatus({
    required Uri origin,
    required String nonce,
  }) async => QrLoginState.fromJson(
    _decodeData(
      await _client.post(
        normalizeAuthOrigin(origin).resolve('/api/v1/qr-login/status'),
        headers: const {'Content-Type': 'application/json; charset=utf-8'},
        body: jsonEncode({'nonce': nonce}),
      ),
      const {200},
    ),
  );

  @override
  Future<QrLoginState> scanLogin({
    required Uri origin,
    required String accessToken,
    required String nonce,
  }) async => QrLoginState.fromJson(
    _decodeData(
      await _client.post(
        normalizeAuthOrigin(origin).resolve('/api/v1/qr-login/scan'),
        headers: _jsonHeaders(accessToken),
        body: jsonEncode({'nonce': nonce}),
      ),
      const {200},
    ),
  );

  @override
  Future<QrLoginState> confirmLogin({
    required Uri origin,
    required String accessToken,
    required String nonce,
    required bool approved,
  }) async => QrLoginState.fromJson(
    _decodeData(
      await _client.post(
        normalizeAuthOrigin(origin).resolve('/api/v1/qr-login/confirm'),
        headers: _jsonHeaders(accessToken),
        body: jsonEncode({'nonce': nonce, 'approved': approved}),
      ),
      const {200},
    ),
  );

  @override
  Future<AuthSession> consumeLogin({
    required Uri origin,
    required String nonce,
  }) async {
    final data = _decodeData(
      await _client.post(
        normalizeAuthOrigin(origin).resolve('/api/v1/qr-login/consume'),
        headers: const {'Content-Type': 'application/json; charset=utf-8'},
        body: jsonEncode({'nonce': nonce}),
      ),
      const {200},
    );
    final session = data['session'];
    if (session is! Map<String, dynamic>) {
      throw const FormatException('扫码登录响应格式错误。');
    }
    return AuthSession.fromJson(session);
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
      var code = 'QR_HTTP_${response.statusCode}';
      var message = '二维码服务请求失败（HTTP ${response.statusCode}）。';
      if (decoded is Map<String, dynamic>) {
        final rawError = decoded['error'];
        if (rawError is Map<String, dynamic>) {
          code = rawError['code'] as String? ?? code;
          message = rawError['message'] as String? ?? message;
        }
      }
      throw QrApiException(
        statusCode: response.statusCode,
        code: code,
        message: message,
      );
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['data'] is! Map<String, dynamic>) {
      throw const FormatException('二维码服务响应格式错误。');
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

final class QrApiException implements Exception {
  const QrApiException({
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
