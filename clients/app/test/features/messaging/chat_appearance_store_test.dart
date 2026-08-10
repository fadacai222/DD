import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/security/dd_secure_storage.dart';
import 'package:im_client/features/messaging/data/chat_appearance_store.dart';
import 'package:im_client/features/messaging/data/chat_wallpaper_asset_store.dart';
import 'package:image/image.dart' as img;

void main() {
  test(
    'appearance preferences are account scoped and conversation can follow global',
    () async {
      final storage = _MemoryStore();
      final aliceAssets = _MemoryAssets();
      final bobAssets = _MemoryAssets();
      final alice = ChatAppearanceStore(
        userId: 'alice',
        storage: storage,
        assetStore: aliceAssets,
      );
      final bob = ChatAppearanceStore(
        userId: 'bob',
        storage: storage,
        assetStore: bobAssets,
      );

      await alice.load();
      await alice.setGlobalSolid(0xFFF1EEE8);
      await alice.setConversationSolid('c1', 0xFFE7F3ED);
      await bob.load();

      expect(alice.state.globalWallpaper.kind, ChatWallpaperKind.solid);
      expect(alice.state.resolve('c1').colorValue, 0xFFE7F3ED);
      expect(bob.state.globalWallpaper.kind, ChatWallpaperKind.system);

      await alice.followGlobal('c1');
      expect(alice.state.conversationWallpapers.containsKey('c1'), isFalse);
      expect(alice.state.resolve('c1').colorValue, 0xFFF1EEE8);

      final reloaded = ChatAppearanceStore(
        userId: 'alice',
        storage: storage,
        assetStore: aliceAssets,
      );
      await reloaded.load();
      expect(reloaded.state.globalWallpaper.colorValue, 0xFFF1EEE8);
    },
  );

  test(
    'custom wallpaper is processed, owned by app storage and old asset is cleaned',
    () async {
      final storage = _MemoryStore();
      final assets = _MemoryAssets();
      final store = ChatAppearanceStore(
        userId: 'alice',
        storage: storage,
        assetStore: assets,
      );
      final image = img.Image(width: 2400, height: 1200)
        ..clear(img.ColorRgb8(220, 230, 225));
      final source = Uint8List.fromList(img.encodeJpg(image, quality: 95));

      await store.setGlobalCustom(source);
      final first = store.state.globalWallpaper;
      expect(first.kind, ChatWallpaperKind.custom);
      expect(first.assetReference, isNotNull);
      final saved = await assets.read(first.assetReference!);
      expect(saved, isNotNull);
      final decoded = img.decodeJpg(saved!);
      expect(decoded, isNotNull);
      expect(decoded!.width, lessThanOrEqualTo(1920));
      expect(decoded.height, lessThanOrEqualTo(1920));

      await store.setGlobalSolid(0xFFEEEEEE);
      expect(assets.deleted, contains(first.assetReference));
    },
  );
}

final class _MemoryStore implements SecureKeyValueStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

final class _MemoryAssets implements ChatWallpaperAssetStore {
  final Map<String, Uint8List> values = {};
  final List<String> deleted = [];
  int nextId = 1;

  @override
  Future<String> save(Uint8List bytes) async {
    final key = 'memory://${nextId++}';
    values[key] = Uint8List.fromList(bytes);
    return key;
  }

  @override
  Future<Uint8List?> read(String reference) async => values[reference];

  @override
  Future<void> delete(String reference) async {
    deleted.add(reference);
    values.remove(reference);
  }
}
