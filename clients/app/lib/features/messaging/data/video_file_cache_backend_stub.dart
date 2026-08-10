Future<Uri?> readCachedVideoUri(
  String cacheKey, {
  required int expectedSizeBytes,
}) async => null;

Future<({Uri? uri, int? statusCode})> cacheVideoFromUrl(
  String cacheKey,
  Uri url, {
  required int expectedSizeBytes,
  void Function(int receivedBytes, int? totalBytes)? onProgress,
}) async => (uri: null, statusCode: null);

Future<void> deleteCachedVideo(String cacheKey) async {}
