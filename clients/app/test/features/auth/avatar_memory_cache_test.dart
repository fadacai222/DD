import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/auth/data/avatar_memory_cache.dart';

void main() {
  test('avatar cache evicts least recently used entries by count', () {
    final cache = AvatarMemoryCache(maximumEntries: 2, maximumBytes: 1024);
    cache.put('a', Uint8List(10));
    cache.put('b', Uint8List(10));
    expect(cache.get('a'), isNotNull);

    cache.put('c', Uint8List(10));

    expect(cache.get('a'), isNotNull);
    expect(cache.get('b'), isNull);
    expect(cache.get('c'), isNotNull);
  });

  test('avatar cache stays under byte budget and supports prefix eviction', () {
    final cache = AvatarMemoryCache(maximumEntries: 10, maximumBytes: 20);
    cache.put('origin|u1|1', Uint8List(12));
    cache.put('origin|u2|1', Uint8List(12));

    expect(cache.bytes, lessThanOrEqualTo(20));
    expect(cache.length, 1);

    cache.put('origin|u1|2', Uint8List(8));
    cache.removeWhere((key) => key.startsWith('origin|u1|'));
    expect(cache.get('origin|u1|2'), isNull);
  });

  test('oversized avatar is not retained', () {
    final cache = AvatarMemoryCache(maximumEntries: 10, maximumBytes: 8);
    cache.put('too-large', Uint8List(9));
    expect(cache.length, 0);
    expect(cache.bytes, 0);
  });
}
