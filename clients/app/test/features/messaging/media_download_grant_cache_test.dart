import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/messaging/data/media_api_client.dart';
import 'package:im_client/features/messaging/data/media_download_grant_cache.dart';

void main() {
  test(
    'concurrent grant callers complete instead of waiting on themselves',
    () async {
      final cache = MediaDownloadGrantCache();
      final source = Completer<MediaDownloadGrant>();
      var loads = 0;

      Future<MediaDownloadGrant> loader() {
        loads++;
        return source.future;
      }

      final first = cache.resolve('media-1', loader: loader);
      final second = cache.resolve('media-1', loader: loader);
      expect(loads, 1);

      source.complete(
        MediaDownloadGrant(
          url: Uri.parse('http://192.168.6.158:19000/object'),
          expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
        ),
      );

      final results = await Future.wait([
        first,
        second,
      ]).timeout(const Duration(seconds: 1));
      expect(results[0].url, results[1].url);
      expect(loads, 1);
    },
  );

  test(
    'valid grant is reused until close to expiry and clear forces reload',
    () async {
      final cache = MediaDownloadGrantCache();
      var loads = 0;

      Future<MediaDownloadGrant> loader() async {
        loads++;
        return MediaDownloadGrant(
          url: Uri.parse('http://example.test/$loads'),
          expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
        );
      }

      final first = await cache.resolve('media-2', loader: loader);
      final second = await cache.resolve('media-2', loader: loader);
      expect(second.url, first.url);
      expect(loads, 1);

      cache.clear('media-2');
      final third = await cache.resolve('media-2', loader: loader);
      expect(third.url, isNot(first.url));
      expect(loads, 2);
    },
  );
}
