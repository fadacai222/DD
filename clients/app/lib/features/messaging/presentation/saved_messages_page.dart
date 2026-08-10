import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/widgets/dd_action_sheet.dart';
import '../../../theme/app_theme.dart';
import '../application/messaging_coordinator.dart';
import '../data/media_api_client.dart';
import '../data/media_download_grant_cache.dart';
import '../data/media_local_cache.dart';
import '../domain/messaging_models.dart';
import 'text_chat_page.dart';

class SavedMessagesPage extends StatefulWidget {
  const SavedMessagesPage({
    super.key,
    required this.coordinator,
    required this.onOpenMessage,
  });

  final MessagingCoordinator coordinator;
  final Future<void> Function(ChatMessage message) onOpenMessage;

  @override
  State<SavedMessagesPage> createState() => _SavedMessagesPageState();
}

class _SavedMessagesPageState extends State<SavedMessagesPage> {
  bool _loading = true;
  String? _error;
  ConversationItem? _savedConversation;
  List<SavedMessageItem> _items = const [];
  late final MediaApiClient _mediaApi;
  late final MediaLocalCache _mediaCache;
  final MediaDownloadGrantCache _mediaDownloadGrants =
      MediaDownloadGrantCache();

  @override
  void initState() {
    super.initState();
    _mediaApi = MediaApiClient();
    _mediaCache = MediaLocalCache(
      namespace: '${widget.coordinator.currentUserId}:saved-messages',
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    _mediaApi.close();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final conversation = await widget.coordinator.ensureSavedConversation();
      if (!mounted) return;
      setState(() {
        _savedConversation = conversation;
        _error = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final savedConversation = _savedConversation;
    if (savedConversation != null) {
      return TextChatPage(
        coordinator: widget.coordinator,
        conversation: savedConversation,
        currentUserId: widget.coordinator.currentUserId,
        savedMessagesMode: true,
      );
    }
    return Scaffold(
      backgroundColor: _chatBackground(context),
      appBar: AppBar(
        titleSpacing: 0,
        title: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('我的收藏'),
            SizedBox(height: 1),
            Text(
              '仅自己可见',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w400,
                color: DdColors.textTertiary,
              ),
            ),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _error != null
          ? _errorState()
          : SavedMessagesConversationView(
              items: _items,
              currentUserId: widget.coordinator.currentUserId,
              conversationFor: widget.coordinator.conversationFor,
              onOpenMessage: widget.onOpenMessage,
              onRemoveMessage: _removeMessage,
              onRefresh: _load,
              mediaBuilder: _mediaPreview,
            ),
    );
  }

  Future<void> _removeMessage(ChatMessage message) async {
    try {
      await widget.coordinator.unsaveMessage(message);
      if (!mounted) return;
      setState(() {
        _items = _items
            .where((item) => item.message.id != message.id)
            .toList(growable: false);
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('取消收藏失败，请稍后重试。')));
    }
  }

  Widget _mediaPreview(ChatMessage message) {
    final content = message.content;
    final mediaId = content?.mediaId;
    if (content == null || mediaId == null || mediaId.isEmpty) {
      return _SavedCompactMediaPreview(message: message);
    }
    if (!const {'IMAGE', 'GIF', 'STICKER'}.contains(message.type) ||
        !content.isImage) {
      return _SavedCompactMediaPreview(message: message);
    }

    final width = content.width!.toDouble();
    final height = content.height!.toDouble();
    final ratio = width / height;
    var displayWidth = width.clamp(120.0, 260.0);
    var displayHeight = displayWidth / ratio;
    if (displayHeight > 320) {
      displayHeight = 320;
      displayWidth = displayHeight * ratio;
    }
    if (displayHeight < 92) {
      displayHeight = 92;
      displayWidth = (displayHeight * ratio).clamp(120.0, 260.0);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(message.type == 'STICKER' ? 8 : 5),
      child: SizedBox(
        width: displayWidth,
        height: displayHeight,
        child: FutureBuilder<Uint8List>(
          future: _mediaBytesFor(mediaId),
          builder: (context, snapshot) {
            if (snapshot.hasData) {
              final bytes = snapshot.data!;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => unawaited(_openMediaPreview(bytes)),
                child: Image.memory(
                  bytes,
                  fit: message.type == 'STICKER'
                      ? BoxFit.contain
                      : BoxFit.cover,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, _, _) => _mediaLoadFailure(mediaId),
                ),
              );
            }
            if (snapshot.hasError) return _mediaLoadFailure(mediaId);
            return Container(
              color: const Color(0xFFE6E6E6),
              alignment: Alignment.center,
              child: const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _mediaLoadFailure(String mediaId) => Material(
    color: const Color(0xFFE6E6E6),
    child: InkWell(
      onTap: () {
        _mediaDownloadGrants.clear(mediaId);
        unawaited(_mediaCache.evict(mediaId));
        if (mounted) setState(() {});
      },
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined, color: DdColors.textSecondary),
            SizedBox(height: 4),
            Text('加载失败，点击重试', style: TextStyle(fontSize: 11)),
          ],
        ),
      ),
    ),
  );

  Future<Uint8List> _mediaBytesFor(String mediaId) => _mediaCache.resolve(
    mediaId,
    loader: () async {
      final grant = await _mediaDownloadGrants.resolve(
        mediaId,
        loader: () => widget.coordinator.withAuthorizedToken(
          (token) => _mediaApi.createDownloadUrl(
            origin: widget.coordinator.origin,
            accessToken: token,
            mediaId: mediaId,
          ),
        ),
      );
      return _mediaApi.downloadMedia(url: grant.url);
    },
  );

  Future<void> _openMediaPreview(Uint8List bytes) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.94),
      builder: (dialogContext) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 0.7,
                maxScale: 5,
                child: Center(
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.high,
                  ),
                ),
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: SafeArea(
                child: IconButton.filledTonal(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(dialogContext),
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorState() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.cloud_off_outlined,
          size: 42,
          color: DdColors.textTertiary,
        ),
        const SizedBox(height: 12),
        const Text('我的收藏加载失败'),
        const SizedBox(height: 10),
        OutlinedButton(onPressed: _load, child: const Text('重试')),
      ],
    ),
  );
}

class SavedMessagesConversationView extends StatelessWidget {
  const SavedMessagesConversationView({
    super.key,
    required this.items,
    required this.currentUserId,
    required this.conversationFor,
    required this.onOpenMessage,
    required this.onRemoveMessage,
    this.onRefresh,
    this.mediaBuilder,
  });

  final List<SavedMessageItem> items;
  final String currentUserId;
  final ConversationItem? Function(String conversationId) conversationFor;
  final Future<void> Function(ChatMessage message) onOpenMessage;
  final Future<void> Function(ChatMessage message) onRemoveMessage;
  final Future<void> Function()? onRefresh;
  final Widget Function(ChatMessage message)? mediaBuilder;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const _SavedConversationEmptyState();
    }

    final stream = ListView.builder(
      key: const Key('saved-messages-chat-stream'),
      reverse: true,
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 10),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final next = index + 1 < items.length ? items[index + 1] : null;
        final showDay = next == null || !_sameDay(item.savedAt, next.savedAt);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _savedBubble(context, item),
            if (showDay) _dayDivider(item.savedAt.toLocal()),
          ],
        );
      },
    );

    return Column(
      children: [
        Expanded(
          child: onRefresh == null
              ? stream
              : RefreshIndicator(onRefresh: onRefresh!, child: stream),
        ),
        const _SavedComposerHint(),
      ],
    );
  }

  Widget _savedBubble(BuildContext context, SavedMessageItem item) {
    final message = item.message;
    final conversation = conversationFor(message.conversationId);
    final peerName = (conversation?.peer?.displayName ?? '').trim();
    final sourceName = peerName.isEmpty ? '原会话' : peerName;
    final senderName = message.senderUserId == currentUserId ? '我' : sourceName;
    final recalled = message.isRecalled;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 328),
          child: GestureDetector(
            onLongPress: () => _showActions(context, item),
            onSecondaryTap: () => _showActions(context, item),
            child: Material(
              key: Key('saved-bubble-${message.id}'),
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(DdRadii.messageBubble),
                onTap: () => onOpenMessage(message),
                child: Ink(
                  padding: const EdgeInsets.fromLTRB(11, 8, 11, 7),
                  decoration: BoxDecoration(
                    color: Theme.of(context).brightness == Brightness.dark
                        ? const Color(0xFF315234)
                        : DdColors.ownBubble,
                    borderRadius: BorderRadius.circular(DdRadii.messageBubble),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.bookmark_rounded,
                            size: 13,
                            color: DdColors.greenPressed,
                          ),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              '来自 $sourceName',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: DdColors.greenPressed,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (senderName != sourceName ||
                          message.senderUserId == currentUserId) ...[
                        const SizedBox(height: 2),
                        Text(
                          senderName,
                          style: const TextStyle(
                            fontSize: 10,
                            color: DdColors.textSecondary,
                          ),
                        ),
                      ],
                      const SizedBox(height: 6),
                      if (recalled)
                        const Text(
                          '收藏内容不可用',
                          style: TextStyle(
                            fontSize: 13,
                            color: DdColors.textSecondary,
                          ),
                        )
                      else
                        _content(message),
                      const SizedBox(height: 5),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _shortTime(item.savedAt.toLocal()),
                            style: const TextStyle(
                              fontSize: 10,
                              color: DdColors.textTertiary,
                            ),
                          ),
                          const SizedBox(width: 5),
                          const Icon(
                            Icons.check_rounded,
                            size: 13,
                            color: DdColors.greenPressed,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _content(ChatMessage message) {
    if (const {'IMAGE', 'GIF', 'STICKER'}.contains(message.type)) {
      return mediaBuilder?.call(message) ??
          _SavedCompactMediaPreview(message: message);
    }
    if (message.type == 'FILE' || message.type == 'VOICE') {
      return _SavedCompactMediaPreview(message: message);
    }
    final text = (message.content?.text ?? '').trim();
    return Text(
      text.isEmpty ? '消息' : text,
      style: const TextStyle(fontSize: 15, height: 1.38),
    );
  }

  Future<void> _showActions(BuildContext context, SavedMessageItem item) async {
    final action = await showDdActionSheet<String>(
      context,
      items: const [
        DdActionSheetItem(
          value: 'open',
          icon: Icons.open_in_new_rounded,
          label: '查看原消息',
        ),
        DdActionSheetItem(
          value: 'remove',
          icon: Icons.bookmark_remove_outlined,
          label: '取消收藏',
        ),
      ],
    );
    if (action == 'open') {
      await onOpenMessage(item.message);
    } else if (action == 'remove') {
      await onRemoveMessage(item.message);
    }
  }

  Widget _dayDivider(DateTime value) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 3, 0, 13),
    child: Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0x26000000),
          borderRadius: BorderRadius.circular(DdRadii.pill),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          child: Text(
            _dayLabel(value),
            style: const TextStyle(
              fontSize: 10,
              color: Colors.white,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    ),
  );

  static bool _sameDay(DateTime a, DateTime b) {
    final left = a.toLocal();
    final right = b.toLocal();
    return left.year == right.year &&
        left.month == right.month &&
        left.day == right.day;
  }

  static String _dayLabel(DateTime value) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(value.year, value.month, value.day);
    if (date == today) return '今天';
    if (date == today.subtract(const Duration(days: 1))) return '昨天';
    if (value.year == now.year) return '${value.month}月${value.day}日';
    return '${value.year}年${value.month}月${value.day}日';
  }

  static String _shortTime(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
}

class _SavedCompactMediaPreview extends StatelessWidget {
  const _SavedCompactMediaPreview({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final content = message.content;
    return switch (message.type) {
      'FILE' => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.62),
              borderRadius: BorderRadius.circular(DdRadii.control),
            ),
            child: const Icon(Icons.insert_drive_file_outlined, size: 25),
          ),
          const SizedBox(width: 9),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (content?.fileName ?? '').trim().isEmpty
                      ? '文件'
                      : content!.fileName!.trim(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14),
                ),
                if (content?.sizeBytes != null)
                  Text(
                    _formatBytes(content!.sizeBytes!),
                    style: const TextStyle(
                      fontSize: 10,
                      color: DdColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      'VOICE' => SizedBox(
        width: 210,
        child: Row(
          children: [
            const Icon(Icons.play_arrow_rounded, size: 24),
            const SizedBox(width: 5),
            Expanded(
              child: Row(
                children: List.generate(14, (index) {
                  final height = 6.0 + ((index * 7) % 13);
                  return Expanded(
                    child: Center(
                      child: Container(
                        width: 2,
                        height: height,
                        decoration: BoxDecoration(
                          color: const Color(0xFF5C8C52),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${((content?.durationMs ?? 0).clamp(1, 600000) / 1000).ceil()}″',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      'IMAGE' => _fallbackVisual(Icons.image_outlined, '图片'),
      'GIF' => _fallbackVisual(Icons.gif_box_outlined, 'GIF'),
      'STICKER' => _fallbackVisual(Icons.emoji_emotions_outlined, '表情'),
      _ => const Text('消息'),
    };
  }

  Widget _fallbackVisual(IconData icon, String label) => SizedBox(
    width: 180,
    height: 110,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(DdRadii.media),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28, color: DdColors.textSecondary),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 11)),
          ],
        ),
      ),
    ),
  );

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB';
  }
}

class _SavedComposerHint extends StatelessWidget {
  const _SavedComposerHint();

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 11),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: const Border(
          top: BorderSide(color: DdColors.divider, width: 0.5),
        ),
      ),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.bookmark_add_outlined,
            size: 16,
            color: DdColors.textTertiary,
          ),
          SizedBox(width: 7),
          Text(
            '从其他聊天收藏或转发到这里',
            style: TextStyle(fontSize: 12, color: DdColors.textSecondary),
          ),
        ],
      ),
    ),
  );
}

class _SavedConversationEmptyState extends StatelessWidget {
  const _SavedConversationEmptyState();

  @override
  Widget build(BuildContext context) => Container(
    color: _chatBackground(context),
    alignment: Alignment.center,
    child: const Padding(
      padding: EdgeInsets.symmetric(horizontal: 34),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 32,
            backgroundColor: DdColors.green,
            child: Icon(Icons.bookmark_rounded, size: 32, color: Colors.white),
          ),
          SizedBox(height: 14),
          Text(
            '我的收藏',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 7),
          Text(
            '把重要消息、图片、文件和语音收藏到这里。内容仅自己可见，并会在你的设备之间同步。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: DdColors.textSecondary,
            ),
          ),
        ],
      ),
    ),
  );
}

Color _chatBackground(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFF1D1D1D)
    : DdColors.chatBackground;
