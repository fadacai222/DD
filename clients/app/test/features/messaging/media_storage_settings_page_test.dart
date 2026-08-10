import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:im_client/core/media/media_cache_manager.dart';
import 'package:im_client/core/security/dd_secure_storage.dart';
import 'package:im_client/features/messaging/data/media_auto_download_store.dart';
import 'package:im_client/features/messaging/presentation/media_storage_settings_page.dart';

void main() {
  testWidgets('media settings persist auto-download switches and clear cache kind', (
    tester,
  ) async {
    final storage = _MemoryStore();
    final cache = _FakeCache();
    final store = MediaAutoDownloadStore(userId: 'user-a', storage: storage);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaStorageSettingsPage(
          userId: 'user-a',
          preferencesStore: store,
          cacheManager: cache,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<SwitchListTile>(find.byKey(const Key('media-auto-videos'))).value,
      isFalse,
    );
    await tester.tap(find.byKey(const Key('media-auto-videos')));
    await tester.pumpAndSettle();
    expect((await store.load()).videos, isTrue);

    expect(find.text('12.0 MB'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('media-cache-video')),
        matching: find.text('清理'),
      ),
    );
    await tester.pumpAndSettle();
    expect(cache.cleared, contains(MediaCacheKind.video));
    expect(find.text('0 B'), findsWidgets);
  });
}

final class _FakeCache implements MediaCacheGateway {
  Map<MediaCacheKind, int> values = <MediaCacheKind, int>{
    MediaCacheKind.image: 1024,
    MediaCacheKind.video: 12 * 1024 * 1024,
    MediaCacheKind.file: 0,
    MediaCacheKind.voice: 0,
    MediaCacheKind.stickerGif: 0,
    MediaCacheKind.temporary: 0,
  };
  final List<MediaCacheKind> cleared = <MediaCacheKind>[];

  @override
  Future<void> clear(MediaCacheKind kind) async {
    cleared.add(kind);
    values[kind] = 0;
  }

  @override
  Future<void> clearAll() async {
    values = <MediaCacheKind, int>{
      for (final kind in MediaCacheKind.values) kind: 0,
    };
  }

  @override
  Future<MediaCacheSummary> snapshot() async => MediaCacheSummary(values);
}

final class _MemoryStore implements SecureKeyValueStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
