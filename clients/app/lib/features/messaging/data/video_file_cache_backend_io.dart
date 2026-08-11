import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../../core/media/media_cache_manager_backend_io.dart'
    show pruneManagedMediaCache;
import 'media_api_client.dart';
import 'resumable_media_downloader.dart';

const Duration _maximumVideoCacheAge = Duration(days: 30);

Future<Directory> _videoCacheDirectory() async {
  final base = await getApplicationSupportDirectory();
  final directory = Directory(
    '${base.path}${Platform.pathSeparator}video_cache_v1',
  );
  if (!await directory.exists()) await directory.create(recursive: true);
  return directory;
}

Future<File> _videoCacheFile(String cacheKey) async {
  final directory = await _videoCacheDirectory();
  return File('${directory.path}${Platform.pathSeparator}$cacheKey.video');
}

Future<Uri?> readCachedVideoUri(
  String cacheKey, {
  required int expectedSizeBytes,
}) async {
  final file = await _videoCacheFile(cacheKey);
  if (!await file.exists()) return null;
  try {
    final stat = await file.stat();
    if (stat.size <= 0 ||
        (expectedSizeBytes > 0 && stat.size != expectedSizeBytes)) {
      await file.delete();
      return null;
    }
    if (DateTime.now().difference(stat.modified) > _maximumVideoCacheAge) {
      await file.delete();
      return null;
    }
    try {
      await file.setLastModified(DateTime.now());
    } catch (_) {}
    return file.uri;
  } on FileSystemException {
    return null;
  }
}

Future<({Uri? uri, int? statusCode})> cacheVideoFromUrl(
  String cacheKey,
  Uri url, {
  required int expectedSizeBytes,
  MediaDownloadCancellation? cancellation,
  void Function(int receivedBytes, int? totalBytes)? onProgress,
}) async {
  final cached = await readCachedVideoUri(
    cacheKey,
    expectedSizeBytes: expectedSizeBytes,
  );
  if (cached != null) return (uri: cached, statusCode: null);

  final file = await _videoCacheFile(cacheKey);
  try {
    final result = await ResumableMediaDownloader().download(
      resolveUrl: () async => url,
      destinationPath: file.path,
      expectedBytes: expectedSizeBytes > 0 ? expectedSizeBytes : null,
      cancellation: cancellation,
      onProgress: onProgress,
      maximumAttempts: 2,
    );
    final completed = File(result.path);
    try {
      await completed.setLastModified(DateTime.now());
    } catch (_) {}
    await pruneManagedMediaCache();
    return (uri: completed.uri, statusCode: null);
  } on ResumableDownloadHttpException catch (error) {
    return (uri: null, statusCode: error.statusCode);
  }
}

Future<void> deleteCachedVideo(String cacheKey) async {
  final file = await _videoCacheFile(cacheKey);
  try {
    if (await file.exists()) await file.delete();
    final temp = File('${file.path}.part');
    if (await temp.exists()) await temp.delete();
  } on FileSystemException {
    // Best-effort eviction. A temporary Windows file lock is harmless.
  }
}
