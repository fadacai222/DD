import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/security/dd_secure_storage.dart';

final class StoredAuthSession {
  const StoredAuthSession({required this.origin, required this.refreshToken});

  final Uri origin;
  final String refreshToken;
}

final class AuthSessionVault {
  AuthSessionVault({SecureKeyValueStore? storage})
    : _storage = storage ?? DdSecureStorage.shared;

  static const _bundleKey = 'dd.auth.session.v2';
  static const _legacyOriginKey = 'dd.auth.origin';
  static const _legacyRefreshKey = 'dd.auth.refresh';

  final SecureKeyValueStore _storage;

  Future<void> save({required Uri origin, required String refreshToken}) async {
    if (kIsWeb || refreshToken.isEmpty) return;
    await _storage.write(
      _bundleKey,
      jsonEncode({
        'version': 2,
        'loggedOut': false,
        'origin': origin.toString(),
        'refreshToken': refreshToken,
      }),
    );
  }

  Future<StoredAuthSession?> read() async {
    if (kIsWeb) return null;
    final bundled = await _storage.read(_bundleKey);
    if (bundled != null) {
      return _decodeBundle(bundled);
    }

    // One-time compatibility path for sessions persisted before v2. Keep the
    // legacy keys untouched; once the bundle exists they are never consulted
    // again, avoiding extra writes/deletes against the shared Windows store.
    final originRaw = await _storage.read(_legacyOriginKey);
    final refreshToken = await _storage.read(_legacyRefreshKey);
    final origin = originRaw == null ? null : Uri.tryParse(originRaw);
    if (origin == null || refreshToken == null || refreshToken.isEmpty) {
      return null;
    }
    final migrated = StoredAuthSession(
      origin: origin,
      refreshToken: refreshToken,
    );
    await save(origin: origin, refreshToken: refreshToken);
    return migrated;
  }

  Future<void> clear() async {
    if (kIsWeb) return;
    // Write a tombstone instead of deleting keys. On Windows delete still
    // performs a read-modify-write of the same encrypted file, and a durable
    // tombstone also prevents stale legacy refresh tokens from being restored.
    await _storage.write(
      _bundleKey,
      jsonEncode({'version': 2, 'loggedOut': true}),
    );
  }

  StoredAuthSession? _decodeBundle(String raw) {
    if (raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['loggedOut'] == true) return null;
      final originRaw = decoded['origin'];
      final refreshToken = decoded['refreshToken'];
      final origin = originRaw is String ? Uri.tryParse(originRaw) : null;
      if (origin == null ||
          refreshToken is! String ||
          refreshToken.trim().isEmpty) {
        return null;
      }
      return StoredAuthSession(origin: origin, refreshToken: refreshToken);
    } catch (_) {
      return null;
    }
  }
}
