import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../domain/account_management.dart';
import '../domain/auth_session.dart';
import 'auth_http_client.dart';

abstract interface class AuthGateway {
  Future<void> sendRegistrationCode({
    required Uri origin,
    required String email,
  });

  Future<AuthSession> register({
    required Uri origin,
    required String email,
    required String code,
    required String password,
    required String handle,
    required String displayName,
    required AuthDeviceInput device,
  });

  Future<AuthSession> login({
    required Uri origin,
    required String email,
    required String password,
    required AuthDeviceInput device,
  });

  Future<AuthSession> refresh({
    required Uri origin,
    required String refreshToken,
  });

  Future<void> sendPasswordResetCode({
    required Uri origin,
    required String email,
  });

  Future<void> resetPassword({
    required Uri origin,
    required String email,
    required String code,
    required String newPassword,
  });

  Future<AccountMe> getMe({required Uri origin, required String accessToken});

  Future<AccountMe> updateMe({
    required Uri origin,
    required String accessToken,
    required String handle,
    required String displayName,
    required String bio,
    required AccountPrivacy privacy,
  });

  Future<void> sendEmailChangeCode({
    required Uri origin,
    required String accessToken,
    required String email,
  });

  Future<AccountMe> changeEmail({
    required Uri origin,
    required String accessToken,
    required String email,
    required String code,
  });

  Future<DateTime> uploadProfileAvatar({
    required Uri origin,
    required String accessToken,
    required Uint8List bytes,
    required String contentType,
  });

  Future<void> deleteProfileAvatar({
    required Uri origin,
    required String accessToken,
  });

  Future<List<AccountDevice>> listDevices({
    required Uri origin,
    required String accessToken,
  });

  Future<void> revokeDevice({
    required Uri origin,
    required String accessToken,
    required String deviceId,
  });

  Future<int> clearRevokedDevices({
    required Uri origin,
    required String accessToken,
  });

  Future<void> logoutAll({required Uri origin, required String accessToken});

  void close();
}

final class AuthDeviceInput {
  const AuthDeviceInput({
    required this.name,
    required this.platform,
    this.appVersion = '',
  });

  factory AuthDeviceInput.fromJson(Map<String, dynamic> json) => AuthDeviceInput(
    name: json['name'] as String? ?? '',
    platform: json['platform'] as String? ?? '',
    appVersion: json['appVersion'] as String? ?? '',
  );

  factory AuthDeviceInput.current() {
    final platform = kIsWeb
        ? 'WEB'
        : switch (defaultTargetPlatform) {
            TargetPlatform.android => 'ANDROID',
            TargetPlatform.iOS => 'IOS',
            TargetPlatform.windows => 'WINDOWS',
            TargetPlatform.macOS => 'MACOS',
            TargetPlatform.linux => 'LINUX',
            TargetPlatform.fuchsia => 'LINUX',
          };
    final name = kIsWeb ? 'DD Web' : 'DD ${platform.toLowerCase()}';
    return AuthDeviceInput(
      name: name,
      platform: platform,
      appVersion: '0.5.0-dev',
    );
  }

  final String name;
  final String platform;
  final String appVersion;

  Map<String, dynamic> toJson() => {
    'name': name,
    'platform': platform,
    if (appVersion.isNotEmpty) 'appVersion': appVersion,
  };
}

final class AuthApiException implements Exception {
  const AuthApiException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.requestId,
  });

  final int statusCode;
  final String code;
  final String message;
  final String? requestId;

  @override
  String toString() => '$message${requestId == null ? '' : ' · $requestId'}';
}

final class AuthApiClient implements AuthGateway {
  AuthApiClient({http.Client? httpClient})
    : _client = httpClient ?? createAuthHttpClient();

  final http.Client _client;

  @override
  Future<void> sendRegistrationCode({
    required Uri origin,
    required String email,
  }) async {
    final response = await _post(
      origin,
      '/api/v1/auth/register/email/send-code',
      {'email': email, 'purpose': 'register'},
    );
    if (response.statusCode != 202) {
      throw _exception(response);
    }
  }

  @override
  Future<AuthSession> register({
    required Uri origin,
    required String email,
    required String code,
    required String password,
    required String handle,
    required String displayName,
    required AuthDeviceInput device,
  }) async {
    final response = await _post(origin, '/api/v1/auth/register', {
      'email': email,
      'code': code,
      'password': password,
      'handle': handle,
      'displayName': displayName,
      'device': device.toJson(),
    });
    return _decodeSession(response, expectedStatus: 201);
  }

  @override
  Future<AuthSession> login({
    required Uri origin,
    required String email,
    required String password,
    required AuthDeviceInput device,
  }) async {
    final response = await _post(origin, '/api/v1/auth/login', {
      'email': email,
      'password': password,
      'device': device.toJson(),
    });
    return _decodeSession(response, expectedStatus: 200);
  }

  @override
  Future<AuthSession> refresh({
    required Uri origin,
    required String refreshToken,
  }) async {
    final response = await _post(
      origin,
      '/api/v1/auth/token/refresh',
      kIsWeb ? const <String, dynamic>{} : {'refreshToken': refreshToken},
    );
    return _decodeSession(response, expectedStatus: 200);
  }

  @override
  Future<void> sendPasswordResetCode({
    required Uri origin,
    required String email,
  }) async {
    final response = await _post(
      origin,
      '/api/v1/auth/password/reset/send-code',
      {'email': email},
    );
    if (response.statusCode != 202) throw _exception(response);
  }

  @override
  Future<void> resetPassword({
    required Uri origin,
    required String email,
    required String code,
    required String newPassword,
  }) async {
    final response = await _post(origin, '/api/v1/auth/password/reset', {
      'email': email,
      'code': code,
      'newPassword': newPassword,
    });
    if (response.statusCode != 200) throw _exception(response);
  }

  @override
  Future<AccountMe> getMe({
    required Uri origin,
    required String accessToken,
  }) async {
    final response = await _authorized(origin, '/api/v1/me', accessToken);
    if (response.statusCode != 200) throw _exception(response);
    final body = _decodeObject(response.body);
    return AccountMe.fromJson(body['data'] as Map<String, dynamic>);
  }

  @override
  Future<AccountMe> updateMe({
    required Uri origin,
    required String accessToken,
    required String handle,
    required String displayName,
    required String bio,
    required AccountPrivacy privacy,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/me',
      accessToken,
      method: 'PATCH',
      body: {
        'handle': handle,
        'displayName': displayName,
        'bio': bio,
        'privacy': privacy.toJson(),
      },
    );
    if (response.statusCode != 200) throw _exception(response);
    final body = _decodeObject(response.body);
    return AccountMe.fromJson(body['data'] as Map<String, dynamic>);
  }

  @override
  Future<void> sendEmailChangeCode({
    required Uri origin,
    required String accessToken,
    required String email,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/me/email/send-code',
      accessToken,
      method: 'POST',
      body: {'email': email},
    );
    if (response.statusCode != 202) throw _exception(response);
  }

  @override
  Future<AccountMe> changeEmail({
    required Uri origin,
    required String accessToken,
    required String email,
    required String code,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/me/email',
      accessToken,
      method: 'PATCH',
      body: {'email': email, 'code': code},
    );
    if (response.statusCode != 200) throw _exception(response);
    final body = _decodeObject(response.body);
    return AccountMe.fromJson(body['data'] as Map<String, dynamic>);
  }

  @override
  Future<DateTime> uploadProfileAvatar({
    required Uri origin,
    required String accessToken,
    required Uint8List bytes,
    required String contentType,
  }) async {
    final normalizedOrigin = normalizeAuthOrigin(origin);
    final response = await _client.put(
      normalizedOrigin.resolve('/api/v1/me/avatar'),
      headers: {
        'Accept': 'application/json',
        'Authorization': 'Bearer $accessToken',
        'Content-Type': contentType,
      },
      body: bytes,
    );
    if (response.statusCode != 200) throw _exception(response);
    final body = _decodeObject(response.body);
    final data = body['data'];
    if (data is! Map<String, dynamic> || data['updatedAt'] is! String) {
      throw const FormatException('Avatar response is malformed');
    }
    return DateTime.parse(data['updatedAt'] as String);
  }

  @override
  Future<void> deleteProfileAvatar({
    required Uri origin,
    required String accessToken,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/me/avatar',
      accessToken,
      method: 'DELETE',
    );
    if (response.statusCode != 200) throw _exception(response);
  }

  @override
  Future<List<AccountDevice>> listDevices({
    required Uri origin,
    required String accessToken,
  }) async {
    final response = await _authorized(origin, '/api/v1/devices', accessToken);
    if (response.statusCode != 200) throw _exception(response);
    final body = _decodeObject(response.body);
    final data = body['data'] as Map<String, dynamic>;
    final list = data['devices'];
    if (list is! List) throw const FormatException('Device list is malformed');
    return list
        .map((item) => AccountDevice.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  @override
  Future<void> revokeDevice({
    required Uri origin,
    required String accessToken,
    required String deviceId,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/devices/$deviceId',
      accessToken,
      method: 'DELETE',
    );
    if (response.statusCode != 200) throw _exception(response);
  }

  @override
  Future<int> clearRevokedDevices({
    required Uri origin,
    required String accessToken,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/devices/revoked',
      accessToken,
      method: 'DELETE',
    );
    if (response.statusCode != 200) throw _exception(response);
    final body = _decodeObject(response.body);
    final data = body['data'];
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Device cleanup response is malformed');
    }
    final count = data['clearedCount'];
    if (count is! num || count < 0) {
      throw const FormatException('Device cleanup count is malformed');
    }
    return count.toInt();
  }

  @override
  Future<void> logoutAll({
    required Uri origin,
    required String accessToken,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/auth/logout-all',
      accessToken,
      method: 'POST',
      body: const {},
    );
    if (response.statusCode != 200) throw _exception(response);
  }

  Future<http.Response> _post(
    Uri rawOrigin,
    String path,
    Map<String, dynamic> body,
  ) {
    final origin = normalizeAuthOrigin(rawOrigin);
    return _client.post(
      origin.resolve(path),
      headers: const {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );
  }

  Future<http.Response> _authorized(
    Uri rawOrigin,
    String path,
    String accessToken, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) {
    final origin = normalizeAuthOrigin(rawOrigin);
    final request = http.Request(method, origin.resolve(path));
    request.headers.addAll({
      'Accept': 'application/json',
      'Authorization': 'Bearer $accessToken',
      if (body != null) 'Content-Type': 'application/json',
    });
    if (body != null) request.body = jsonEncode(body);
    return _client.send(request).then(http.Response.fromStream);
  }

  AuthSession _decodeSession(
    http.Response response, {
    required int expectedStatus,
  }) {
    if (response.statusCode != expectedStatus) throw _exception(response);
    final body = _decodeObject(response.body);
    final data = body['data'];
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Authentication response data is missing');
    }
    return AuthSession.fromJson(data);
  }

  AuthApiException _exception(http.Response response) {
    var code = 'HTTP_ERROR';
    var message = 'HTTP ${response.statusCode}';
    String? requestId = response.headers['x-request-id'];
    try {
      final body = _decodeObject(response.body);
      final error = body['error'];
      if (error is Map<String, dynamic>) {
        if (error['code'] case final String value when value.isNotEmpty) {
          code = value;
        }
        if (error['message'] case final String value when value.isNotEmpty) {
          message = value;
        }
        if (error['requestId'] case final String value when value.isNotEmpty) {
          requestId = value;
        }
      }
    } catch (_) {
      // Keep the generic HTTP error if a proxy returns HTML or malformed JSON.
    }
    return AuthApiException(
      statusCode: response.statusCode,
      code: code,
      message: message,
      requestId: requestId,
    );
  }

  @override
  void close() => _client.close();
}

Uri normalizeAuthOrigin(Uri uri) {
  if (!uri.isAbsolute ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw ArgumentError.value(uri, 'origin', 'must be an http/https origin');
  }
  return uri.replace(path: '', query: null, fragment: null);
}

Map<String, dynamic> _decodeObject(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('API response must be a JSON object');
  }
  return decoded;
}
