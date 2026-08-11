import 'package:crypto/crypto.dart';

import 'media_api_client.dart';
import 'video_file_cache_backend_stub.dart'
    if (dart.library.io) 'video_file_cache_backend_io.dart';

final class VideoFileCacheHttpException implements Exception {
  const VideoFileCacheHttpException(this.statusCode);

  final int statusCode;

  @override
  String toString() => '视频缓存下载失败（HTTP $statusCode）。';
}

final class VideoFileCache {
  VideoFileCache({required String namespace})
    : _namespace = namespace.trim().isEmpty ? 'anonymous' : namespace.trim();

  final String _namespace;

  Future<Uri?> cachedUri(
    String mediaId, {
    required int expectedSizeBytes,
  }) {
    final id = mediaId.trim();
    if (id.isEmpty) throw const FormatException('mediaId 不能为空。');
    return readCachedVideoUri(
      _cacheKey(id),
      expectedSizeBytes: expectedSizeBytes,
    );
  }

  Future<Uri?> cacheFromUrl({
    required String mediaId,
    required Uri url,
    required int expectedSizeBytes,
    MediaDownloadCancellation? cancellation,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    final id = mediaId.trim();
    if (id.isEmpty) throw const FormatException('mediaId 不能为空。');
    final result = await cacheVideoFromUrl(
      _cacheKey(id),
      url,
      expectedSizeBytes: expectedSizeBytes,
      cancellation: cancellation,
      onProgress: onProgress,
    );
    final statusCode = result.statusCode;
    if (statusCode != null) throw VideoFileCacheHttpException(statusCode);
    return result.uri;
  }

  Future<void> evict(String mediaId) {
    final id = mediaId.trim();
    if (id.isEmpty) return Future<void>.value();
    return deleteCachedVideo(_cacheKey(id));
  }

  String _cacheKey(String mediaId) =>
      sha256.convert('$_namespace:video:$mediaId'.codeUnits).toString();
}
