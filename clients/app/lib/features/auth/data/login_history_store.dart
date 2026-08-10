import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'login_history_backend_stub.dart'
    if (dart.library.io) 'login_history_backend_io.dart';

final class LoginHistoryEntry {
  const LoginHistoryEntry({
    required this.origin,
    required this.userId,
    required this.email,
    required this.ddid,
    required this.displayName,
    required this.lastUsedAt,
    this.avatarBytes,
  });

  factory LoginHistoryEntry.fromJson(Map<String, dynamic> json) {
    final avatar = json['avatarBase64'];
    return LoginHistoryEntry(
      origin: Uri.parse(json['origin'] as String),
      userId: json['userId'] as String,
      email: json['email'] as String,
      ddid: json['ddid'] as String,
      displayName: json['displayName'] as String,
      lastUsedAt: DateTime.parse(json['lastUsedAt'] as String).toUtc(),
      avatarBytes: avatar is String && avatar.isNotEmpty
          ? base64Decode(avatar)
          : null,
    );
  }

  final Uri origin;
  final String userId;
  final String email;
  final String ddid;
  final String displayName;
  final DateTime lastUsedAt;
  final Uint8List? avatarBytes;

  Map<String, dynamic> toJson() => {
    'origin': origin.toString(),
    'userId': userId,
    'email': email,
    'ddid': ddid,
    'displayName': displayName,
    'lastUsedAt': lastUsedAt.toUtc().toIso8601String(),
    if (avatarBytes != null && avatarBytes!.isNotEmpty)
      'avatarBase64': base64Encode(avatarBytes!),
  };
}

abstract interface class LoginHistoryRepository {
  Future<List<LoginHistoryEntry>> list();
  Future<void> upsert(LoginHistoryEntry entry);
  Future<void> remove(LoginHistoryEntry entry);
}

final class LoginHistoryStore implements LoginHistoryRepository {
  LoginHistoryStore();

  static Future<void> _tail = Future<void>.value();

  @override
  Future<List<LoginHistoryEntry>> list() async {
    try {
      final raw = await readLoginHistoryFile();
      if (raw == null || raw.trim().isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const [];
      final entries = decoded['entries'];
      if (entries is! List) return const [];
      final result = <LoginHistoryEntry>[];
      for (final rawEntry in entries.whereType<Map<String, dynamic>>()) {
        try {
          result.add(LoginHistoryEntry.fromJson(rawEntry));
        } catch (_) {
          // Skip only the damaged history row; do not lose other accounts.
        }
      }
      result.sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt));
      return List.unmodifiable(result.take(5));
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> upsert(LoginHistoryEntry entry) => _enqueue(() async {
    final current = await list();
    final next = <LoginHistoryEntry>[
      entry,
      ...current.where(
        (item) =>
            item.userId != entry.userId ||
            item.origin.origin != entry.origin.origin,
      ),
    ].take(5).toList(growable: false);
    await writeLoginHistoryFile(
      jsonEncode({
        'version': 1,
        'entries': next.map((e) => e.toJson()).toList(),
      }),
    );
  });

  @override
  Future<void> remove(LoginHistoryEntry entry) => _enqueue(() async {
    final current = await list();
    final next = current
        .where(
          (item) =>
              item.userId != entry.userId ||
              item.origin.origin != entry.origin.origin,
        )
        .toList(growable: false);
    await writeLoginHistoryFile(
      jsonEncode({
        'version': 1,
        'entries': next.map((e) => e.toJson()).toList(),
      }),
    );
  });

  Future<void> _enqueue(Future<void> Function() action) {
    final completer = Completer<void>();
    final previous = _tail;
    _tail = () async {
      try {
        await previous;
      } catch (_) {}
      try {
        await action();
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }();
    return completer.future;
  }
}
