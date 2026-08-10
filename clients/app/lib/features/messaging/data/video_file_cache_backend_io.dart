import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../../core/media/media_cache_lease_registry.dart';
import '../../../core/media/media_cache_manager_backend_io.dart'
    show pruneManagedMediaCache;

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
  void Function(int receivedBytes, int? totalBytes)? onProgress,
}) async {
  final file = await _videoCacheFile(cacheKey);
  final temp = File('${file.path}.part');
  return MediaCacheLeaseRegistry.shared.withLease(
    file.path,
    () => MediaCacheLeaseRegistry.shared.withLease(
      temp.path,
      () => _cacheVideoFromUrlUnleased(
        cacheKey,
        url,
        expectedSizeBytes: expectedSizeBytes,
        onProgress: onProgress,
      ),
    ),
  );
}

Future<({Uri? uri, int? statusCode})> _cacheVideoFromUrlUnleased(
  String cacheKey,
  Uri url, {
  required int expectedSizeBytes,
  void Function(int receivedBytes, int? totalBytes)? onProgress,
}) async {
  final cached = await readCachedVideoUri(
    cacheKey,
    expectedSizeBytes: expectedSizeBytes,
  );
  if (cached != null) return (uri: cached, statusCode: null);

  final file = await _videoCacheFile(cacheKey);
  final temp = File('${file.path}.part');
  final client = http.Client();
  IOSink? sink;
  try {
    final response = await client.send(http.Request('GET', url));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.drain<void>();
      return (uri: null, statusCode: response.statusCode);
    }
    if (expectedSizeBytes > 0 &&
        response.contentLength != null &&
        response.contentLength != expectedSizeBytes) {
      await response.stream.drain<void>();
      throw const FormatException('视频缓存文件大小与服务端元数据不一致。');
    }
    if (await temp.exists()) await temp.delete();
    sink = temp.openWrite();
    var received = 0;
    final total = response.contentLength;
    await for (final chunk in response.stream) {
      sink.add(chunk);
      received += chunk.length;
      onProgress?.call(received, total);
    }
    await sink.flush();
    await sink.close();
    sink = null;
    final stat = await temp.stat();
    if (stat.size <= 0 ||
        (expectedSizeBytes > 0 && stat.size != expectedSizeBytes)) {
      await temp.delete();
      throw const FormatException('视频缓存下载不完整。');
    }
    if (await file.exists()) await file.delete();
    await temp.rename(file.path);
    try {
      await file.setLastModified(DateTime.now());
    } catch (_) {}
    await pruneManagedMediaCache();
    return (uri: file.uri, statusCode: null);
  } catch (_) {
    try {
      await sink?.close();
    } catch (_) {}
    try {
      if (await temp.exists()) await temp.delete();
    } catch (_) {}
    rethrow;
  } finally {
    client.close();
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

