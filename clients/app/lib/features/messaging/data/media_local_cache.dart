import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'media_cache_backend_stub.dart'
    if (dart.library.io) 'media_cache_backend_io.dart';

abstract interface class MediaCacheStore {
  Future<Uint8List?> read(String cacheKey);
  Future<void> write(String cacheKey, Uint8List bytes);
  Future<void> delete(String cacheKey);
}

final class PlatformMediaCacheStore implements MediaCacheStore {
  const PlatformMediaCacheStore();

  @override
  Future<Uint8List?> read(String cacheKey) => readMediaCacheFile(cacheKey);

  @override
  Future<void> write(String cacheKey, Uint8List bytes) =>
      writeMediaCacheFile(cacheKey, bytes);

  @override
  Future<void> delete(String cacheKey) => deleteMediaCacheFile(cacheKey);
}

final class MediaLocalCache {
  MediaLocalCache({required String namespace, MediaCacheStore? store})
    : _namespace = namespace.trim().isEmpty ? 'anonymous' : namespace.trim(),
      _store = store ?? const PlatformMediaCacheStore();

  final String _namespace;
  final MediaCacheStore _store;
  final Map<String, Future<Uint8List>> _inflight = {};
  final Map<String, Uint8List> _memory = {};

  Future<Uint8List> resolve(
    String mediaId, {
    required Future<Uint8List> Function() loader,
  }) {
    final id = mediaId.trim();
    if (id.isEmpty) throw const FormatException('mediaId 不能为空。');
    final memory = _memory[id];
    if (memory != null && memory.isNotEmpty) return Future.value(memory);
    final current = _inflight[id];
    if (current != null) return current;

    final request = _resolve(id, loader).whenComplete(() {
      final _ = _inflight.remove(id);
    });
    _inflight[id] = request;
    return request;
  }

  Future<void> evict(String mediaId) async {
    final id = mediaId.trim();
    if (id.isEmpty) return;
    _memory.remove(id);
    final _ = _inflight.remove(id);
    await _store.delete(_cacheKey(id));
  }

  Future<Uint8List> _resolve(
    String mediaId,
    Future<Uint8List> Function() loader,
  ) async {
    final key = _cacheKey(mediaId);
    final cached = await _store.read(key);
    if (cached != null && cached.isNotEmpty) {
      _remember(mediaId, cached);
      return cached;
    }

    final downloaded = await loader();
    if (downloaded.isEmpty) throw StateError('媒体下载结果为空。');
    _remember(mediaId, downloaded);
    try {
      await _store.write(key, downloaded);
    } catch (_) {
      // Disk cache is an optimization. A read-only/full disk must not make a
      // valid message unusable during the current session.
    }
    return downloaded;
  }

  void _remember(String mediaId, Uint8List bytes) {
    // Keep only a small hot set in RAM. Persistent cache is the long-lived
    // layer; this avoids pinning hundreds of MB after scrolling a long chat.
    if (_memory.length >= 24 && !_memory.containsKey(mediaId)) {
      _memory.remove(_memory.keys.first);
    }
    _memory[mediaId] = bytes;
  }

  String _cacheKey(String mediaId) =>
      sha256.convert('$_namespace:$mediaId'.codeUnits).toString();
}
