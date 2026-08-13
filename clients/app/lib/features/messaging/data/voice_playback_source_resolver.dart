// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:typed_data';

import '../../../core/media/media_cache_manager.dart';
import '../domain/messaging_models.dart';
import 'media_api_client.dart';
import 'media_download_grant_cache.dart';
import 'media_download_resolver.dart';
import 'media_local_cache.dart';
import 'voice_playback_source.dart';

abstract interface class VoicePlaybackSourceResolver {
  Future<VoicePlaybackSource> resolve(
    ChatMessage message, {
    bool forceGrantRefresh = false,
  });

  Future<VoicePlaybackSource> resolveBytesFallback(ChatMessage message);

  Future<void> prefetch(Iterable<ChatMessage> messages);
}

final class AuthorizedVoicePlaybackSourceResolver
    implements VoicePlaybackSourceResolver {
  AuthorizedVoicePlaybackSourceResolver({
    required MediaLocalCache cache,
    required MediaDownloadGrantCache grants,
    required Future<MediaDownloadGrant> Function(String mediaId) grantLoader,
    required Future<Uint8List> Function(Uri url) downloader,
    this.maxBackgroundCacheBytes = 8 * 1024 * 1024,
    this.maxFallbackBytes = 8 * 1024 * 1024,
    this.maxPrefetchItems = 2,
  }) : _cache = cache,
       _grants = grants,
       _grantLoader = grantLoader,
       _downloader = downloader;

  final MediaLocalCache _cache;
  final MediaDownloadGrantCache _grants;
  final Future<MediaDownloadGrant> Function(String mediaId) _grantLoader;
  final Future<Uint8List> Function(Uri url) _downloader;
  final int maxBackgroundCacheBytes;
  final int maxFallbackBytes;
  final int maxPrefetchItems;
  final Map<String, Future<void>> _cacheInflight = <String, Future<void>>{};

  @override
  Future<VoicePlaybackSource> resolve(
    ChatMessage message, {
    bool forceGrantRefresh = false,
  }) async {
    final content = message.content;
    final mediaId = content?.mediaId?.trim() ?? '';
    if (message.type.toUpperCase() != 'VOICE' || mediaId.isEmpty) {
      throw const FormatException('VOICE message media is invalid.');
    }

    if (!forceGrantRefresh) {
      final localPath = await _cache.localPathIfPresent(
        mediaId,
        kind: MediaCacheKind.voice,
      );
      if (localPath != null) {
        return LocalVoicePlaybackSource(localPath, mimeType: content?.mimeType);
      }
      final cached = await _cache.readIfPresent(
        mediaId,
        kind: MediaCacheKind.voice,
      );
      if (cached != null) {
        return BytesVoicePlaybackSource(
          cached,
          namespace: message.conversationId,
          mediaId: mediaId,
          mimeType: content?.mimeType,
        );
      }
    } else {
      _grants.clear(mediaId);
    }

    final grant = await _grants.resolve(
      mediaId,
      loader: () => _grantLoader(mediaId),
    );
    unawaited(_scheduleCache(message));
    return RemoteVoicePlaybackSource(grant.url, mimeType: content?.mimeType);
  }

  @override
  Future<VoicePlaybackSource> resolveBytesFallback(ChatMessage message) async {
    final content = message.content;
    final mediaId = content?.mediaId?.trim() ?? '';
    final sizeBytes = content?.sizeBytes ?? 0;
    if (message.type.toUpperCase() != 'VOICE' ||
        message.isRecalled ||
        mediaId.isEmpty ||
        sizeBytes <= 0 ||
        sizeBytes > maxFallbackBytes) {
      throw StateError('Voice byte fallback is not eligible.');
    }
    final cached = await _cache.readIfPresent(
      mediaId,
      kind: MediaCacheKind.voice,
    );
    if (cached != null) {
      return BytesVoicePlaybackSource(
        cached,
        namespace: message.conversationId,
        mediaId: mediaId,
        mimeType: content?.mimeType,
      );
    }
    final bytes = await downloadMediaWithGrantRefresh(
      mediaId: mediaId,
      grants: _grants,
      grantLoader: () => _grantLoader(mediaId),
      downloader: _downloader,
    );
    if (bytes.isEmpty || bytes.length > maxFallbackBytes) {
      throw StateError('Voice byte fallback exceeded its bound.');
    }
    await _cache.store(mediaId, bytes, kind: MediaCacheKind.voice);
    return BytesVoicePlaybackSource(
      bytes,
      namespace: message.conversationId,
      mediaId: mediaId,
      mimeType: content?.mimeType,
    );
  }

  @override
  Future<void> prefetch(Iterable<ChatMessage> messages) async {
    var accepted = 0;
    for (final message in messages) {
      if (accepted >= maxPrefetchItems) break;
      if (!_canBackgroundCache(message)) continue;
      accepted++;
      await _scheduleCache(message);
    }
  }

  Future<void> _scheduleCache(ChatMessage message) {
    final mediaId = message.content?.mediaId?.trim() ?? '';
    if (!_canBackgroundCache(message) || mediaId.isEmpty) {
      return Future<void>.value();
    }
    final existing = _cacheInflight[mediaId];
    if (existing != null) return existing;
    if (_cacheInflight.isNotEmpty) return Future<void>.value();

    final future = _downloadIntoCache(message).whenComplete(() {
      _cacheInflight.remove(mediaId);
    });
    _cacheInflight[mediaId] = future;
    unawaited(future.catchError((Object _) {}));
    return future;
  }

  bool _canBackgroundCache(ChatMessage message) {
    if (message.type.toUpperCase() != 'VOICE' || message.isRecalled) {
      return false;
    }
    final size = message.content?.sizeBytes ?? 0;
    return size > 0 && size <= maxBackgroundCacheBytes;
  }

  Future<void> _downloadIntoCache(ChatMessage message) async {
    final mediaId = message.content!.mediaId!.trim();
    final cached = await _cache.readIfPresent(
      mediaId,
      kind: MediaCacheKind.voice,
    );
    if (cached != null) return;
    final bytes = await downloadMediaWithGrantRefresh(
      mediaId: mediaId,
      grants: _grants,
      grantLoader: () => _grantLoader(mediaId),
      downloader: _downloader,
    );
    if (bytes.length > maxBackgroundCacheBytes) return;
    await _cache.store(mediaId, bytes, kind: MediaCacheKind.voice);
  }
}
