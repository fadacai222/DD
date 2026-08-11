import 'media_cache_manager_backend_stub.dart'
    if (dart.library.io) 'media_cache_manager_backend_io.dart';

enum MediaCacheKind { image, video, file, voice, stickerGif, temporary }

final class MediaCacheSummary {
  const MediaCacheSummary(this.bytesByKind);

  final Map<MediaCacheKind, int> bytesByKind;

  int bytesFor(MediaCacheKind kind) => bytesByKind[kind] ?? 0;
  int get totalBytes => bytesByKind.values.fold<int>(0, (sum, value) => sum + value);
}

abstract interface class MediaCacheGateway {
  Future<MediaCacheSummary> snapshot();
  Future<void> clear(MediaCacheKind kind);
  Future<void> clearAll();
  Future<void> prune();
}

final class MediaCacheManager implements MediaCacheGateway {
  const MediaCacheManager();

  @override
  Future<MediaCacheSummary> snapshot() async {
    final raw = await readManagedMediaCacheSnapshot();
    return MediaCacheSummary(<MediaCacheKind, int>{
      for (final kind in MediaCacheKind.values) kind: raw[kind.name] ?? 0,
    });
  }

  @override
  Future<void> clear(MediaCacheKind kind) => clearManagedMediaCacheKind(kind.name);

  @override
  Future<void> clearAll() => clearAllManagedMediaCache();

  @override
  Future<void> prune() => pruneManagedMediaCache();
}

String formatMediaCacheBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
