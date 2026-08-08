final class AuthUser {
  const AuthUser({
    required this.id,
    required this.email,
    required this.handle,
    required this.displayName,
  });

  factory AuthUser.fromJson(Map<String, dynamic> json) => AuthUser(
    id: _string(json, 'id'),
    email: _string(json, 'email'),
    handle: _string(json, 'handle'),
    displayName: _string(json, 'displayName'),
  );

  final String id;
  final String email;
  final String handle;
  final String displayName;
}

final class AuthDevice {
  const AuthDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.appVersion,
  });

  factory AuthDevice.fromJson(Map<String, dynamic> json) => AuthDevice(
    id: _string(json, 'id'),
    name: _string(json, 'name'),
    platform: _string(json, 'platform'),
    appVersion: json['appVersion'] is String
        ? json['appVersion'] as String
        : '',
  );

  final String id;
  final String name;
  final String platform;
  final String appVersion;
}

final class AuthTokens {
  const AuthTokens({
    required this.accessToken,
    required this.accessExpiresAt,
    required this.refreshToken,
    required this.refreshExpiresAt,
  });

  factory AuthTokens.fromJson(Map<String, dynamic> json) => AuthTokens(
    accessToken: _string(json, 'accessToken'),
    accessExpiresAt: _date(json, 'accessExpiresAt'),
    refreshToken: json['refreshToken'] is String
        ? json['refreshToken'] as String
        : '',
    refreshExpiresAt: _date(json, 'refreshExpiresAt'),
  );

  final String accessToken;
  final DateTime accessExpiresAt;
  final String refreshToken;
  final DateTime refreshExpiresAt;
}

final class AuthSession {
  const AuthSession({
    required this.user,
    required this.device,
    required this.tokens,
  });

  factory AuthSession.fromJson(Map<String, dynamic> json) {
    final user = json['user'];
    final device = json['device'];
    final tokens = json['tokens'];
    if (user is! Map<String, dynamic> ||
        device is! Map<String, dynamic> ||
        tokens is! Map<String, dynamic>) {
      throw const FormatException('Authentication response is malformed');
    }
    return AuthSession(
      user: AuthUser.fromJson(user),
      device: AuthDevice.fromJson(device),
      tokens: AuthTokens.fromJson(tokens),
    );
  }

  final AuthUser user;
  final AuthDevice device;
  final AuthTokens tokens;
}

String _string(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value;
}

DateTime _date(Map<String, dynamic> json, String key) {
  final value = _string(json, key);
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw FormatException('$key must be an ISO date-time');
  return parsed.toUtc();
}
