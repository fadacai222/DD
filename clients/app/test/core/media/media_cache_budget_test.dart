import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/media/media_cache_budget.dart';
import 'package:im_client/core/security/dd_secure_storage.dart';

void main() {
  test('cache budget defaults to 2 GiB and persists supported values', () async {
    final storage = _MemoryStore();
    final store = MediaCacheBudgetStore(userId: 'user-a', storage: storage);

    expect(await store.load(), mediaCacheBudget2GiB);
    expect(MediaCacheBudgetRegistry.bytes, mediaCacheBudget2GiB);

    await store.save(mediaCacheBudget5GiB);
    expect(store.bytes, mediaCacheBudget5GiB);
    expect(MediaCacheBudgetRegistry.bytes, mediaCacheBudget5GiB);

    final reloaded = MediaCacheBudgetStore(userId: 'user-a', storage: storage);
    expect(await reloaded.load(), mediaCacheBudget5GiB);
  });

  test('invalid persisted cache budget falls back to 2 GiB', () async {
    final storage = _MemoryStore();
    await storage.write('dd.media.cache-budget.v1.user-b', '12345');
    final store = MediaCacheBudgetStore(userId: 'user-b', storage: storage);

    expect(await store.load(), mediaCacheBudget2GiB);
    expect(MediaCacheBudgetRegistry.bytes, mediaCacheBudget2GiB);
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
