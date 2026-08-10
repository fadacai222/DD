import 'package:flutter_test/flutter_test.dart';

import 'package:im_client/core/media/media_cache_lease_registry.dart';

void main() {
  test('cache lease stays active until every holder releases', () {
    const path = r'C:\cache\video-1.mp4';
    final registry = MediaCacheLeaseRegistry.shared;
    final first = registry.acquire(path);
    final second = registry.acquire(path);

    expect(registry.isLeased(path), isTrue);
    first.release();
    expect(registry.isLeased(path), isTrue);
    second.release();
    expect(registry.isLeased(path), isFalse);

    second.release();
    expect(registry.isLeased(path), isFalse);
  });

  test('async withLease releases after errors', () async {
    const path = '/cache/partial.part';
    final registry = MediaCacheLeaseRegistry.shared;

    await expectLater(
      registry.withLease<void>(path, () async {
        expect(registry.isLeased(path), isTrue);
        throw StateError('boom');
      }),
      throwsStateError,
    );
    expect(registry.isLeased(path), isFalse);
  });
}
