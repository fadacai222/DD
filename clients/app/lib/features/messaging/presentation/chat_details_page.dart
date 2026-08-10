import 'dart:async';

import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
import '../../auth/presentation/widgets/profile_avatar.dart';
import '../application/messaging_coordinator.dart';
import '../domain/messaging_models.dart';
import 'conversation_media_page.dart';

final class ChatDetailsResult {
  const ChatDetailsResult({this.messageId, this.conversationHidden = false});

  final String? messageId;
  final bool conversationHidden;
}

class ChatDetailsPage extends StatefulWidget {
  const ChatDetailsPage({
    super.key,
    required this.coordinator,
    required this.conversation,
    required this.onOpenProfile,
    this.onOpenMomentPrivacy,
    this.onChangeBackground,
  });

  final MessagingCoordinator coordinator;
  final ConversationItem conversation;
  final Future<void> Function() onOpenProfile;
  final Future<void> Function()? onOpenMomentPrivacy;
  final Future<void> Function()? onChangeBackground;

  @override
  State<ChatDetailsPage> createState() => _ChatDetailsPageState();
}

class _ChatDetailsPageState extends State<ChatDetailsPage> {
  bool _busy = false;
  String? _error;

  ConversationItem get _conversation =>
      widget.coordinator.conversationFor(widget.conversation.id) ??
      widget.conversation;

  bool get _muted =>
      _conversation.preferences.mutedUntil?.isAfter(DateTime.now().toUtc()) ==
      true;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.coordinator,
      builder: (context, _) {
        final conversation = _conversation;
        final peer = conversation.peer;
        return Scaffold(
          appBar: AppBar(
            title: const Text(
              '聊天详情',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            centerTitle: true,
          ),
          body: ListView(
            padding: const EdgeInsets.only(top: 10, bottom: 28),
            children: [
              if (_error != null) _errorBanner(),
              if (peer != null)
                Material(
                  color: Theme.of(context).colorScheme.surface,
                  child: InkWell(
                    key: const Key('chat-details-profile'),
                    onTap: _busy ? null : widget.onOpenProfile,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 18, 14, 18),
                      child: Row(
                        children: [
                          ClipOval(
                            child: ProfileAvatar(
                              origin: widget.coordinator.origin,
                              accessToken: widget.coordinator.accessToken,
                              userId: peer.id,
                              displayName: peer.displayName,
                              size: 58,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  peer.displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'DDID：${peer.handle}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: DdColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Icon(
                            Icons.chevron_right_rounded,
                            color: DdColors.textTertiary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 10),
              _actionRow(
                key: const Key('chat-details-search'),
                icon: Icons.search_rounded,
                label: '查找聊天记录',
                onTap: _busy ? null : _openSearch,
              ),
              _actionRow(
                key: const Key('chat-details-media'),
                icon: Icons.photo_library_outlined,
                label: '聊天图片、视频与文件',
                onTap: _busy ? null : _openMedia,
              ),
              if (peer != null && widget.onOpenMomentPrivacy != null)
                _actionRow(
                  key: const Key('chat-details-moment-privacy'),
                  icon: Icons.visibility_outlined,
                  label: '朋友圈权限',
                  subtitle: '不看他的朋友圈 / 不让他看我的朋友圈',
                  onTap: _busy ? null : widget.onOpenMomentPrivacy,
                ),
              if (widget.onChangeBackground != null)
                _actionRow(
                  key: const Key('chat-details-background'),
                  icon: Icons.wallpaper_rounded,
                  label: '设置当前聊天背景',
                  onTap: _busy
                      ? null
                      : () => unawaited(widget.onChangeBackground!()),
                ),
              const SizedBox(height: 10),
              _switchRow(
                key: const Key('chat-details-mute'),
                icon: Icons.notifications_off_outlined,
                label: '消息免打扰',
                value: _muted,
                onChanged: _busy ? null : _setMuted,
              ),
              _switchRow(
                key: const Key('chat-details-pin'),
                icon: Icons.push_pin_outlined,
                label: '置顶聊天',
                value: conversation.preferences.isPinned,
                onChanged: _busy ? null : _setPinned,
              ),
              const SizedBox(height: 10),
              _actionRow(
                key: const Key('chat-details-hide'),
                icon: Icons.delete_outline_rounded,
                label: '仅本地删除会话',
                destructive: true,
                onTap: _busy ? null : _confirmHide,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _errorBanner() {
    return Material(
      color: const Color(0xFFFFE8E8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            const Icon(
              Icons.error_outline_rounded,
              size: 18,
              color: DdColors.danger,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _error!,
                style: const TextStyle(fontSize: 12, color: Color(0xFF9D2323)),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() => _error = null),
              icon: const Icon(Icons.close_rounded, size: 17),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionRow({
    Key? key,
    required IconData icon,
    required String label,
    String? subtitle,
    required VoidCallback? onTap,
    bool destructive = false,
  }) {
    final color = destructive ? DdColors.danger : null;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: ListTile(
        key: key,
        leading: Icon(icon, color: color ?? DdColors.textSecondary),
        title: Text(label, style: TextStyle(color: color)),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 11,
                  color: DdColors.textSecondary,
                ),
              ),
        trailing: const Icon(
          Icons.chevron_right_rounded,
          size: 20,
          color: DdColors.textTertiary,
        ),
        onTap: onTap,
      ),
    );
  }

  Widget _switchRow({
    Key? key,
    required IconData icon,
    required String label,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SwitchListTile(
        key: key,
        secondary: Icon(icon, color: DdColors.textSecondary),
        title: Text(label),
        value: value,
        onChanged: onChanged,
      ),
    );
  }

  Future<void> _setPinned(bool value) => _run(() async {
    await widget.coordinator.setPinned(_conversation, value);
  });

  Future<void> _setMuted(bool value) => _run(() async {
    if (value) {
      await widget.coordinator.muteUntil(
        _conversation,
        DateTime.utc(9998, 12, 31, 23, 59, 59),
      );
    } else {
      await widget.coordinator.clearMute(_conversation);
    }
  });

  Future<void> _openSearch() async {
    final selected = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => _ConversationMessageSearchPage(
          coordinator: widget.coordinator,
          conversation: _conversation,
        ),
      ),
    );
    if (selected == null || !mounted) return;
    Navigator.of(context).pop(ChatDetailsResult(messageId: selected));
  }

  Future<void> _openMedia() async {
    final selected = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => ConversationMediaPage(
          coordinator: widget.coordinator,
          conversation: _conversation,
        ),
      ),
    );
    if (selected == null || !mounted) return;
    Navigator.of(context).pop(ChatDetailsResult(messageId: selected));
  }

  Future<void> _confirmHide() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('仅本地删除会话？'),
        content: const Text('会从你的会话列表隐藏，不会删除对方消息，也不会为双方删除历史记录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('chat-details-hide-confirm'),
            style: FilledButton.styleFrom(backgroundColor: DdColors.danger),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('仅本地删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() async {
      await widget.coordinator.hideConversation(_conversation);
      if (mounted) {
        Navigator.of(
          context,
        ).pop(const ChatDetailsResult(conversationHidden: true));
      }
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _error = '操作失败，请检查网络后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _ConversationMessageSearchPage extends StatefulWidget {
  const _ConversationMessageSearchPage({
    required this.coordinator,
    required this.conversation,
  });

  final MessagingCoordinator coordinator;
  final ConversationItem conversation;

  @override
  State<_ConversationMessageSearchPage> createState() =>
      _ConversationMessageSearchPageState();
}

class _ConversationMessageSearchPageState
    extends State<_ConversationMessageSearchPage> {
  late final TextEditingController _query;
  List<MessageSearchHit> _hits = const [];
  bool _busy = false;
  bool _searched = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _query = TextEditingController();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('查找聊天记录')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: TextField(
              key: const Key('chat-details-search-field'),
              controller: _query,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => unawaited(_search()),
              decoration: InputDecoration(
                hintText: '搜索当前聊天',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: IconButton(
                  key: const Key('chat-details-search-submit'),
                  tooltip: '搜索',
                  onPressed: _busy ? null : _search,
                  icon: const Icon(Icons.arrow_forward_rounded),
                ),
              ),
            ),
          ),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _error!,
                style: const TextStyle(color: DdColors.danger),
              ),
            ),
          Expanded(
            child: !_searched
                ? const Center(
                    child: Text(
                      '输入关键词搜索当前聊天',
                      style: TextStyle(color: DdColors.textSecondary),
                    ),
                  )
                : _hits.isEmpty
                ? const Center(
                    child: Text(
                      '没有找到相关消息',
                      style: TextStyle(color: DdColors.textSecondary),
                    ),
                  )
                : ListView.separated(
                    itemCount: _hits.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final message = _hits[index].message;
                      return ListTile(
                        key: Key('chat-details-search-result-${message.id}'),
                        title: Text(
                          message.content?.text ?? '',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          _formatTime(message.createdAt.toLocal()),
                        ),
                        onTap: () => Navigator.pop(context, message.id),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _search() async {
    final query = _query.text.trim();
    if (query.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final hits = await widget.coordinator.searchMessages(
        query,
        conversationId: widget.conversation.id,
      );
      if (!mounted) return;
      setState(() {
        _hits = hits;
        _searched = true;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _searched = true;
          _error = '搜索失败，请稍后重试。';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _formatTime(DateTime time) =>
      '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
}
