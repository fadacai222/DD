import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../../core/media/avatar_image_processor.dart';

import '../../../theme/app_theme.dart';
import '../../auth/presentation/widgets/profile_avatar.dart';
import '../../messaging/data/media_api_client.dart';
import '../../messaging/data/messaging_api_client.dart';
import '../../messaging/data/video_media_probe.dart';
import '../../messaging/presentation/video_viewer_page.dart';
import '../../messaging/presentation/widgets/inline_video_preview.dart';
import '../data/moments_api_client.dart';
import '../domain/moment_models.dart';
import 'moment_cover_crop_page.dart';
import 'moment_publish_page.dart';

typedef MomentVideoMetadataLoader =
    Future<VideoMediaMetadata> Function(Uri url);

class MomentsFeedPage extends StatefulWidget {
  const MomentsFeedPage({
    super.key,
    required this.origin,
    required this.accessToken,
    required this.currentUserId,
    required this.currentUserDisplayName,
    required this.onUnauthorized,
    this.currentUserAvatarRevision = 0,
    this.authorId,
    this.authorDisplayName,
    this.gateway,
    this.mediaApi,
    this.videoMetadataLoader,
  });

  final Uri origin;
  final String accessToken;
  final String currentUserId;
  final String currentUserDisplayName;
  final int currentUserAvatarRevision;
  final String? authorId;
  final String? authorDisplayName;
  final Future<String?> Function() onUnauthorized;
  final MomentsGateway? gateway;
  final MediaApiClient? mediaApi;
  final MomentVideoMetadataLoader? videoMetadataLoader;

  @override
  State<MomentsFeedPage> createState() => _MomentsFeedPageState();
}

class _MomentsFeedPageState extends State<MomentsFeedPage> {
  late final MomentsGateway _gateway;
  late final MomentActivityGateway? _activityGateway;
  late final MediaApiClient _media;
  late final bool _ownsGateway;
  late final bool _ownsMedia;
  final ScrollController _scroll = ScrollController();
  final Map<String, Future<MediaDownloadGrant>> _downloadGrants = {};
  final Map<String, Future<MediaObjectInfo>> _mediaInfo = {};
  final Map<String, Future<VideoMediaMetadata>> _videoMetadata = {};
  List<MomentItem> _items = const [];
  MomentActivitySummary _activity = const MomentActivitySummary(unreadCount: 0);
  MomentProfile? _profile;
  Future<Uint8List>? _coverBytes;
  bool _coverSaving = false;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;

  bool get _isPersonalFeed => widget.authorId?.trim().isNotEmpty == true;
  String get _profileUserId =>
      _isPersonalFeed ? widget.authorId!.trim() : widget.currentUserId;

  @override
  void initState() {
    super.initState();
    _ownsGateway = widget.gateway == null;
    _ownsMedia = widget.mediaApi == null;
    _gateway = widget.gateway ?? MomentsApiClient();
    _activityGateway = _gateway is MomentActivityGateway
        ? _gateway as MomentActivityGateway
        : null;
    _media = widget.mediaApi ?? MediaApiClient();
    _scroll.addListener(_onScroll);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    if (_ownsGateway) _gateway.close();
    if (_ownsMedia) _media.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          _isPersonalFeed
              ? '${widget.authorDisplayName?.trim().isNotEmpty == true ? widget.authorDisplayName!.trim() : '对方'}的朋友圈'
              : '朋友圈',
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
        actions: [
          if (MediaQuery.sizeOf(context).width >= 680)
            IconButton(
              key: const Key('moments-refresh'),
              tooltip: '刷新朋友圈',
              onPressed: _loading ? null : () => unawaited(_refresh()),
              icon: const Icon(Icons.refresh_rounded),
            ),
          if (!_isPersonalFeed) ...[
            IconButton(
              key: const Key('moments-publish'),
              tooltip: '发表',
              onPressed: () => unawaited(_openPublish()),
              icon: const Icon(Icons.camera_alt_outlined),
            ),
            const SizedBox(width: 4),
          ],
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: _isPersonalFeed ? _personalHeader() : _cover(),
            ),
            if (!_isPersonalFeed && _activity.items.isNotEmpty)
              SliverToBoxAdapter(child: _activityFocus()),
            if (_error != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                  child: Material(
                    color: const Color(0xFFFFE8E8),
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.error_outline_rounded,
                            color: DdColors.danger,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _error!,
                              style: const TextStyle(
                                fontSize: 12,
                                color: DdColors.danger,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: () => unawaited(_refresh()),
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (_loading && _items.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_items.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.photo_library_outlined,
                        size: 48,
                        color: DdColors.textTertiary,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _isPersonalFeed ? '暂无可见内容' : '朋友圈还是空的',
                        style: const TextStyle(color: DdColors.textSecondary),
                      ),
                      if (!_isPersonalFeed) ...[
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: () => unawaited(_openPublish()),
                          icon: const Icon(Icons.camera_alt_outlined),
                          label: const Text('发表第一条'),
                        ),
                      ],
                    ],
                  ),
                ),
              )
            else
              SliverList.builder(
                itemCount: _items.length,
                itemBuilder: (context, index) => _momentCard(_items[index]),
              ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: _loadingMore
                      ? const SizedBox.square(
                          dimension: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          _hasMore && _items.isNotEmpty
                              ? '继续上滑加载'
                              : (_items.isEmpty ? '' : '— 暂时没有更多了 —'),
                          style: const TextStyle(
                            fontSize: 11,
                            color: DdColors.textTertiary,
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _personalHeader() {
    final profile = _profile;
    final authorId = widget.authorId?.trim() ?? '';
    final displayName = profile?.user.displayName.trim().isNotEmpty == true
        ? profile!.user.displayName.trim()
        : widget.authorDisplayName?.trim().isNotEmpty == true
        ? widget.authorDisplayName!.trim()
        : '对方';
    return Material(
      key: const Key('moments-personal-header'),
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          _coverSurface(
            userId: authorId,
            displayName: displayName,
            avatarRevision: 0,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
            child: Row(
              children: [
                ClipOval(
                  child: ProfileAvatar(
                    origin: widget.origin,
                    accessToken: widget.accessToken,
                    userId: authorId,
                    displayName: displayName,
                    size: 52,
                  ),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      const Text(
                        '仅显示当前对你可见的动态',
                        style: TextStyle(
                          fontSize: 12,
                          color: DdColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _cover() => _coverSurface(
    userId: widget.currentUserId,
    displayName: widget.currentUserDisplayName.isEmpty
        ? '我'
        : widget.currentUserDisplayName,
    avatarRevision: widget.currentUserAvatarRevision,
  );

  Widget _activityFocus() {
    final latest = _activity.items.first;
    final unread = _activity.unreadCount;
    final unreadLabel = unread > 99 ? '99+' : '$unread';
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 2),
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(DdRadii.control),
        child: InkWell(
          key: const Key('moments-activity-focus'),
          borderRadius: BorderRadius.circular(DdRadii.control),
          onTap: () => unawaited(_showActivitySheet()),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                SizedBox(
                  width: 68,
                  height: 34,
                  child: Stack(
                    children: [
                      for (
                        var index = 0;
                        index < _activity.items.length && index < 3;
                        index++
                      )
                        Positioned(
                          left: index * 18,
                          child: ClipOval(
                            child: ProfileAvatar(
                              origin: widget.origin,
                              accessToken: widget.accessToken,
                              userId: _activity.items[index].actor.id,
                              displayName:
                                  _activity.items[index].actor.displayName,
                              size: 34,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        unread > 0 ? '$unreadLabel 条新互动' : '最近互动',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _activityPreview(latest),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: DdColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (unread > 0) ...[
                  Container(
                    constraints: const BoxConstraints(
                      minWidth: 22,
                      minHeight: 22,
                    ),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      color: DdColors.danger,
                      borderRadius: BorderRadius.circular(DdRadii.pill),
                    ),
                    child: Text(
                      unreadLabel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                const Icon(
                  Icons.chevron_right_rounded,
                  color: DdColors.textTertiary,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _activityPreview(MomentActivityItem item) {
    final name = item.actor.displayName.trim().isNotEmpty
        ? item.actor.displayName.trim()
        : item.actor.handle.trim().isNotEmpty
        ? item.actor.handle.trim()
        : '好友';
    if (item.kind == 'LIKE') return '$name赞了你的朋友圈';
    final text = item.commentText.trim();
    return text.isEmpty ? '$name评论了你的朋友圈' : '$name评论了你：$text';
  }

  String _activityAction(MomentActivityItem item) {
    if (item.kind == 'LIKE') return '赞了你的朋友圈';
    final text = item.commentText.trim();
    return text.isEmpty ? '评论了你的朋友圈' : '评论了你：$text';
  }

  String _activityTime(DateTime createdAt) {
    final local = createdAt.toLocal();
    final delta = DateTime.now().difference(local);
    if (delta.isNegative || delta.inSeconds < 60) return '刚刚';
    if (delta.inMinutes < 60) return '${delta.inMinutes}分钟前';
    if (delta.inHours < 24) return '${delta.inHours}小时前';
    if (delta.inDays < 7) return '${delta.inDays}天前';
    return '${local.month}月${local.day}日';
  }

  Future<void> _showActivitySheet() async {
    final items = List<MomentActivityItem>.of(_activity.items);
    if (items.isEmpty || !mounted) return;
    unawaited(_markActivityRead());
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 460),
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: 0.72,
        child: Material(
          key: const Key('moments-activity-sheet'),
          color: Theme.of(sheetContext).colorScheme.surface,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 10, 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '互动消息',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, indent: 72),
                  itemBuilder: (_, index) {
                    final item = items[index];
                    final displayName = item.actor.displayName.trim().isNotEmpty
                        ? item.actor.displayName.trim()
                        : item.actor.handle;
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 5,
                      ),
                      leading: ClipOval(
                        child: ProfileAvatar(
                          origin: widget.origin,
                          accessToken: widget.accessToken,
                          userId: item.actor.id,
                          displayName: displayName,
                          size: 42,
                        ),
                      ),
                      title: Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        _activityAction(item),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          color: DdColors.textSecondary,
                        ),
                      ),
                      trailing: Text(
                        _activityTime(item.createdAt),
                        style: const TextStyle(
                          fontSize: 11,
                          color: DdColors.textTertiary,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _markActivityRead() async {
    final gateway = _activityGateway;
    if (gateway == null || _activity.unreadCount == 0) return;
    try {
      final cleared = await _authorized(
        (token) =>
            gateway.markActivityRead(origin: widget.origin, accessToken: token),
      );
      if (!mounted) return;
      setState(() {
        _activity = MomentActivitySummary(
          unreadCount: cleared.unreadCount,
          items: _activity.items
              .map((item) => item.copyWith(read: true))
              .toList(growable: false),
        );
      });
    } catch (_) {
      // Keep the focus visible; the durable unread count can be retried later.
    }
  }

  Widget _coverSurface({
    required String userId,
    required String displayName,
    required int avatarRevision,
  }) {
    final profile = _profile;
    final canEdit = profile?.canEdit == true && !_coverSaving;
    return SizedBox(
      height: 188,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _coverBackground(),
          if (canEdit)
            Positioned.fill(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  key: const Key('moments-edit-cover'),
                  onTap: () => unawaited(_editCover()),
                  child: Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.48),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 5,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_coverSaving)
                                const SizedBox.square(
                                  dimension: 13,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              else
                                const Icon(
                                  Icons.camera_alt_rounded,
                                  size: 15,
                                  color: Colors.white,
                                ),
                              const SizedBox(width: 5),
                              const Text(
                                '更换封面',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            right: 18,
            bottom: 14,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  displayName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    shadows: [Shadow(color: Colors.black38, blurRadius: 3)],
                  ),
                ),
                const SizedBox(width: 10),
                ClipOval(
                  child: ProfileAvatar(
                    origin: widget.origin,
                    accessToken: widget.accessToken,
                    userId: userId,
                    displayName: displayName,
                    revision: avatarRevision,
                    size: 58,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _coverBackground() {
    final mediaId = _profile?.coverMediaId.trim() ?? '';
    if (mediaId.isEmpty) return _defaultCoverBackground();
    _coverBytes ??= _downloadCover(mediaId);
    return FutureBuilder<Uint8List>(
      future: _coverBytes,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty || snapshot.hasError) {
          return _defaultCoverBackground();
        }
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
        );
      },
    );
  }

  Widget _defaultCoverBackground() {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? const [Color(0xFF26343A), Color(0xFF111718)]
              : const [Color(0xFF9FB4B2), Color(0xFF536A69)],
        ),
      ),
    );
  }

  Widget _momentCard(MomentItem item) {
    final own = item.author.id == widget.currentUserId;
    return Container(
      key: Key('moment-${item.id}'),
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: const Border(
          bottom: BorderSide(color: DdColors.divider, width: 0.5),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              key: Key('moment-author-avatar-${item.author.id}'),
              borderRadius: BorderRadius.circular(4),
              onTap: () => unawaited(_openAuthorMoments(item.author)),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: ProfileAvatar(
                  origin: widget.origin,
                  accessToken: widget.accessToken,
                  userId: item.author.id,
                  displayName: _momentUserName(item.author),
                  size: 44,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _momentUserName(item.author),
                  style: const TextStyle(
                    color: Color(0xFF576B95),
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (item.text.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  SelectableText(
                    item.text,
                    style: const TextStyle(fontSize: 15, height: 1.45),
                  ),
                ],
                if (item.mediaIds.isNotEmpty) ...[
                  const SizedBox(height: 9),
                  _mediaGrid(item),
                ],
                const SizedBox(height: 9),
                Row(
                  children: [
                    Text(
                      _timeLabel(item.createdAt),
                      style: const TextStyle(
                        fontSize: 11,
                        color: DdColors.textTertiary,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      key: Key('moment-like-${item.id}'),
                      visualDensity: VisualDensity.compact,
                      tooltip: item.likedByMe ? '取消赞' : '赞',
                      onPressed: () =>
                          unawaited(_setLike(item, !item.likedByMe)),
                      icon: Icon(
                        item.likedByMe
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        size: 19,
                        color: item.likedByMe
                            ? DdColors.danger
                            : const Color(0xFF576B95),
                      ),
                    ),
                    IconButton(
                      key: Key('moment-comment-${item.id}'),
                      visualDensity: VisualDensity.compact,
                      tooltip: '评论',
                      onPressed: () => unawaited(_comment(item)),
                      icon: const Icon(
                        Icons.chat_bubble_outline_rounded,
                        size: 19,
                        color: Color(0xFF576B95),
                      ),
                    ),
                    if (own)
                      IconButton(
                        key: Key('moment-actions-${item.id}'),
                        visualDensity: VisualDensity.compact,
                        tooltip: '更多',
                        onPressed: () => unawaited(_showActions(item)),
                        icon: const Icon(
                          Icons.more_horiz_rounded,
                          size: 21,
                          color: Color(0xFF576B95),
                        ),
                      ),
                  ],
                ),
                if (item.likeUsers.isNotEmpty || item.comments.isNotEmpty)
                  _interactionBox(item),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _mediaGrid(MomentItem item) {
    final count = item.mediaIds.length;
    Widget tile(int index, {bool singleMedia = false}) => _MomentMediaTile(
      mediaId: item.mediaIds[index],
      info: _mediaInfoFor(item.mediaIds[index]),
      grant: _downloadGrant(item.mediaIds[index]),
      retryGrant: () {
        _downloadGrants.remove(item.mediaIds[index]);
        return _downloadGrant(item.mediaIds[index]);
      },
      loadVideoMetadata: (url) => _videoMetadataFor(item.mediaIds[index], url),
      scrollListenable: _scroll,
      heroTag: 'moment-${item.id}-media-$index',
      singleMedia: singleMedia,
    );

    if (count == 1) {
      return SizedBox(width: 220, child: tile(0, singleMedia: true));
    }
    final columns = count == 4 ? 2 : 3;
    return SizedBox(
      width: 270,
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: 4,
          mainAxisSpacing: 4,
        ),
        itemCount: count,
        itemBuilder: (context, index) => tile(index),
      ),
    );
  }

  Widget _interactionBox(MomentItem item) {
    final commentsById = <String, MomentComment>{
      for (final comment in item.comments) comment.id: comment,
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF292929)
            : const Color(0xFFF3F3F5),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (item.likeUsers.isNotEmpty) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.favorite_rounded,
                  size: 15,
                  color: Color(0xFF576B95),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    item.likeUsers.map((user) => user.displayName).join('，'),
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF576B95),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            if (item.comments.isNotEmpty) const Divider(height: 10),
          ],
          for (final comment in item.comments)
            _commentRow(item, comment, commentsById[comment.replyToCommentId]),
        ],
      ),
    );
  }

  Widget _commentRow(
    MomentItem item,
    MomentComment comment,
    MomentComment? replyTarget,
  ) {
    final replyName = replyTarget == null
        ? ''
        : _momentUserName(replyTarget.author);
    return GestureDetector(
      key: Key('moment-comment-item-${comment.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => unawaited(_comment(item, replyTo: comment)),
      onLongPress:
          comment.author.id == widget.currentUserId ||
              item.author.id == widget.currentUserId
          ? () => unawaited(_confirmDeleteComment(item, comment))
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text.rich(
          TextSpan(
            style: DefaultTextStyle.of(
              context,
            ).style.copyWith(fontSize: 13, height: 1.35),
            children: [
              TextSpan(
                text: _momentUserName(comment.author),
                style: const TextStyle(
                  color: Color(0xFF576B95),
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (replyName.isNotEmpty) ...[
                const TextSpan(text: ' 回复@'),
                TextSpan(
                  text: replyName,
                  style: const TextStyle(
                    color: Color(0xFF576B95),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const TextSpan(text: '：'),
              TextSpan(text: comment.text),
            ],
          ),
        ),
      ),
    );
  }

  String _momentUserName(MomentUserPreview user) {
    final displayName = user.displayName.trim();
    if (displayName.isNotEmpty) return displayName;
    final handle = user.handle.trim();
    return handle.isNotEmpty ? handle : '用户';
  }

  Future<void> _openAuthorMoments(MomentUserPreview author) async {
    if (_isPersonalFeed && _profileUserId == author.id) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MomentsFeedPage(
          origin: widget.origin,
          accessToken: widget.accessToken,
          currentUserId: widget.currentUserId,
          currentUserDisplayName: widget.currentUserDisplayName,
          currentUserAvatarRevision: widget.currentUserAvatarRevision,
          authorId: author.id,
          authorDisplayName: _momentUserName(author),
          onUnauthorized: widget.onUnauthorized,
          gateway: _gateway,
          mediaApi: _media,
          videoMetadataLoader: widget.videoMetadataLoader,
        ),
      ),
    );
  }

  Future<Uint8List> _downloadCover(String mediaId) async {
    final grant = await _downloadGrant(mediaId);
    return _media.downloadMedia(url: grant.url);
  }

  Future<void> _editCover() async {
    if (_profile?.canEdit != true || _coverSaving) return;
    final file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: '朋友圈封面',
          extensions: <String>['jpg', 'jpeg', 'png', 'webp'],
          mimeTypes: <String>['image/jpeg', 'image/png', 'image/webp'],
        ),
      ],
    );
    if (file == null || !mounted) return;
    setState(() {
      _coverSaving = true;
      _error = null;
    });
    try {
      final source = await file.readAsBytes();
      final preview = await prepareAvatarCropPreview(source);
      if (!mounted) return;
      final crop = await Navigator.of(context).push<MomentCoverCropResult>(
        MaterialPageRoute<MomentCoverCropResult>(
          fullscreenDialog: true,
          builder: (_) => MomentCoverCropPage(
            previewBytes: preview.bytes,
            width: preview.width,
            height: preview.height,
          ),
        ),
      );
      if (crop == null || !mounted) return;
      final processed = await processMomentCoverImage(source, crop);
      final media = await _authorized(
        (token) => _media.uploadMedia(
          origin: widget.origin,
          accessToken: token,
          bytes: processed,
          fileName: 'moments-cover-${widget.currentUserId}.jpg',
          mimeType: 'image/jpeg',
          purpose: 'MOMENT_COVER',
        ),
      );
      final profile = await _authorized(
        (token) => _gateway.updateProfile(
          origin: widget.origin,
          accessToken: token,
          userId: widget.currentUserId,
          coverMediaId: media.mediaId,
        ),
      );
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _coverBytes = Future<Uint8List>.value(processed);
      });
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _coverSaving = false);
    }
  }

  Future<MediaObjectInfo> _mediaInfoFor(String mediaId) {
    return _mediaInfo.putIfAbsent(mediaId, () => _loadMediaInfo(mediaId));
  }

  Future<MediaObjectInfo> _loadMediaInfo(String mediaId) async {
    try {
      return await _authorized(
        (token) => _media.getMedia(
          origin: widget.origin,
          accessToken: token,
          mediaId: mediaId,
        ),
      );
    } catch (_) {
      final _ = _mediaInfo.remove(mediaId);
      rethrow;
    }
  }

  Future<MediaDownloadGrant> _downloadGrant(String mediaId) {
    return _downloadGrants.putIfAbsent(
      mediaId,
      () => _loadDownloadGrant(mediaId),
    );
  }

  Future<VideoMediaMetadata> _videoMetadataFor(String mediaId, Uri url) {
    return _videoMetadata.putIfAbsent(
      mediaId,
      () => _loadVideoMetadata(mediaId, url),
    );
  }

  Future<VideoMediaMetadata> _loadVideoMetadata(String mediaId, Uri url) async {
    try {
      final loader =
          widget.videoMetadataLoader ?? const VideoMediaProbe().probe;
      return await loader(url);
    } catch (_) {
      final _ = _videoMetadata.remove(mediaId);
      rethrow;
    }
  }

  Future<MediaDownloadGrant> _loadDownloadGrant(String mediaId) async {
    try {
      return await _authorized(
        (token) => _media.createDownloadUrl(
          origin: widget.origin,
          accessToken: token,
          mediaId: mediaId,
        ),
      );
    } catch (_) {
      final _ = _downloadGrants.remove(mediaId);
      rethrow;
    }
  }

  Future<void> _refresh() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final profile = await _authorized(
        (token) => _gateway.getProfile(
          origin: widget.origin,
          accessToken: token,
          userId: _profileUserId,
        ),
      );
      final items = await _authorized(
        (token) => _gateway.listFeed(
          origin: widget.origin,
          accessToken: token,
          authorId: widget.authorId,
          limit: 30,
        ),
      );
      MomentActivitySummary? activity;
      final activityGateway = _activityGateway;
      if (!_isPersonalFeed && activityGateway != null) {
        try {
          activity = await _authorized(
            (token) => activityGateway.getActivitySummary(
              origin: widget.origin,
              accessToken: token,
            ),
          );
        } catch (_) {
          // Activity history must not make the main feed unavailable.
        }
      }
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _coverBytes = null;
        _items = items;
        if (activity != null) _activity = activity;
        _hasMore = items.length >= 30;
        _downloadGrants.clear();
        _mediaInfo.clear();
      });
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore || _items.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final next = await _authorized(
        (token) => _gateway.listFeed(
          origin: widget.origin,
          accessToken: token,
          before: _items.last.id,
          authorId: widget.authorId,
          limit: 30,
        ),
      );
      if (!mounted) return;
      final seen = _items.map((item) => item.id).toSet();
      setState(() {
        _items = [..._items, ...next.where((item) => seen.add(item.id))];
        _hasMore = next.length >= 30;
      });
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _onScroll() {
    if (_scroll.position.extentAfter < 500) unawaited(_loadMore());
  }

  Future<void> _openPublish() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        fullscreenDialog: true,
        builder: (_) => MomentPublishPage(
          origin: widget.origin,
          accessToken: widget.accessToken,
          onUnauthorized: widget.onUnauthorized,
        ),
      ),
    );
    if (changed == true) await _refresh();
  }

  Future<void> _showActions(MomentItem item) async {
    if (item.author.id != widget.currentUserId) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded),
            title: const Text('删除', style: TextStyle(color: DdColors.danger)),
            onTap: () => Navigator.pop(sheetContext, 'delete'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
    if (action == 'delete') await _confirmDelete(item);
  }

  Future<void> _setLike(MomentItem item, bool liked) async {
    try {
      final updated = await _authorized(
        (token) => _gateway.setLike(
          origin: widget.origin,
          accessToken: token,
          momentId: item.id,
          liked: liked,
        ),
      );
      _replace(updated);
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _comment(MomentItem item, {MomentComment? replyTo}) async {
    var draft = '';
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          replyTo == null ? '评论' : '回复 ${replyTo.author.displayName}',
        ),
        content: TextField(
          key: const Key('moment-comment-input'),
          autofocus: true,
          maxLength: 1000,
          maxLines: 4,
          decoration: const InputDecoration(hintText: '说点什么…'),
          onChanged: (value) => draft = value,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final value = draft.trim();
              if (value.isNotEmpty) Navigator.pop(dialogContext, value);
            },
            child: const Text('发送'),
          ),
        ],
      ),
    );
    if (text == null || text.isEmpty) return;
    try {
      final updated = await _authorized(
        (token) => _gateway.addComment(
          origin: widget.origin,
          accessToken: token,
          momentId: item.id,
          text: text,
          replyToCommentId: replyTo?.id,
        ),
      );
      _replace(updated);
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _confirmDelete(MomentItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除朋友圈？'),
        content: const Text('删除后所有联系人都无法再查看这条内容。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除', style: TextStyle(color: DdColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _authorized(
        (token) => _gateway.deleteMoment(
          origin: widget.origin,
          accessToken: token,
          momentId: item.id,
        ),
      );
      if (!mounted) return;
      setState(
        () => _items = _items
            .where((candidate) => candidate.id != item.id)
            .toList(growable: false),
      );
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _confirmDeleteComment(
    MomentItem item,
    MomentComment comment,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除评论？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除', style: TextStyle(color: DdColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final updated = await _authorized(
        (token) => _gateway.deleteComment(
          origin: widget.origin,
          accessToken: token,
          momentId: item.id,
          commentId: comment.id,
        ),
      );
      _replace(updated);
    } catch (error) {
      _showError(error);
    }
  }

  void _replace(MomentItem item) {
    if (!mounted) return;
    setState(() {
      _items = [
        for (final current in _items)
          if (current.id == item.id) item else current,
      ];
    });
  }

  Future<T> _authorized<T>(Future<T> Function(String token) action) async {
    try {
      return await action(widget.accessToken);
    } on MomentsApiException catch (error) {
      if (error.statusCode != 401) rethrow;
      final token = await widget.onUnauthorized();
      if (token == null || token.isEmpty) rethrow;
      return action(token);
    } on MessagingApiException catch (error) {
      if (error.statusCode != 401) rethrow;
      final token = await widget.onUnauthorized();
      if (token == null || token.isEmpty) rethrow;
      return action(token);
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    final message = _friendlyError(error);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _friendlyError(Object error) {
    if (error is MomentsApiException) return error.message;
    return error.toString().replaceFirst('FormatException: ', '');
  }

  String _timeLabel(DateTime utc) {
    final local = utc.toLocal();
    final delta = DateTime.now().difference(local);
    if (delta.inMinutes < 1) return '刚刚';
    if (delta.inHours < 1) return '${delta.inMinutes}分钟前';
    if (delta.inHours < 24) return '${delta.inHours}小时前';
    if (delta.inDays < 7) return '${delta.inDays}天前';
    return '${local.month}月${local.day}日';
  }
}

class _MomentMediaTile extends StatelessWidget {
  const _MomentMediaTile({
    required this.mediaId,
    required this.info,
    required this.grant,
    required this.retryGrant,
    required this.loadVideoMetadata,
    required this.scrollListenable,
    required this.heroTag,
    this.singleMedia = false,
  });

  final String mediaId;
  final Future<MediaObjectInfo> info;
  final Future<MediaDownloadGrant> grant;
  final Future<MediaDownloadGrant> Function() retryGrant;
  final Future<VideoMediaMetadata> Function(Uri url) loadVideoMetadata;
  final Listenable scrollListenable;
  final String heroTag;
  final bool singleMedia;

  Widget _frame(Widget child, {double aspectRatio = 1}) {
    if (!singleMedia) return child;
    final safeRatio = aspectRatio.isFinite && aspectRatio > 0
        ? aspectRatio
        : 1.0;
    return AspectRatio(aspectRatio: safeRatio, child: child);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Object>>(
      future: Future.wait<Object>([info, grant]),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _frame(
            Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              alignment: Alignment.center,
              child: const Icon(
                Icons.broken_image_outlined,
                color: DdColors.textTertiary,
              ),
            ),
          );
        }
        final values = snapshot.data;
        if (values == null) {
          return _frame(
            Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              alignment: Alignment.center,
              child: const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final metadata = values[0] as MediaObjectInfo;
        final download = values[1] as MediaDownloadGrant;
        if (metadata.isVideo) {
          return FutureBuilder<VideoMediaMetadata>(
            future: loadVideoMetadata(download.url),
            builder: (context, videoSnapshot) {
              final preview = videoSnapshot.data;
              if (preview == null) {
                if (videoSnapshot.hasError) {
                  return _videoFallback(context, metadata, download);
                }
                return _frame(
                  Container(
                    key: Key('moment-video-$mediaId'),
                    color: const Color(0xFF202020),
                    alignment: Alignment.center,
                    child: const SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: Colors.white70,
                      ),
                    ),
                  ),
                );
              }
              return KeyedSubtree(
                key: Key('moment-video-$mediaId'),
                child: _frame(
                  InlineVideoPreview(
                    playbackId: 'moment-$mediaId',
                    posterBytes: preview.posterJpeg,
                    declaredDuration: Duration(
                      milliseconds: preview.durationMs,
                    ),
                    sourceResolver: () async {
                      if (download.expiresAt.isAfter(
                        DateTime.now().toUtc().add(const Duration(seconds: 30)),
                      )) {
                        return download.url;
                      }
                      return (await retryGrant()).url;
                    },
                    onOpenFull: () => _openVideo(context, metadata, download),
                    scrollListenable: scrollListenable,
                    autoPlayWhenVisible: true,
                    openFullOnTap: true,
                  ),
                  aspectRatio: preview.width / preview.height,
                ),
              );
            },
          );
        }
        return _frame(
          GestureDetector(
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) =>
                    _MomentImageViewer(url: download.url, heroTag: heroTag),
              ),
            ),
            child: Hero(
              tag: heroTag,
              child: Image.network(
                download.url.toString(),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => Container(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.broken_image_outlined,
                    color: DdColors.textTertiary,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _videoFallback(
    BuildContext context,
    MediaObjectInfo metadata,
    MediaDownloadGrant download,
  ) {
    return _frame(
      GestureDetector(
        key: Key('moment-video-$mediaId'),
        behavior: HitTestBehavior.opaque,
        onTap: () => _openVideo(context, metadata, download),
        child: Container(
          color: const Color(0xFF202020),
          alignment: Alignment.center,
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: Color(0xAA000000),
                child: Icon(
                  Icons.play_arrow_rounded,
                  size: 32,
                  color: Colors.white,
                ),
              ),
              SizedBox(height: 6),
              Text(
                '点击播放',
                style: TextStyle(fontSize: 11, color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openVideo(
    BuildContext context,
    MediaObjectInfo metadata,
    MediaDownloadGrant download,
  ) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => VideoViewerPage(
          url: download.url,
          fileName: metadata.originalName.isEmpty
              ? 'moment-video.mp4'
              : metadata.originalName,
          mimeType: metadata.mimeType.isEmpty ? 'video/mp4' : metadata.mimeType,
          retryUrlResolver: () async => (await retryGrant()).url,
        ),
      ),
    );
  }
}

class _MomentImageViewer extends StatelessWidget {
  const _MomentImageViewer({required this.url, required this.heroTag});
  final Uri url;
  final String heroTag;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.8,
          maxScale: 5,
          child: Hero(
            tag: heroTag,
            child: Image.network(url.toString(), fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }
}
