import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/messaging/data/media_local_cache.dart';

void main() {
  test('same mediaId downloads once and is reused from memory', () async {
    final store = _MemoryMediaStore();
    final cache = MediaLocalCache(namespace: 'user-a', store: store);
    var loads = 0;

    Future<Uint8List> loader() async {
      loads++;
      return Uint8List.fromList([1, 2, 3, 4]);
    }

    final first = await cache.resolve('media-1', loader: loader);
    final second = await cache.resolve('media-1', loader: loader);

    expect(first, [1, 2, 3, 4]);
    expect(second, [1, 2, 3, 4]);
    expect(loads, 1);
    expect(store.writeCalls, 1);
  });

  test(
    'new cache instance reuses persistent bytes without server loader',
    () async {
      final store = _MemoryMediaStore();
      final first = MediaLocalCache(namespace: 'user-a', store: store);
      await first.resolve(
        'media-2',
        loader: () async => Uint8List.fromList([9, 8, 7]),
      );

      final reopened = MediaLocalCache(namespace: 'user-a', store: store);
      var serverLoads = 0;
      final bytes = await reopened.resolve(
        'media-2',
        loader: () async {
          serverLoads++;
          return Uint8List.fromList([0]);
        },
      );

      expect(bytes, [9, 8, 7]);
      expect(serverLoads, 0);
    },
  );

  test(
    'different users never reuse each others persistent media cache',
    () async {
      final store = _MemoryMediaStore();
      final userA = MediaLocalCache(namespace: 'user-a', store: store);
      await userA.resolve(
        'shared-media-id',
        loader: () async => Uint8List.fromList([1, 1, 1]),
      );

      final userB = MediaLocalCache(namespace: 'user-b', store: store);
      var userBLoads = 0;
      final bytes = await userB.resolve(
        'shared-media-id',
        loader: () async {
          userBLoads++;
          return Uint8List.fromList([2, 2, 2]);
        },
      );

      expect(bytes, [2, 2, 2]);
      expect(userBLoads, 1);
    },
  );

  test('concurrent visible widgets share one in-flight download', () async {
    final store = _MemoryMediaStore();
    final cache = MediaLocalCache(namespace: 'user-a', store: store);
    var loads = 0;

    Future<Uint8List> loader() async {
      loads++;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return Uint8List.fromList([5, 5]);
    }

    final results = await Future.wait([
      cache.resolve('media-3', loader: loader),
      cache.resolve('media-3', loader: loader),
      cache.resolve('media-3', loader: loader),
    ]);

    expect(results, everyElement([5, 5]));
    expect(loads, 1);
  });
}

final class _MemoryMediaStore implements MediaCacheStore {
  final Map<String, Uint8List> values = {};
  int writeCalls = 0;

  @override
  Future<Uint8List?> read(String cacheKey) async => values[cacheKey];

  @override
  Future<void> write(String cacheKey, Uint8List bytes) async {
    writeCalls++;
    values[cacheKey] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> delete(String cacheKey) async => values.remove(cacheKey);
}
