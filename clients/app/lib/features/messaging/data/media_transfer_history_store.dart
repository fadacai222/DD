import 'dart:convert';

import '../../../core/security/dd_secure_storage.dart';

final class MediaTransferHistoryStore {
  MediaTransferHistoryStore({
    required String userId,
    SecureKeyValueStore? storage,
  }) : _userId = userId.trim(),
       _storage = storage ?? DdSecureStorage.shared;

  final String _userId;
  final SecureKeyValueStore _storage;

  String get _key => 'dd.media.transfer-history.v1.$_userId';

  Future<List<Map<String, dynamic>>> load() async {
    if (_userId.isEmpty) return const [];
    final raw = await _storage.read(_key);
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map(
            (item) => <String, dynamic>{
              for (final entry in item.entries)
                entry.key.toString(): entry.value,
            },
          )
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(List<Map<String, Object?>> records) async {
    if (_userId.isEmpty) return;
    await _storage.write(_key, jsonEncode(records));
  }

  Future<void> clear() async {
    if (_userId.isEmpty) return;
    await _storage.delete(_key);
  }
}
