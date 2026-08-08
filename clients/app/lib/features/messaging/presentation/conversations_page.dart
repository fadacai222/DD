import 'dart:async';

import 'package:flutter/material.dart';
import 'package:realtime_poc/realtime_poc.dart';

import '../../../core/widgets/dd_action_sheet.dart';
import '../../../theme/app_theme.dart';
import '../../auth/presentation/widgets/profile_avatar.dart';
import '../../calls/domain/call_session.dart';
import '../application/messaging_coordinator.dart';
import '../domain/messaging_models.dart';
import 'text_chat_page.dart';

class ConversationsPage extends StatefulWidget {
  const ConversationsPage({
    super.key,
    required this.origin,
    required this.accessToken,
    required this.currentUserId,
    required this.deviceId,
    this.currentUserDisplayName = '',
    this.currentUserAvatarRevision = 0,
    this.onStartCall,
    this.onOpenContacts,
    this.coordinator,
    this.hostVisible = true,
    this.embedded = false,
  });

  final Uri origin;
  final String accessToken;
  final String currentUserId;
  final String deviceId;
  final String currentUserDisplayName;
  final int currentUserAvatarRevision;
  final Future<void> Function(String peerId, String peerName, CallKind kind)?
  onStartCall;
  final VoidCallback? onOpenContacts;
  final MessagingCoordinator? coordinator;
  final bool hostVisible;
  final bool embedded;

  @override
  State<ConversationsPage> createState() => _ConversationsPageState();
}

class _ConversationsPageState extends State<ConversationsPage> {
  late final MessagingCoordinator _coordinator;
  late final bool _ownsCoordinator;
  late final TextEditingController _searchController;
  String _query = '';
  String? _selectedConversationId;

  @override
  void initState() {
    super.initState();
    _ownsCoordinator = widget.coordinator == null;
    _coordinator =
        widget.coordinator ??
        MessagingCoordinator(
          origin: widget.origin,
          accessToken: widget.accessToken,
          currentUserId: widget.currentUserId,
          deviceId: widget.deviceId,
        );
    _searchController = TextEditingController();
    if (_ownsCoordinator) unawaited(_coordinator.initialize());
  }

  @override
  void dispose() {
    _searchController.dispose();
    if (_ownsCoordinator) _coordinator.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _coordinator,
      builder: (context, _) {
        final content = LayoutBuilder(
          builder: (context, constraints) {
            final desktop = constraints.maxWidth >= 680;
            if (desktop) return _buildDesktop(context);
            return _buildMobile(context);
          },
        );
        if (widget.embedded) return content;
        return Scaffold(body: SafeArea(child: content));
      },
    );
  }

  Widget _buildMobile(BuildContext context) {
    return Column(
      children: [
        _mobileHeader(context),
        if (_coordinator.errorMessage != null) _buildErrorBar(context),
        if (_coordinator.busy) const LinearProgressIndicator(minHeight: 1),
        Expanded(child: _conversationList(context, desktop: false)),
      ],
    );
  }

  Widget _mobileHeader(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          SizedBox(
            height: 52,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '消息',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _connectionDot(),
                  const SizedBox(width: 6),
                  IconButton(
                    key: const Key('messaging-sync'),
                    tooltip: '同步',
                    visualDensity: VisualDensity.compact,
                    onPressed: _coordinator.busy ? null : _sync,
                    icon: const Icon(Icons.sync_rounded, size: 21),
                  ),
                ],
              ),
            ),
          ),
          _searchBox(horizontal: 12),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildDesktop(BuildContext context) {
    final selected = _selectedConversation();
    return Row(
      children: [
        SizedBox(
          width: 248,
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: Column(
              children: [
                _desktopListHeader(),
                if (_coordinator.errorMessage != null) _buildErrorBar(context),
                if (_coordinator.busy)
                  const LinearProgressIndicator(minHeight: 1),
                Expanded(child: _conversationList(context, desktop: true)),
              ],
            ),
          ),
        ),
        const VerticalDivider(width: 1, thickness: 0.5),
        Expanded(
          child: selected == null
              ? _desktopEmptyState(context)
              : TextChatPage(
                  key: ValueKey('desktop-chat-${selected.id}'),
                  coordinator: _coordinator,
                  conversation: selected,
                  currentUserId: widget.currentUserId,
                  currentUserDisplayName: widget.currentUserDisplayName,
                  currentUserAvatarRevision: widget.currentUserAvatarRevision,
                  onStartCall: widget.onStartCall,
                  hostVisible: widget.hostVisible,
                  embedded: true,
                ),
        ),
      ],
    );
  }

  Widget _desktopListHeader() {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        height: 50,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 7, 8),
          child: Row(
            children: [
              Expanded(child: _searchBox(horizontal: 0)),
              const SizedBox(width: 6),
              PopupMenuButton<String>(
                key: const Key('messaging-create-menu'),
                tooltip: '新建',
                offset: const Offset(0, 36),
                elevation: 10,
                color: Theme.of(context).colorScheme.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(7),
                ),
                menuPadding: const EdgeInsets.symmetric(vertical: 5),
                onSelected: (value) {
                  if (value == 'contacts') widget.onOpenContacts?.call();
                },
                itemBuilder: (_) => [
                  const PopupMenuItem<String>(
                    enabled: false,
                    value: 'group',
                    child: _CreateMenuRow(
                      icon: Icons.chat_bubble_outline_rounded,
                      label: '发起群聊',
                      trailing: '开发中',
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'contacts',
                    enabled: widget.onOpenContacts != null,
                    child: const _CreateMenuRow(
                      icon: Icons.person_add_alt_1_outlined,
                      label: '添加朋友',
                    ),
                  ),
                  const PopupMenuItem<String>(
                    enabled: false,
                    value: 'note',
                    child: _CreateMenuRow(
                      icon: Icons.edit_note_rounded,
                      label: '写笔记',
                      trailing: '开发中',
                    ),
                  ),
                ],
                child: Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Theme.of(context).brightness == Brightness.dark
                        ? const Color(0xFF303030)
                        : const Color(0xFFE8E8E8),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Icon(Icons.add_rounded, size: 21),
                ),
              ),
              const SizedBox(width: 3),
              Tooltip(
                message: switch (_coordinator.realtimeState) {
                  RealtimeConnectionState.connected => '实时已连接',
                  RealtimeConnectionState.connecting => '实时连接中',
                  RealtimeConnectionState.disconnected => '实时已断开，将自动补同步',
                },
                child: _connectionDot(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _searchBox({required double horizontal}) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontal),
      child: SizedBox(
        height: 34,
        child: TextField(
          key: const Key('messaging-search'),
          controller: _searchController,
          onChanged: (value) =>
              setState(() => _query = value.trim().toLowerCase()),
          decoration: InputDecoration(
            hintText: '搜索',
            prefixIcon: const Icon(Icons.search_rounded, size: 18),
            prefixIconConstraints: const BoxConstraints(minWidth: 34),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    tooltip: '清除',
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _query = '');
                    },
                    icon: const Icon(Icons.cancel_rounded, size: 16),
                  ),
            contentPadding: const EdgeInsets.symmetric(vertical: 7),
          ),
        ),
      ),
    );
  }

  Widget _connectionDot() {
    final (color, tooltip) = switch (_coordinator.realtimeState) {
      RealtimeConnectionState.connected => (DdColors.green, '实时已连接'),
      RealtimeConnectionState.connecting => (const Color(0xFFF0A020), '实时连接中'),
      RealtimeConnectionState.disconnected => (
        DdColors.textTertiary,
        '实时已断开，将使用同步补偿',
      ),
    };
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }

  Widget _conversationList(BuildContext context, {required bool desktop}) {
    final conversations = _filteredConversations();
    if (_coordinator.conversations.isEmpty) {
      return RefreshIndicator(
        onRefresh: _sync,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(height: desktop ? 120 : 96),
            const Icon(
              Icons.chat_bubble_outline_rounded,
              size: 42,
              color: DdColors.textTertiary,
            ),
            const SizedBox(height: 12),
            const Center(
              child: Text(
                '暂无会话',
                style: TextStyle(color: DdColors.textSecondary),
              ),
            ),
            const SizedBox(height: 5),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 30),
              child: Text(
                '成为好友后会自动创建私聊',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: DdColors.textTertiary),
              ),
            ),
          ],
        ),
      );
    }
    if (conversations.isEmpty) {
      return const Center(
        child: Text('没有匹配的会话', style: TextStyle(color: DdColors.textSecondary)),
      );
    }
    return RefreshIndicator(
      onRefresh: _sync,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: conversations.length,
        itemExtent: 68,
        itemBuilder: (context, index) =>
            _conversationTile(conversations[index], desktop: desktop),
      ),
    );
  }

  List<ConversationItem> _filteredConversations() {
    if (_query.isEmpty) return _coordinator.conversations;
    return _coordinator.conversations
        .where((conversation) {
          final peer = conversation.peer;
          final last = conversation.lastMessage?.content?.text ?? '';
          return (peer?.displayName.toLowerCase().contains(_query) ?? false) ||
              (peer?.handle.toLowerCase().contains(_query) ?? false) ||
              last.toLowerCase().contains(_query);
        })
        .toList(growable: false);
  }

  Widget _conversationTile(
    ConversationItem conversation, {
    required bool desktop,
  }) {
    final peer = conversation.peer;
    final title = peer?.displayName ?? '会话';
    final draft = _coordinator.draftFor(conversation.id);
    final pendingCount = _coordinator.pendingFor(conversation.id).length;
    final muted = _isMuted(conversation);
    final selected = desktop && _selectedConversationId == conversation.id;
    final pinned = conversation.preferences.isPinned;
    final background = selected
        ? (Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF333333)
              : const Color(0xFFE2E2E2))
        : pinned
        ? (Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF292929)
              : const Color(0xFFF2F2F2))
        : Theme.of(context).colorScheme.surface;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () => _showConversationActions(conversation),
      onSecondaryTapDown: (details) =>
          _showConversationMenuAt(conversation, details.globalPosition),
      child: Material(
        color: background,
        child: InkWell(
          key: Key('conversation-${conversation.id}'),
          onTap: () => _openConversation(conversation, desktop: desktop),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(11, 8, 10, 8),
            child: Row(
              children: [
                _avatar(peer?.id ?? '', title),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          if (conversation.updatedAt.year > 1970)
                            Text(
                              _conversationTime(
                                conversation.updatedAt.toLocal(),
                              ),
                              style: const TextStyle(
                                fontSize: 10,
                                color: DdColors.textTertiary,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          if (draft.isNotEmpty)
                            const Text(
                              '[草稿] ',
                              style: TextStyle(
                                fontSize: 12,
                                color: DdColors.danger,
                              ),
                            ),
                          if (pendingCount > 0)
                            const Padding(
                              padding: EdgeInsets.only(right: 4),
                              child: Icon(
                                Icons.schedule_rounded,
                                size: 13,
                                color: DdColors.textTertiary,
                              ),
                            ),
                          Expanded(
                            child: Text(
                              draft.isNotEmpty ? draft : _preview(conversation),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: DdColors.textSecondary,
                              ),
                            ),
                          ),
                          if (muted)
                            const Padding(
                              padding: EdgeInsets.only(left: 5),
                              child: Icon(
                                Icons.notifications_off_rounded,
                                size: 14,
                                color: DdColors.textTertiary,
                              ),
                            ),
                          if (conversation.unreadCount > 0) ...[
                            const SizedBox(width: 6),
                            _unreadBadge(
                              conversation.unreadCount,
                              muted: muted,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _avatar(String userId, String title) {
    if (userId.isEmpty) {
      final letter = title.trim().isEmpty ? '?' : title.trim().characters.first;
      return Container(
        width: 46,
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFF6F9FCA),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(
          letter,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 19,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    return ProfileAvatar(
      origin: widget.origin,
      accessToken: widget.accessToken,
      userId: userId,
      displayName: title,
      size: 46,
    );
  }

  Widget _unreadBadge(int unread, {required bool muted}) {
    final text = unread > 99 ? '99+' : '$unread';
    return Container(
      constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      decoration: BoxDecoration(
        color: muted ? const Color(0xFFB8B8B8) : DdColors.danger,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 10, height: 1),
      ),
    );
  }

  Widget _desktopEmptyState(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF1D1D1D)
          : DdColors.chatBackground,
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_outlined, size: 56, color: Color(0xFFCDCDCD)),
            SizedBox(height: 14),
            Text(
              '选择一个会话开始聊天',
              style: TextStyle(fontSize: 13, color: DdColors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorBar(BuildContext context) {
    return Material(
      color: const Color(0xFFFFE8E8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
        child: Row(
          children: [
            const Icon(
              Icons.error_outline_rounded,
              size: 16,
              color: DdColors.danger,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _coordinator.errorMessage!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Color(0xFF9D2323)),
              ),
            ),
            IconButton(
              tooltip: '关闭',
              visualDensity: VisualDensity.compact,
              onPressed: _coordinator.clearError,
              icon: const Icon(Icons.close_rounded, size: 16),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openConversation(
    ConversationItem conversation, {
    required bool desktop,
  }) async {
    if (desktop) {
      if (_selectedConversationId != conversation.id) {
        setState(() => _selectedConversationId = conversation.id);
      }
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TextChatPage(
          coordinator: _coordinator,
          conversation: conversation,
          currentUserId: widget.currentUserId,
          currentUserDisplayName: widget.currentUserDisplayName,
          currentUserAvatarRevision: widget.currentUserAvatarRevision,
          onStartCall: widget.onStartCall,
          hostVisible: true,
        ),
      ),
    );
  }

  ConversationItem? _selectedConversation() {
    final selectedId = _selectedConversationId;
    if (selectedId == null) return null;
    return _coordinator.conversationFor(selectedId);
  }

  Future<void> _showConversationActions(ConversationItem conversation) async {
    final current =
        _coordinator.conversationFor(conversation.id) ?? conversation;
    final muted = _isMuted(current);
    final action = await showDdActionSheet<String>(
      context,
      items: [
        DdActionSheetItem(
          value: 'pin',
          icon: current.preferences.isPinned
              ? Icons.push_pin_outlined
              : Icons.push_pin_rounded,
          label: current.preferences.isPinned ? '取消置顶' : '置顶聊天',
        ),
        DdActionSheetItem(
          value: muted ? 'unmute' : 'mute-8h',
          icon: muted
              ? Icons.notifications_active_outlined
              : Icons.notifications_off_outlined,
          label: muted ? '取消免打扰' : '免打扰 8 小时',
        ),
        if (!muted)
          const DdActionSheetItem(
            value: 'mute-7d',
            icon: Icons.bedtime_outlined,
            label: '免打扰 7 天',
          ),
        if (current.unreadCount > 0)
          const DdActionSheetItem(
            value: 'read',
            icon: Icons.mark_chat_read_outlined,
            label: '标为已读',
          ),
      ],
    );
    await _applyConversationAction(current, action);
  }

  Future<void> _showConversationMenuAt(
    ConversationItem conversation,
    Offset globalPosition,
  ) async {
    final current =
        _coordinator.conversationFor(conversation.id) ?? conversation;
    final muted = _isMuted(current);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<String>(
      context: context,
      color: Theme.of(context).colorScheme.surface,
      elevation: 10,
      shadowColor: Colors.black.withValues(alpha: 0.22),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      menuPadding: const EdgeInsets.symmetric(vertical: 5),
      constraints: const BoxConstraints(minWidth: 190, maxWidth: 232),
      position: RelativeRect.fromRect(
        Rect.fromPoints(globalPosition, globalPosition),
        Offset.zero & overlay.size,
      ),
      items: [
        _conversationMenuItem(
          value: 'pin',
          icon: current.preferences.isPinned
              ? Icons.push_pin_outlined
              : Icons.push_pin_rounded,
          label: current.preferences.isPinned ? '取消置顶' : '置顶聊天',
        ),
        _conversationMenuItem(
          value: muted ? 'unmute' : 'mute-8h',
          icon: muted
              ? Icons.notifications_active_outlined
              : Icons.notifications_off_outlined,
          label: muted ? '取消免打扰' : '免打扰 8 小时',
        ),
        if (!muted)
          _conversationMenuItem(
            value: 'mute-7d',
            icon: Icons.bedtime_outlined,
            label: '免打扰 7 天',
          ),
        if (current.unreadCount > 0) ...[
          const PopupMenuDivider(height: 5),
          _conversationMenuItem(
            value: 'read',
            icon: Icons.mark_chat_read_outlined,
            label: '标为已读',
          ),
        ],
      ],
    );
    await _applyConversationAction(current, action);
  }

  PopupMenuItem<String> _conversationMenuItem({
    required String value,
    required IconData icon,
    required String label,
  }) {
    final color = Theme.of(context).colorScheme.onSurface;
    return PopupMenuItem<String>(
      value: value,
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 11),
          Expanded(
            child: Text(label, style: TextStyle(fontSize: 13, color: color)),
          ),
        ],
      ),
    );
  }

  Future<void> _applyConversationAction(
    ConversationItem conversation,
    String? action,
  ) async {
    if (action == null) return;
    try {
      switch (action) {
        case 'pin':
          await _coordinator.setPinned(
            conversation,
            !conversation.preferences.isPinned,
          );
        case 'unmute':
          await _coordinator.clearMute(conversation);
        case 'mute-8h':
          await _coordinator.muteUntil(
            conversation,
            DateTime.now().toUtc().add(const Duration(hours: 8)),
          );
        case 'mute-7d':
          await _coordinator.muteUntil(
            conversation,
            DateTime.now().toUtc().add(const Duration(days: 7)),
          );
        case 'read':
          await _coordinator.markReadThrough(
            conversation.id,
            conversation.lastSequence,
          );
      }
    } catch (_) {
      // Coordinator/API state surfaces the actionable error.
    }
  }

  bool _isMuted(ConversationItem conversation) =>
      conversation.preferences.mutedUntil?.isAfter(DateTime.now().toUtc()) ==
      true;

  String _preview(ConversationItem conversation) {
    final message = conversation.lastMessage;
    if (message == null) return '还没有消息';
    if (message.isRecalled) return '消息已撤回';
    if (message.type == 'TEXT') return message.content?.text ?? '';
    return switch (message.type) {
      'IMAGE' => '[图片]',
      'GIF' => '[GIF]',
      'STICKER' => '[表情]',
      'VOICE' => '[语音]',
      'FILE' => '[文件]',
      _ => '[${message.type}]',
    };
  }

  String _conversationTime(DateTime time) {
    final now = DateTime.now();
    if (now.year == time.year &&
        now.month == time.month &&
        now.day == time.day) {
      return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    }
    final yesterday = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(const Duration(days: 1));
    final date = DateTime(time.year, time.month, time.day);
    if (date == yesterday) return '昨天';
    if (now.year == time.year) return '${time.month}/${time.day}';
    return '${time.year}/${time.month}/${time.day}';
  }

  Future<void> _sync() async {
    await _coordinator.flushPending();
    await _coordinator.syncNow();
  }
}

class _CreateMenuRow extends StatelessWidget {
  const _CreateMenuRow({
    required this.icon,
    required this.label,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 11),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          if (trailing != null)
            Text(
              trailing!,
              style: const TextStyle(
                fontSize: 10,
                color: DdColors.textTertiary,
              ),
            ),
        ],
      ),
    );
  }
}
