import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

final class StoredAuthSession {
  const StoredAuthSession({required this.origin, required this.refreshToken});

  final Uri origin;
  final String refreshToken;
}

final class AuthSessionVault {
  AuthSessionVault({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _originKey = 'dd.auth.origin';
  static const _refreshKey = 'dd.auth.refresh';

  final FlutterSecureStorage _storage;

  Future<void> save({required Uri origin, required String refreshToken}) async {
    if (kIsWeb || refreshToken.isEmpty) return;
    await _storage.write(key: _originKey, value: origin.toString());
    await _storage.write(key: _refreshKey, value: refreshToken);
  }

  Future<StoredAuthSession?> read() async {
    if (kIsWeb) return null;
    final originRaw = await _storage.read(key: _originKey);
    final refreshToken = await _storage.read(key: _refreshKey);
    final origin = originRaw == null ? null : Uri.tryParse(originRaw);
    if (origin == null || refreshToken == null || refreshToken.isEmpty) {
      return null;
    }
    return StoredAuthSession(origin: origin, refreshToken: refreshToken);
  }

  Future<void> clear() async {
    if (kIsWeb) return;
    await _storage.delete(key: _originKey);
    await _storage.delete(key: _refreshKey);
  }
}
