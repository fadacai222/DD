import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../core/media/media_cache_manager.dart';
import '../../data/media_api_client.dart';
import '../../data/media_download_grant_cache.dart';
import '../../data/media_download_resolver.dart';
import '../../data/media_local_cache.dart';
import '../../domain/messaging_models.dart';
import 'group_avatar_mosaic.dart';

class GroupAvatar extends StatefulWidget {
  const GroupAvatar({
    super.key,
    required this.origin,
    required this.accessToken,
    required this.groupId,
    required this.groupName,
    required this.members,
    this.avatarMediaId = '',
    this.avatarRevision = 0,
    this.size = 46,
  });

  final Uri origin;
  final String accessToken;
  final String groupId;
  final String groupName;
  final List<MessagingUserPreview> members;
  final String avatarMediaId;
  final int avatarRevision;
  final double size;

  @override
  State<GroupAvatar> createState() => _GroupAvatarState();
}

class _GroupAvatarState extends State<GroupAvatar> {
  static final MediaDownloadGrantCache _grants = MediaDownloadGrantCache();
  static final MediaApiClient _api = MediaApiClient();

  late MediaLocalCache _cache;
  Future<Uint8List>? _bytes;

  @override
  void initState() {
    super.initState();
    _reset();
  }

  @override
  void didUpdateWidget(covariant GroupAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.avatarMediaId != widget.avatarMediaId ||
        oldWidget.avatarRevision != widget.avatarRevision ||
        oldWidget.accessToken != widget.accessToken ||
        oldWidget.origin != widget.origin ||
        oldWidget.groupId != widget.groupId) {
      _reset();
    }
  }

  void _reset() {
    _cache = MediaLocalCache(
      namespace: 'group-avatar:${widget.origin.origin}:${widget.groupId}:${widget.avatarRevision}',
    );
    final mediaId = widget.avatarMediaId.trim();
    _bytes = mediaId.isEmpty
        ? null
        : _cache.resolve(
            mediaId,
            kind: MediaCacheKind.image,
            loader: () => downloadMediaWithGrantRefresh(
              mediaId: mediaId,
              grants: _grants,
              grantLoader: () => _api.createDownloadUrl(
                origin: widget.origin,
                accessToken: widget.accessToken,
                mediaId: mediaId,
              ),
              downloader: (url) => _api.downloadMedia(url: url),
            ),
          );
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) return _fallback();
    return FutureBuilder<Uint8List>(
      future: bytes,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null || data.isEmpty || snapshot.hasError) return _fallback();
        return ClipOval(
          child: Image.memory(
            data,
            width: widget.size,
            height: widget.size,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, _, _) => _fallback(),
          ),
        );
      },
    );
  }

  Widget _fallback() => ClipOval(
    child: GroupAvatarMosaic(
      origin: widget.origin,
      accessToken: widget.accessToken,
      groupName: widget.groupName,
      members: widget.members,
      size: widget.size,
    ),
  );
}
