import 'media_api_client.dart';

final class MediaDownloadGrantCache {
  final Map<String, MediaDownloadGrant> _cache = <String, MediaDownloadGrant>{};
  final Map<String, Future<MediaDownloadGrant>> _inflight =
      <String, Future<MediaDownloadGrant>>{};

  Future<MediaDownloadGrant> resolve(
    String mediaId, {
    required Future<MediaDownloadGrant> Function() loader,
  }) {
    final cached = _cache[mediaId];
    final now = DateTime.now().toUtc();
    if (cached != null &&
        cached.expiresAt.isAfter(now.add(const Duration(seconds: 20)))) {
      return Future<MediaDownloadGrant>.value(cached);
    }

    final pending = _inflight[mediaId];
    if (pending != null) return pending;

    final request = loader()
        .then((grant) {
          _cache[mediaId] = grant;
          return grant;
        })
        .whenComplete(() {
          // Do not return Map.remove's value here. It is the current Future and
          // would make whenComplete wait on itself forever.
          _inflight.remove(mediaId);
        });
    _inflight[mediaId] = request;
    return request;
  }

  void clear(String mediaId) {
    _cache.remove(mediaId);
    _inflight.remove(mediaId);
  }
}
