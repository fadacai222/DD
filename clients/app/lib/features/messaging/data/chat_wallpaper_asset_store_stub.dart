import 'dart:convert';
import 'dart:typed_data';

import '../../../core/security/dd_secure_storage.dart';

abstract interface class ChatWallpaperAssetStore {
  Future<String> save(Uint8List bytes);
  Future<Uint8List?> read(String reference);
  Future<void> delete(String reference);
}

ChatWallpaperAssetStore createChatWallpaperAssetStore(String userId) =>
    _KeyValueChatWallpaperAssetStore(userId, DdSecureStorage.shared);

final class _KeyValueChatWallpaperAssetStore
    implements ChatWallpaperAssetStore {
  _KeyValueChatWallpaperAssetStore(this.userId, this.storage);

  final String userId;
  final SecureKeyValueStore storage;

  String _key(String id) => 'dd.chat.wallpaper.asset.v1.$userId.$id';

  @override
  Future<String> save(Uint8List bytes) async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    await storage.write(_key(id), base64Encode(bytes));
    return 'kv://$id';
  }

  @override
  Future<Uint8List?> read(String reference) async {
    if (!reference.startsWith('kv://')) return null;
    final id = reference.substring(5);
    final raw = await storage.read(_key(id));
    if (raw == null || raw.isEmpty) return null;
    try {
      return Uint8List.fromList(base64Decode(raw));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> delete(String reference) async {
    if (!reference.startsWith('kv://')) return;
    final id = reference.substring(5);
    if (id.isEmpty) return;
    await storage.delete(_key(id));
  }
}
