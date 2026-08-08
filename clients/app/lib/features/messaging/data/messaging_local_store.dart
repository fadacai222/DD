import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/messaging_models.dart';

final class MessagingLocalState {
  const MessagingLocalState({
    required this.syncCursor,
    required this.pending,
    this.drafts = const {},
  });

  final int syncCursor;
  final List<PendingTextMessage> pending;
  final Map<String, String> drafts;
}

abstract interface class MessagingLocalStore {
  Future<MessagingLocalState> load();
  Future<void> save({
    required int syncCursor,
    required List<PendingTextMessage> pending,
    required Map<String, String> drafts,
  });
  Future<void> clear();
}

final class SecureMessagingLocalStore implements MessagingLocalStore {
  SecureMessagingLocalStore({
    required String userId,
    required String deviceId,
    FlutterSecureStorage? storage,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _key = 'dd.messaging.v1.$userId.$deviceId';

  static const int schemaVersion = 1;
  final FlutterSecureStorage _storage;
  final String _key;

  @override
  Future<MessagingLocalState> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.trim().isEmpty) {
      return const MessagingLocalState(syncCursor: 0, pending: []);
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> ||
          decoded['schemaVersion'] != schemaVersion) {
        await clear();
        return const MessagingLocalState(syncCursor: 0, pending: []);
      }
      final rawPending = decoded['pending'];
      final pending = rawPending is List
          ? rawPending
                .whereType<Map<String, dynamic>>()
                .map(PendingTextMessage.fromJson)
                .toList(growable: false)
          : <PendingTextMessage>[];
      final drafts = <String, String>{};
      final rawDrafts = decoded['drafts'];
      if (rawDrafts is Map<String, dynamic>) {
        for (final entry in rawDrafts.entries) {
          final value = entry.value;
          if (value is String && value.isNotEmpty) {
            drafts[entry.key] = value;
          }
        }
      }
      final cursor = decoded['syncCursor'];
      return MessagingLocalState(
        syncCursor: cursor is int && cursor >= 0 ? cursor : 0,
        pending: pending,
        drafts: drafts,
      );
    } catch (_) {
      await clear();
      return const MessagingLocalState(syncCursor: 0, pending: []);
    }
  }

  @override
  Future<void> save({
    required int syncCursor,
    required List<PendingTextMessage> pending,
    required Map<String, String> drafts,
  }) {
    return _storage.write(
      key: _key,
      value: jsonEncode({
        'schemaVersion': schemaVersion,
        'syncCursor': syncCursor < 0 ? 0 : syncCursor,
        'pending': pending.map((item) => item.toJson()).toList(growable: false),
        'drafts': drafts,
      }),
    );
  }

  @override
  Future<void> clear() => _storage.delete(key: _key);
}
