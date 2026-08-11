import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/security/dd_secure_storage.dart';

final class StoredAuthSession {
  const StoredAuthSession({required this.origin, required this.refreshToken});

  final Uri origin;
  final String refreshToken;
}

final class StoredAuthAccount {
  const StoredAuthAccount({
    required this.origin,
    required this.userId,
    required this.refreshToken,
    required this.updatedAt,
  });

  final Uri origin;
  final String userId;
  final String refreshToken;
  final DateTime updatedAt;
}

final class AuthSessionVault {
  AuthSessionVault({SecureKeyValueStore? storage})
    : _storage = storage ?? DdSecureStorage.shared;

  static const _bundleKey = 'dd.auth.session.v2';
  static const _accountsKey = 'dd.auth.accounts.v1';
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

  Future<void> saveAccount({
    required Uri origin,
    required String userId,
    required String refreshToken,
  }) async {
    if (kIsWeb || userId.trim().isEmpty || refreshToken.trim().isEmpty) return;
    final now = DateTime.now().toUtc();
    final current = await readAccounts();
    final next = <StoredAuthAccount>[
      StoredAuthAccount(
        origin: origin,
        userId: userId.trim(),
        refreshToken: refreshToken,
        updatedAt: now,
      ),
      ...current.where(
        (item) => !_sameAccount(item.origin, item.userId, origin, userId),
      ),
    ].take(8).toList(growable: false);
    await _storage.write(
      _accountsKey,
      jsonEncode({
        'version': 1,
        'accounts': [
          for (final account in next)
            {
              'origin': account.origin.toString(),
              'userId': account.userId,
              'refreshToken': account.refreshToken,
              'updatedAt': account.updatedAt.toIso8601String(),
            },
        ],
      }),
    );
  }

  Future<List<StoredAuthAccount>> readAccounts() async {
    if (kIsWeb) return const [];
    final raw = await _storage.read(_accountsKey);
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const [];
      final rows = decoded['accounts'];
      if (rows is! List) return const [];
      final result = <StoredAuthAccount>[];
      for (final row in rows.whereType<Map>()) {
        final originRaw = row['origin'];
        final userId = row['userId'];
        final refreshToken = row['refreshToken'];
        final updatedAtRaw = row['updatedAt'];
        final origin = originRaw is String ? Uri.tryParse(originRaw) : null;
        final updatedAt = updatedAtRaw is String
            ? DateTime.tryParse(updatedAtRaw)?.toUtc()
            : null;
        if (origin == null ||
            userId is! String ||
            userId.trim().isEmpty ||
            refreshToken is! String ||
            refreshToken.trim().isEmpty) {
          continue;
        }
        result.add(
          StoredAuthAccount(
            origin: origin,
            userId: userId.trim(),
            refreshToken: refreshToken,
            updatedAt: updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          ),
        );
      }
      result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return List.unmodifiable(result.take(8));
    } catch (_) {
      return const [];
    }
  }

  Future<StoredAuthAccount?> readAccount({
    required Uri origin,
    required String userId,
  }) async {
    final accounts = await readAccounts();
    for (final account in accounts) {
      if (_sameAccount(account.origin, account.userId, origin, userId)) {
        return account;
      }
    }
    return null;
  }

  Future<void> removeAccount({
    required Uri origin,
    required String userId,
  }) async {
    if (kIsWeb) return;
    final current = await readAccounts();
    final next = current
        .where((item) => !_sameAccount(item.origin, item.userId, origin, userId))
        .toList(growable: false);
    await _storage.write(
      _accountsKey,
      jsonEncode({
        'version': 1,
        'accounts': [
          for (final account in next)
            {
              'origin': account.origin.toString(),
              'userId': account.userId,
              'refreshToken': account.refreshToken,
              'updatedAt': account.updatedAt.toIso8601String(),
            },
        ],
      }),
    );
  }

  bool _sameAccount(Uri leftOrigin, String leftUserId, Uri rightOrigin, String rightUserId) =>
      leftUserId == rightUserId && leftOrigin.origin == rightOrigin.origin;

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
