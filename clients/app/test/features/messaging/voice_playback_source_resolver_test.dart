import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/media/media_cache_manager.dart';
import 'package:im_client/features/messaging/data/media_api_client.dart';
import 'package:im_client/features/messaging/data/media_download_grant_cache.dart';
import 'package:im_client/features/messaging/data/media_local_cache.dart';
import 'package:im_client/features/messaging/data/voice_playback_source.dart';
import 'package:im_client/features/messaging/data/voice_playback_source_resolver.dart';
import 'package:im_client/features/messaging/domain/messaging_models.dart';

void main() {
  test('cache hit returns bytes without loading a remote grant', () async {
    final store = _MemoryStore();
    final cache = MediaLocalCache(namespace: 'u1', store: store);
    final message = _voice(sizeBytes: 4);
    await cache.store('media-1', Uint8List.fromList([1, 2, 3, 4]), kind: MediaCacheKind.voice);
    var grantLoads = 0;
    final resolver = AuthorizedVoicePlaybackSourceResolver(
      cache: cache,
      grants: MediaDownloadGrantCache(),
      grantLoader: (id) async {
        grantLoads++;
        return _grant(id);
      },
      downloader: (url) async => Uint8List.fromList([9]),
    );

    final source = await resolver.resolve(message);
    expect(source, isA<BytesVoicePlaybackSource>());
    expect(grantLoads, 0);
  });

  test('cache miss returns authorized remote source before background download finishes', () async {
    final cache = MediaLocalCache(namespace: 'u1', store: _MemoryStore());
    final downloaderStarted = CompleterFlag();
    final downloaderFinish = CompleterFlag();
    final resolver = AuthorizedVoicePlaybackSourceResolver(
      cache: cache,
      grants: MediaDownloadGrantCache(),
      grantLoader: (id) async => _grant(id),
      downloader: (url) async {
        downloaderStarted.complete();
        await downloaderFinish.future;
        return Uint8List.fromList([1, 2, 3, 4]);
      },
    );

    final source = await resolver.resolve(_voice(sizeBytes: 4));
    expect(source, isA<RemoteVoicePlaybackSource>());
    await downloaderStarted.future;
    expect(downloaderFinish.isCompleted, isFalse);
    downloaderFinish.complete();
    await Future<void>.delayed(Duration.zero);
  });

  test('force refresh invalidates cached signed grant exactly once per explicit retry', () async {
    final cache = MediaLocalCache(namespace: 'u1', store: _MemoryStore());
    var grantLoads = 0;
    final resolver = AuthorizedVoicePlaybackSourceResolver(
      cache: cache,
      grants: MediaDownloadGrantCache(),
      grantLoader: (id) async {
        grantLoads++;
        return _grant('$id-$grantLoads');
      },
      downloader: (url) async => Uint8List(0),
    );
    final message = _voice(sizeBytes: 20 * 1024 * 1024);

    await resolver.resolve(message);
    await resolver.resolve(message, forceGrantRefresh: true);
    expect(grantLoads, 2);
  });

  test('prefetch is bounded by count and voice size', () async {
    final cache = MediaLocalCache(namespace: 'u1', store: _MemoryStore());
    final downloaded = <String>[];
    final resolver = AuthorizedVoicePlaybackSourceResolver(
      cache: cache,
      grants: MediaDownloadGrantCache(),
      grantLoader: (id) async => _grant(id),
      downloader: (url) async {
        downloaded.add(url.pathSegments.last);
        return Uint8List.fromList([1, 2, 3]);
      },
      maxBackgroundCacheBytes: 1024,
      maxPrefetchItems: 2,
    );

    await resolver.prefetch([
      _voice(id: 'm1', mediaId: 'media-1', sizeBytes: 100),
      _voice(id: 'm2', mediaId: 'media-2', sizeBytes: 2048),
      _voice(id: 'm3', mediaId: 'media-3', sizeBytes: 100),
      _voice(id: 'm4', mediaId: 'media-4', sizeBytes: 100),
    ]);
    expect(downloaded, ['media-1', 'media-3']);
  });
}

MediaDownloadGrant _grant(String id) => MediaDownloadGrant(
  url: Uri.parse('https://media.example/$id'),
  expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
);

ChatMessage _voice({
  String id = 'm1',
  String mediaId = 'media-1',
  required int sizeBytes,
}) => ChatMessage(
  id: id,
  conversationId: 'conversation',
  sequence: 1,
  senderUserId: 'peer',
  senderDeviceId: 'device',
  clientMessageId: 'client-$id',
  type: 'VOICE',
  content: TextMessageContent(
    mediaId: mediaId,
    mimeType: 'audio/mp4',
    sizeBytes: sizeBytes,
    durationMs: 1000,
  ),
  createdAt: DateTime.utc(2026, 8, 14),
);

final class _MemoryStore implements MediaCacheStore {
  final Map<String, Uint8List> values = {};

  @override
  Future<void> delete(String cacheKey) async => values.remove(cacheKey);

  @override
  Future<Uint8List?> read(String cacheKey) async => values[cacheKey];

  @override
  Future<void> write(String cacheKey, Uint8List bytes) async {
    values[cacheKey] = Uint8List.fromList(bytes);
  }
}

final class CompleterFlag {
  bool isCompleted = false;
  final _completer = Completer<void>();

  Future<void> get future => _completer.future;

  void complete() {
    if (isCompleted) return;
    isCompleted = true;
    _completer.complete();
  }
}
