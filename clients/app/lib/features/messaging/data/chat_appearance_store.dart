import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/security/dd_secure_storage.dart';
import 'chat_wallpaper_asset_store.dart';
import 'chat_wallpaper_processor.dart';

enum ChatWallpaperKind { system, solid, custom }

final class ChatWallpaper {
  const ChatWallpaper.system()
    : kind = ChatWallpaperKind.system,
      colorValue = null,
      assetReference = null;

  const ChatWallpaper.solid(this.colorValue)
    : kind = ChatWallpaperKind.solid,
      assetReference = null;

  const ChatWallpaper.custom(this.assetReference)
    : kind = ChatWallpaperKind.custom,
      colorValue = null;

  factory ChatWallpaper.fromJson(Map<String, dynamic> json) {
    return switch (json['kind']) {
      'solid' when json['colorValue'] is int => ChatWallpaper.solid(
        json['colorValue'] as int,
      ),
      'custom'
          when json['assetReference'] is String &&
              (json['assetReference'] as String).isNotEmpty =>
        ChatWallpaper.custom(json['assetReference'] as String),
      _ => const ChatWallpaper.system(),
    };
  }

  final ChatWallpaperKind kind;
  final int? colorValue;
  final String? assetReference;

  Map<String, dynamic> toJson() => switch (kind) {
    ChatWallpaperKind.system => const <String, dynamic>{'kind': 'system'},
    ChatWallpaperKind.solid => <String, dynamic>{
      'kind': 'solid',
      'colorValue': colorValue,
    },
    ChatWallpaperKind.custom => <String, dynamic>{
      'kind': 'custom',
      'assetReference': assetReference,
    },
  };
}

final class ChatAppearanceState {
  const ChatAppearanceState({
    this.globalWallpaper = const ChatWallpaper.system(),
    this.conversationWallpapers = const {},
  });

  final ChatWallpaper globalWallpaper;
  final Map<String, ChatWallpaper> conversationWallpapers;

  ChatWallpaper resolve(String conversationId) =>
      conversationWallpapers[conversationId] ?? globalWallpaper;
}

final class ChatAppearanceStore extends ChangeNotifier {
  ChatAppearanceStore({
    required this.userId,
    SecureKeyValueStore? storage,
    ChatWallpaperAssetStore? assetStore,
  }) : _storage = storage ?? DdSecureStorage.shared,
       _assetStore = assetStore ?? createChatWallpaperAssetStore(userId);

  static final Map<String, ChatAppearanceStore> _shared = {};

  static ChatAppearanceStore shared(String userId) =>
      _shared.putIfAbsent(userId, () => ChatAppearanceStore(userId: userId));

  final String userId;
  final SecureKeyValueStore _storage;
  final ChatWallpaperAssetStore _assetStore;
  ChatAppearanceState _state = const ChatAppearanceState();
  bool _loaded = false;
  Future<void>? _loading;

  String get _key => 'dd.chat.appearance.v1.$userId';
  ChatAppearanceState get state => _state;
  bool get loaded => _loaded;

  Future<void> load() {
    if (_loaded) return Future.value();
    return _loading ??= _loadInternal();
  }

  Future<void> _loadInternal() async {
    try {
      final raw = await _storage.read(_key);
      if (raw == null || raw.trim().isEmpty) {
        _state = const ChatAppearanceState();
      } else {
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) throw const FormatException();
        final globalRaw = decoded['global'];
        final conversationsRaw = decoded['conversations'];
        final conversations = <String, ChatWallpaper>{};
        if (conversationsRaw is Map<String, dynamic>) {
          for (final entry in conversationsRaw.entries) {
            final value = entry.value;
            if (value is Map<String, dynamic>) {
              conversations[entry.key] = ChatWallpaper.fromJson(value);
            }
          }
        }
        _state = ChatAppearanceState(
          globalWallpaper: globalRaw is Map<String, dynamic>
              ? ChatWallpaper.fromJson(globalRaw)
              : const ChatWallpaper.system(),
          conversationWallpapers: Map.unmodifiable(conversations),
        );
      }
    } catch (_) {
      _state = const ChatAppearanceState();
    } finally {
      _loaded = true;
      _loading = null;
      notifyListeners();
    }
  }

  Future<Uint8List?> bytesFor(ChatWallpaper wallpaper) async {
    final reference = wallpaper.assetReference;
    if (wallpaper.kind != ChatWallpaperKind.custom || reference == null) {
      return null;
    }
    return _assetStore.read(reference);
  }

  Future<void> setGlobalSystem() => _setGlobal(const ChatWallpaper.system());

  Future<void> setGlobalSolid(int colorValue) =>
      _setGlobal(ChatWallpaper.solid(colorValue));

  Future<void> setGlobalCustom(Uint8List source) async {
    final bytes = await processChatWallpaper(source);
    final reference = await _assetStore.save(bytes);
    await _setGlobal(ChatWallpaper.custom(reference));
  }

  Future<void> setConversationSystem(String conversationId) =>
      _setConversation(conversationId, const ChatWallpaper.system());

  Future<void> setConversationSolid(String conversationId, int colorValue) =>
      _setConversation(conversationId, ChatWallpaper.solid(colorValue));

  Future<void> setConversationCustom(
    String conversationId,
    Uint8List source,
  ) async {
    final bytes = await processChatWallpaper(source);
    final reference = await _assetStore.save(bytes);
    await _setConversation(conversationId, ChatWallpaper.custom(reference));
  }

  Future<void> followGlobal(String conversationId) async {
    await load();
    final old = _state.conversationWallpapers[conversationId];
    if (old == null) return;
    final next = Map<String, ChatWallpaper>.of(_state.conversationWallpapers)
      ..remove(conversationId);
    _state = ChatAppearanceState(
      globalWallpaper: _state.globalWallpaper,
      conversationWallpapers: Map.unmodifiable(next),
    );
    await _persist();
    await _deleteIfOrphan(old.assetReference);
    notifyListeners();
  }

  Future<void> _setGlobal(ChatWallpaper wallpaper) async {
    await load();
    final old = _state.globalWallpaper;
    _state = ChatAppearanceState(
      globalWallpaper: wallpaper,
      conversationWallpapers: _state.conversationWallpapers,
    );
    await _persist();
    await _deleteIfOrphan(old.assetReference);
    notifyListeners();
  }

  Future<void> _setConversation(
    String conversationId,
    ChatWallpaper wallpaper,
  ) async {
    await load();
    final old = _state.conversationWallpapers[conversationId];
    final next = Map<String, ChatWallpaper>.of(_state.conversationWallpapers)
      ..[conversationId] = wallpaper;
    _state = ChatAppearanceState(
      globalWallpaper: _state.globalWallpaper,
      conversationWallpapers: Map.unmodifiable(next),
    );
    await _persist();
    await _deleteIfOrphan(old?.assetReference);
    notifyListeners();
  }

  Future<void> _persist() => _storage.write(
    _key,
    jsonEncode({
      'version': 1,
      'global': _state.globalWallpaper.toJson(),
      'conversations': <String, dynamic>{
        for (final entry in _state.conversationWallpapers.entries)
          entry.key: entry.value.toJson(),
      },
    }),
  );

  Future<void> _deleteIfOrphan(String? reference) async {
    if (reference == null || reference.isEmpty) return;
    if (_state.globalWallpaper.assetReference == reference) return;
    if (_state.conversationWallpapers.values.any(
      (wallpaper) => wallpaper.assetReference == reference,
    )) {
      return;
    }
    await _assetStore.delete(reference);
  }
}
