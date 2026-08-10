import 'package:flutter_test/flutter_test.dart';

import 'package:im_client/core/security/dd_secure_storage.dart';
import 'package:im_client/features/messaging/data/media_auto_download_store.dart';

void main() {
  test('auto-download preferences persist per user and default conservatively', () async {
    final storage = _MemoryStore();
    final userA = MediaAutoDownloadStore(userId: 'user-a', storage: storage);
    final userB = MediaAutoDownloadStore(userId: 'user-b', storage: storage);

    final defaults = await userA.load();
    expect(defaults.images, isTrue);
    expect(defaults.gifAndStickers, isTrue);
    expect(defaults.videos, isFalse);
    expect(defaults.files, isFalse);

    await userA.save(
      defaults.copyWith(images: false, videos: true, files: true),
    );

    final restoredA = await userA.load();
    expect(restoredA.images, isFalse);
    expect(restoredA.videos, isTrue);
    expect(restoredA.files, isTrue);

    final restoredB = await userB.load();
    expect(restoredB.images, isTrue);
    expect(restoredB.videos, isFalse);
    expect(restoredB.files, isFalse);
  });

  test('malformed stored preference falls back safely', () async {
    final storage = _MemoryStore();
    await storage.write('dd.media.auto-download.v1.user-a', '{broken');
    final restored = await MediaAutoDownloadStore(
      userId: 'user-a',
      storage: storage,
    ).load();
    expect(restored, isA<MediaAutoDownloadPreferences>());
    expect(restored.videos, isFalse);
    expect(restored.files, isFalse);
  });
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
