import 'dart:convert';

import '../../../core/security/dd_secure_storage.dart';
import '../domain/messaging_models.dart';

final class MessagingLocalState {
  const MessagingLocalState({
    required this.syncCursor,
    required this.pending,
    this.drafts = const {},
    this.recentEmoji = const [],
    this.heardVoiceMessageIds = const [],
  });

  final int syncCursor;
  final List<PendingTextMessage> pending;
  final Map<String, String> drafts;
  final List<String> recentEmoji;
  final List<String> heardVoiceMessageIds;
}

abstract interface class MessagingLocalStore {
  Future<MessagingLocalState> load();
  Future<void> save({
    required int syncCursor,
    required List<PendingTextMessage> pending,
    required Map<String, String> drafts,
    required List<String> recentEmoji,
    required List<String> heardVoiceMessageIds,
  });
  Future<void> clear();
}

final class SecureMessagingLocalStore implements MessagingLocalStore {
  SecureMessagingLocalStore({
    required String userId,
    required String deviceId,
    SecureKeyValueStore? storage,
  }) : _storage = storage ?? DdSecureStorage.shared,
       _key = 'dd.messaging.v1.$userId.$deviceId';

  static const int schemaVersion = 3;
  final SecureKeyValueStore _storage;
  final String _key;

  @override
  Future<MessagingLocalState> load() async {
    final raw = await _storage.read(_key);
    if (raw == null || raw.trim().isEmpty) {
      return const MessagingLocalState(syncCursor: 0, pending: []);
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        await clear();
        return const MessagingLocalState(syncCursor: 0, pending: []);
      }
      final storedVersion = decoded['schemaVersion'];
      if (storedVersion is! int ||
          storedVersion < 1 ||
          storedVersion > schemaVersion) {
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
      final recentEmoji = <String>[];
      final rawRecentEmoji = decoded['recentEmoji'];
      if (rawRecentEmoji is List) {
        for (final item in rawRecentEmoji.whereType<String>()) {
          if (item.trim().isEmpty || recentEmoji.contains(item)) continue;
          recentEmoji.add(item);
          if (recentEmoji.length == 12) break;
        }
      }
      final heardVoiceMessageIds = <String>[];
      final rawHeardVoiceMessageIds = decoded['heardVoiceMessageIds'];
      if (rawHeardVoiceMessageIds is List) {
        for (final item in rawHeardVoiceMessageIds.whereType<String>()) {
          final id = item.trim();
          if (id.isEmpty || heardVoiceMessageIds.contains(id)) continue;
          heardVoiceMessageIds.add(id);
          if (heardVoiceMessageIds.length == 500) break;
        }
      }
      final cursor = decoded['syncCursor'];
      return MessagingLocalState(
        syncCursor: cursor is int && cursor >= 0 ? cursor : 0,
        pending: pending,
        drafts: drafts,
        recentEmoji: List.unmodifiable(recentEmoji),
        heardVoiceMessageIds: List.unmodifiable(heardVoiceMessageIds),
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
    required List<String> recentEmoji,
    required List<String> heardVoiceMessageIds,
  }) {
    return _storage.write(
      _key,
      jsonEncode({
        'schemaVersion': schemaVersion,
        'syncCursor': syncCursor < 0 ? 0 : syncCursor,
        'pending': pending.map((item) => item.toJson()).toList(growable: false),
        'drafts': drafts,
        'recentEmoji': recentEmoji.take(12).toList(growable: false),
        'heardVoiceMessageIds': heardVoiceMessageIds
            .take(500)
            .toList(growable: false),
      }),
    );
  }

  @override
  Future<void> clear() => _storage.delete(_key);
}
