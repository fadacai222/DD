import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:realtime_poc/realtime_poc.dart';

import '../../../core/logging/client_log.dart';
import '../../../core/widgets/dd_action_sheet.dart';
import '../../../theme/app_theme.dart';
import '../../auth/presentation/widgets/profile_avatar.dart';
import '../../calls/domain/call_session.dart';
import '../../groups/domain/group_models.dart';
import '../../groups/presentation/create_group_page.dart';
import '../application/messaging_coordinator.dart';
import '../domain/messaging_models.dart';
import 'conversations_page_controller.dart';
import 'desktop_inspector.dart';
import 'messaging_search_page.dart';
import 'saved_messages_page.dart';
import 'text_chat_page.dart';
import 'widgets/group_avatar.dart';

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
    this.onOpenAddFriend,
    this.onOpenScanner,
    this.coordinator,
    this.navigationController,
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
  final VoidCallback? onOpenAddFriend;
  final VoidCallback? onOpenScanner;
  final MessagingCoordinator? coordinator;
  final ConversationsPageController? navigationController;
  final bool hostVisible;
  final bool embedded;

  @override
  State<ConversationsPage> createState() => _ConversationsPageState();
}

class _ConversationsPageState extends State<ConversationsPage> {
  late final MessagingCoordinator _coordinator;
  late final bool _ownsCoordinator;
  late final TextEditingController _searchController;
  late final DesktopInspectorController _inspector;
  String _query = '';
  String? _selectedConversationId;
  String? _selectedInitialMessageId;
  bool _showArchived = false;
  int _handledNavigationSerial = 0;

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
    _inspector = DesktopInspectorController();
    widget.navigationController?.addListener(_handleNavigationRequest);
    if (_ownsCoordinator) unawaited(_coordinator.initialize());
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _handleNavigationRequest(),
    );
  }

  @override
  void didUpdateWidget(covariant ConversationsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(
      oldWidget.navigationController,
      widget.navigationController,
    )) {
      oldWidget.navigationController?.removeListener(_handleNavigationRequest);
      widget.navigationController?.addListener(_handleNavigationRequest);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _handleNavigationRequest(),
      );
    }
  }

  @override
  void dispose() {
    widget.navigationController?.removeListener(_handleNavigationRequest);
    _searchController.dispose();
    _inspector.dispose();
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
            width: double.infinity,
            height: 52,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Text(
                  _showArchived ? '已归档' : 'DD',
                  key: const Key('messaging-mobile-title'),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Positioned(
                  left: _showArchived ? 2 : 16,
                  child: _showArchived
                      ? IconButton(
                          key: const Key('archive-back'),
                          tooltip: '返回消息',
                          onPressed: () =>
                              setState(() => _showArchived = false),
                          icon: const Icon(
                            Icons.arrow_back_ios_new_rounded,
                            size: 19,
                          ),
                        )
                      : Tooltip(
                          message: switch (_coordinator.realtimeState) {
                            RealtimeConnectionState.connected => '实时已连接',
                            RealtimeConnectionState.connecting => '实时连接中',
                            RealtimeConnectionState.disconnected =>
                              '实时已断开，将自动补同步',
                          },
                          child: _connectionDot(),
                        ),
                ),
                if (!_showArchived)
                  Positioned(right: 8, child: _createMenuButton(compact: true)),
              ],
            ),
          ),
          _mobileSearchLauncher(),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildDesktop(BuildContext context) {
    final selected = _selectedConversation();
    return LayoutBuilder(
      builder: (context, constraints) {
        final inlineInspector = constraints.maxWidth >= 1120;
        final core = Row(
          children: [
            SizedBox(
              key: const Key('desktop-conversation-sidebar'),
              width: DdDesktopTokens.sidebarWidth,
              child: ColoredBox(
                color: DdDesktopTokens.sidebarSurface(
                  Theme.of(context).brightness,
                ),
                child: Column(
                  children: [
                    _desktopListHeader(),
                    if (_coordinator.errorMessage != null)
                      _buildErrorBar(context),
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
                      key: ValueKey(
                        _selectedInitialMessageId == null
                            ? 'desktop-chat-${selected.id}'
                            : 'desktop-chat-${selected.id}-${_selectedInitialMessageId!}',
                      ),
                      coordinator: _coordinator,
                      conversation: selected,
                      currentUserId: widget.currentUserId,
                      currentUserDisplayName: widget.currentUserDisplayName,
                      currentUserAvatarRevision:
                          widget.currentUserAvatarRevision,
                      onStartCall: widget.onStartCall,
                      onOpenDirectChat: _openDirectChatByUserId,
                      hostVisible: widget.hostVisible,
                      embedded: true,
                      savedMessagesMode: selected.type == 'SELF',
                      initialMessageId: _selectedInitialMessageId,
                      inspectorController: _inspector,
                    ),
            ),
            if (inlineInspector)
              AnimatedBuilder(
                animation: _inspector,
                builder: (context, _) => _inspector.isOpen
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const VerticalDivider(width: 1, thickness: 0.5),
                          RightInspectorPane(controller: _inspector),
                        ],
                      )
                    : const SizedBox.shrink(),
              ),
          ],
        );
        return AnimatedBuilder(
          animation: _inspector,
          builder: (context, _) => Stack(
            fit: StackFit.expand,
            children: [
              core,
              if (!inlineInspector)
                DesktopInspectorOverlay(controller: _inspector),
            ],
          ),
        );
      },
    );
  }

  Widget _desktopListHeader() {
    return Material(
      color: DdDesktopTokens.sidebarSurface(Theme.of(context).brightness),
      child: SizedBox(
        height: 50,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 7, 8),
          child: Row(
            children: [
              if (_showArchived) ...[
                IconButton(
                  key: const Key('desktop-archive-back'),
                  tooltip: '返回消息',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => _showArchived = false),
                  icon: const Icon(Icons.arrow_back_rounded, size: 20),
                ),
                const SizedBox(width: 4),
              ],
              Expanded(child: _searchBox(horizontal: 0)),
              const SizedBox(width: 6),
              if (!_showArchived) _createMenuButton(),
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

  Widget _mobileSearchLauncher() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Material(
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF2B2B2B)
            : const Color(0xFFEDEDED),
        borderRadius: BorderRadius.circular(DdRadii.pill),
        child: InkWell(
          key: const Key('messaging-mobile-search-launcher'),
          borderRadius: BorderRadius.circular(DdRadii.pill),
          onTap: _openMobileSearch,
          child: const SizedBox(
            height: 36,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.search_rounded,
                  size: 18,
                  color: DdColors.textSecondary,
                ),
                SizedBox(width: 5),
                Text(
                  '搜索',
                  style: TextStyle(fontSize: 14, color: DdColors.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openMobileSearch() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MessagingSearchPage(
          coordinator: _coordinator,
          onOpenConversation: (conversation, messageId) => _openConversation(
            conversation,
            desktop: false,
            initialMessageId: messageId,
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
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 14,
            color: DdColors.textPrimary,
            fontWeight: FontWeight.w400,
          ),
          onChanged: (value) =>
              setState(() => _query = value.trim().toLowerCase()),
          decoration: InputDecoration(
            hintText: '搜索',
            hintStyle: const TextStyle(
              fontSize: 14,
              color: DdColors.textSecondary,
              fontWeight: FontWeight.w400,
            ),
            prefixIcon: const Icon(
              Icons.search_rounded,
              size: 17,
              color: DdColors.textSecondary,
            ),
            prefixIconConstraints: const BoxConstraints(minWidth: 34),
            suffixIcon: _query.isEmpty
                ? const SizedBox(width: 34)
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

  Widget _createMenuButton({bool compact = false}) {
    return PopupMenuButton<String>(
      key: const Key('messaging-create-menu'),
      tooltip: '更多功能',
      offset: Offset(0, compact ? 38 : 36),
      elevation: 12,
      color: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF2A2A2A)
          : const Color(0xFF4C4C4C),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DdRadii.surface),
      ),
      menuPadding: const EdgeInsets.symmetric(vertical: 5),
      onSelected: _handleCreateAction,
      itemBuilder: (_) => const [
        PopupMenuItem<String>(
          value: 'group',
          child: _CreateMenuRow(
            icon: Icons.chat_bubble_outline_rounded,
            label: '发起群聊',
            lightOnDark: true,
          ),
        ),
        PopupMenuItem<String>(
          value: 'contacts',
          child: _CreateMenuRow(
            icon: Icons.person_add_alt_1_outlined,
            label: '添加联系人',
            lightOnDark: true,
          ),
        ),
        PopupMenuItem<String>(
          value: 'scan',
          child: _CreateMenuRow(
            icon: Icons.qr_code_scanner_rounded,
            label: '扫一扫',
            lightOnDark: true,
          ),
        ),
      ],
      child: compact
          ? const SizedBox(
              width: 40,
              height: 40,
              child: Icon(Icons.add_rounded, size: 27),
            )
          : Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xFF303030)
                    : const Color(0xFFE8E8E8),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.add_rounded, size: 21),
            ),
    );
  }

  void _handleCreateAction(String value) {
    if (value == 'group') {
      unawaited(_openCreateGroup());
      return;
    }
    if (value == 'contacts') {
      (widget.onOpenAddFriend ?? widget.onOpenContacts)?.call();
      return;
    }
    if (value == 'scan') {
      widget.onOpenScanner?.call();
    }
  }

  Future<void> _openCreateGroup() async {
    final group = await Navigator.of(context).push<GroupInfo>(
      MaterialPageRoute<GroupInfo>(
        builder: (_) => CreateGroupPage(
          origin: widget.origin,
          accessToken: _coordinator.accessToken,
        ),
      ),
    );
    if (!mounted || group == null) return;
    await _coordinator.refreshConversations();
    if (!mounted) return;
    final conversation = _coordinator.conversationFor(group.id);
    if (conversation == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('群聊已创建，但会话尚未同步完成，请稍后刷新。')));
      return;
    }
    final desktop = MediaQuery.sizeOf(context).width >= 680;
    await _openConversation(conversation, desktop: desktop);
  }

  Future<void> _openSavedMessages({bool desktop = false}) async {
    if (desktop) {
      try {
        final conversation = await _coordinator.ensureSavedConversation();
        if (!mounted) return;
        setState(() => _selectedConversationId = conversation.id);
      } catch (_) {
        // Coordinator/API state exposes the actionable error in the list.
      }
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SavedMessagesPage(
          coordinator: _coordinator,
          onOpenMessage: _openSavedMessage,
        ),
      ),
    );
  }

  Future<void> _openSavedMessage(ChatMessage message) async {
    final conversation = _coordinator.conversationFor(message.conversationId);
    if (conversation == null || !mounted) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('原会话当前不可用。')));
      }
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => TextChatPage(
          coordinator: _coordinator,
          conversation: conversation,
          currentUserId: widget.currentUserId,
          currentUserDisplayName: widget.currentUserDisplayName,
          currentUserAvatarRevision: widget.currentUserAvatarRevision,
          onStartCall: widget.onStartCall,
          onOpenDirectChat: _openDirectChatByUserId,
          initialMessageId: message.id,
        ),
      ),
    );
  }

  Widget _connectionDot() {
    if (_coordinator.realtimeState == RealtimeConnectionState.connecting) {
      return const Tooltip(
        message: '实时连接中',
        child: SizedBox.square(
          key: Key('realtime-connecting-indicator'),
          dimension: 12,
          child: CircularProgressIndicator(
            strokeWidth: 1.8,
            color: Color(0xFFF0A020),
          ),
        ),
      );
    }
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
    final archivedCount = _coordinator.conversations
        .where((item) => item.preferences.isArchived)
        .length;
    final showArchiveEntry =
        !_showArchived && archivedCount > 0 && _query.isEmpty;
    final showSavedEntry =
        !_showArchived &&
        (_query.isEmpty || '我的收藏'.contains(_query) || '收藏'.contains(_query));
    if (conversations.isEmpty && !showArchiveEntry && !showSavedEntry) {
      return Center(
        child: Text(
          _showArchived ? '没有已归档会话' : '没有匹配的会话',
          style: const TextStyle(color: DdColors.textSecondary),
        ),
      );
    }
    final leadingCount = (showSavedEntry ? 1 : 0) + (showArchiveEntry ? 1 : 0);
    return RefreshIndicator(
      onRefresh: _sync,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: conversations.length + leadingCount,
        itemBuilder: (context, index) {
          var offset = 0;
          if (showArchiveEntry) {
            if (index == 0) {
              return _archiveEntry(archivedCount, desktop: desktop);
            }
            offset++;
          }
          if (showSavedEntry) {
            if (index == offset) return _savedMessagesEntry(desktop: desktop);
            offset++;
          }
          return SizedBox(
            height: 68,
            child: _conversationTile(
              conversations[index - offset],
              desktop: desktop,
            ),
          );
        },
      ),
    );
  }

  ConversationItem? _savedConversation() {
    for (final conversation in _coordinator.conversations) {
      if (conversation.type == 'SELF') return conversation;
    }
    return null;
  }

  Widget _savedMessagesEntry({required bool desktop}) {
    final saved = _savedConversation();
    final preview = saved == null ? '给自己发送消息和文件' : _preview(saved);
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: InkWell(
        key: const Key('saved-messages-conversation-entry'),
        onTap: () => unawaited(_openSavedMessages(desktop: desktop)),
        child: SizedBox(
          height: 68,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Container(
                  key: const Key('saved-messages-avatar'),
                  width: 46,
                  height: 46,
                  decoration: const BoxDecoration(
                    color: Color(0xFF4E9BEA),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.bookmark_rounded,
                    size: 25,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '我的收藏',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (saved != null && saved.updatedAt.year > 1970)
                            Text(
                              _conversationTime(saved.updatedAt.toLocal()),
                              style: const TextStyle(
                                fontSize: 10,
                                color: DdColors.textTertiary,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        preview,
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
                const SizedBox(width: 5),
                Icon(
                  Icons.push_pin_rounded,
                  key: const Key('saved-messages-pin'),
                  size: 14,
                  color: DdColors.textTertiary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _archiveEntry(int count, {required bool desktop}) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: InkWell(
        key: const Key('archived-conversations-entry'),
        onTap: () => setState(() {
          _showArchived = true;
          _selectedConversationId = null;
        }),
        child: SizedBox(
          height: desktop ? 40 : 44,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: desktop ? 12 : 14),
            child: Row(
              children: [
                SizedBox(
                  width: desktop ? 30 : 34,
                  child: Icon(
                    Icons.archive_outlined,
                    size: desktop ? 19 : 21,
                    color: DdColors.textSecondary,
                  ),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '已归档',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                ),
                Text(
                  '$count',
                  style: const TextStyle(
                    fontSize: 11,
                    color: DdColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<ConversationItem> _filteredConversations() {
    return _coordinator.conversations
        .where((conversation) {
          if (conversation.type == 'SELF') return false;
          if (conversation.preferences.isArchived != _showArchived) {
            return false;
          }
          if (_query.isEmpty) return true;
          final peer = conversation.peer;
          final group = conversation.group;
          final last = conversation.lastMessage?.content?.text ?? '';
          return (peer?.effectiveDisplayName.toLowerCase().contains(_query) ?? false) ||
              (peer?.handle.toLowerCase().contains(_query) ?? false) ||
              (group?.name.toLowerCase().contains(_query) ?? false) ||
              last.toLowerCase().contains(_query);
        })
        .toList(growable: false);
  }

  Widget _conversationTile(
    ConversationItem conversation, {
    required bool desktop,
  }) {
    final peer = conversation.peer;
    final title = _conversationTitle(conversation);
    final draft = _coordinator.draftFor(conversation.id);
    final pendingCount = _coordinator.pendingFor(conversation.id).length;
    final muted = _isMuted(conversation);
    final selected = desktop && _selectedConversationId == conversation.id;
    final pinned = conversation.preferences.isPinned;
    final brightness = Theme.of(context).brightness;
    final background = selected
        ? DdDesktopTokens.selectedSurface(brightness)
        : pinned
        ? DdDesktopTokens.hoverSurface(brightness)
        : desktop
        ? DdDesktopTokens.sidebarSurface(brightness)
        : Theme.of(context).colorScheme.surface;

    final tile = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () => _showConversationActions(conversation),
      onSecondaryTapDown: (details) =>
          _showConversationMenuAt(conversation, details.globalPosition),
      child: Material(
        color: background,
        child: InkWell(
          key: Key('conversation-${conversation.id}'),
          onTap: () => _openConversation(conversation, desktop: desktop),
          hoverColor: desktop ? DdDesktopTokens.hoverSurface(brightness) : null,
          splashColor: desktop ? Colors.transparent : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(11, 8, 10, 8),
            child: Row(
              children: [
                conversation.type == 'GROUP'
                    ? _groupAvatar(conversation, title)
                    : _avatar(peer?.id ?? '', title),
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
                          if (conversation.latestUnreadMentionMessageId
                                  ?.trim()
                                  .isNotEmpty ==
                              true) ...[
                            GestureDetector(
                              key: Key(
                                'conversation-mention-${conversation.id}',
                              ),
                              behavior: HitTestBehavior.opaque,
                              onTap: () => unawaited(
                                _openConversation(
                                  conversation,
                                  desktop: desktop,
                                  initialMessageId:
                                      conversation.latestUnreadMentionMessageId,
                                ),
                              ),
                              child: const Padding(
                                padding: EdgeInsets.only(right: 4),
                                child: Text(
                                  '【有人@你】',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: DdColors.danger,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ],
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
                          if (pinned)
                            Padding(
                              padding: const EdgeInsets.only(left: 5),
                              child: Icon(
                                Icons.push_pin_rounded,
                                key: Key('conversation-pin-${conversation.id}'),
                                size: 14,
                                color: DdColors.textTertiary,
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
    if (desktop) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(6, 1, 6, 1),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(DdRadii.control),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: DdDesktopTokens.listRowHeight,
            ),
            child: tile,
          ),
        ),
      );
    }
    return _ConversationSwipeActions(
      conversationId: conversation.id,
      pinned: conversation.preferences.isPinned,
      muted: muted,
      archived: conversation.preferences.isArchived,
      onPin: () => _applyConversationAction(conversation, 'pin'),
      onRead: () => _applyConversationAction(conversation, 'read'),
      onMute: () =>
          _applyConversationAction(conversation, muted ? 'unmute' : 'mute-8h'),
      onArchive: () => _applyConversationAction(
        conversation,
        conversation.preferences.isArchived ? 'unarchive' : 'archive',
      ),
      onDelete: () => _applyConversationAction(conversation, 'delete'),
      child: tile,
    );
  }

  String _conversationTitle(ConversationItem conversation) {
    if (conversation.type == 'GROUP') {
      return conversation.group?.name ?? '群聊';
    }
    if (conversation.type == 'SELF') return '我的收藏';
    return conversation.peer?.effectiveDisplayName ?? '会话';
  }

  Widget _groupAvatar(ConversationItem conversation, String title) {
    return SizedBox.square(
      dimension: 46,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: GroupAvatar(
              origin: widget.origin,
              accessToken: widget.accessToken,
              groupId: conversation.group?.id ?? conversation.id,
              groupName: title,
              avatarMediaId: conversation.group?.avatarMediaId ?? '',
              avatarRevision: conversation.group?.avatarRevision ?? 0,
              members: conversation.group?.avatarMembers ?? const [],
            ),
          ),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              key: Key('conversation-group-marker-${conversation.id}'),
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).colorScheme.surface,
                  width: 1.5,
                ),
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.group_rounded,
                size: 13,
                color: DdColors.greenPressed,
              ),
            ),
          ),
        ],
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
        decoration: const BoxDecoration(
          color: Color(0xFF6F9FCA),
          shape: BoxShape.circle,
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
        borderRadius: BorderRadius.circular(DdRadii.pill),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 10, height: 1),
      ),
    );
  }

  Widget _desktopEmptyState(BuildContext context) {
    return ColoredBox(
      color: DdDesktopTokens.contentSurface(Theme.of(context).brightness),
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
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Color(0xFF9D2323)),
              ),
            ),
            IconButton(
              key: const Key('conversations-error-retry'),
              tooltip: '重试',
              visualDensity: VisualDensity.compact,
              onPressed: _coordinator.busy
                  ? null
                  : () => unawaited(_coordinator.recover()),
              icon: const Icon(Icons.refresh_rounded, size: 16),
            ),
            IconButton(
              tooltip: '查看完整错误',
              visualDensity: VisualDensity.compact,
              onPressed: _showErrorDetails,
              icon: const Icon(Icons.info_outline_rounded, size: 16),
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

  Future<void> _showErrorDetails() async {
    final message = _coordinator.errorMessage;
    if (message == null || !mounted) return;
    final logPath = ClientLog.path;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('错误详情'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SelectableText(
            logPath == null ? message : '$message\n\n本地日志：$logPath',
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: message));
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            icon: const Icon(Icons.copy_rounded, size: 17),
            label: const Text('复制错误'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _handleNavigationRequest() {
    if (!mounted) return;
    final controller = widget.navigationController;
    final conversationId = controller?.requestedConversationId;
    final serial = controller?.requestSerial ?? 0;
    if (controller == null ||
        conversationId == null ||
        serial <= _handledNavigationSerial) {
      return;
    }
    final conversation = _coordinator.conversationFor(conversationId);
    if (conversation == null) return;
    _handledNavigationSerial = serial;
    _showArchived = false;
    final desktop = MediaQuery.sizeOf(context).width >= 680;
    unawaited(_openConversation(conversation, desktop: desktop));
  }

  Future<void> _openConversation(
    ConversationItem conversation, {
    required bool desktop,
    String? initialMessageId,
  }) async {
    if (desktop) {
      if (_selectedConversationId != conversation.id ||
          _selectedInitialMessageId != initialMessageId) {
        _inspector.close();
        setState(() {
          _selectedConversationId = conversation.id;
          _selectedInitialMessageId = initialMessageId;
        });
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
          onOpenDirectChat: _openDirectChatByUserId,
          hostVisible: true,
          initialMessageId: initialMessageId,
          savedMessagesMode: conversation.type == 'SELF',
        ),
      ),
    );
  }

  Future<void> _openDirectChatByUserId(String userId) async {
    final target = await _coordinator.ensureDirectConversation(userId);
    if (!mounted) return;
    final desktop = MediaQuery.sizeOf(context).width >= 680;
    if (desktop) {
      _showArchived = false;
      if (_selectedConversationId != target.id) {
        _inspector.close();
        setState(() => _selectedConversationId = target.id);
      }
      return;
    }

    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await _openConversation(target, desktop: false);
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
          value: current.preferences.isArchived ? 'unarchive' : 'archive',
          icon: current.preferences.isArchived
              ? Icons.unarchive_outlined
              : Icons.archive_outlined,
          label: current.preferences.isArchived ? '取消归档' : '归档',
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
        const DdActionSheetItem(
          value: 'delete',
          icon: Icons.delete_outline_rounded,
          label: '删除会话',
          destructive: true,
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DdRadii.surface),
      ),
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
          value: current.preferences.isArchived ? 'unarchive' : 'archive',
          icon: current.preferences.isArchived
              ? Icons.unarchive_outlined
              : Icons.archive_outlined,
          label: current.preferences.isArchived ? '取消归档' : '归档',
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
        const PopupMenuDivider(height: 5),
        _conversationMenuItem(
          value: 'delete',
          icon: Icons.delete_outline_rounded,
          label: '删除会话',
          danger: true,
        ),
      ],
    );
    await _applyConversationAction(current, action);
  }

  PopupMenuItem<String> _conversationMenuItem({
    required String value,
    required IconData icon,
    required String label,
    bool danger = false,
  }) {
    final color = danger
        ? DdColors.danger
        : Theme.of(context).colorScheme.onSurface;
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
        case 'archive':
          await _coordinator.setArchived(conversation, true);
        case 'unarchive':
          await _coordinator.setArchived(conversation, false);
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
        case 'delete':
          final confirmed = await _confirmHideConversation(conversation);
          if (!confirmed) return;
          await _coordinator.hideConversation(conversation);
          if (_selectedConversationId == conversation.id && mounted) {
            setState(() => _selectedConversationId = null);
          }
      }
    } catch (_) {
      // Coordinator/API state surfaces the actionable error.
    }
  }

  Future<bool> _confirmHideConversation(ConversationItem conversation) async {
    final peerName = _conversationTitle(conversation);
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('删除会话？'),
            content: Text(
              '“$peerName”会从你的会话列表隐藏，历史消息不会从服务器删除。对方或你再次发送新消息后，会话会重新出现。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: DdColors.danger,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('删除'),
              ),
            ],
          ),
        ) ??
        false;
  }

  bool _isMuted(ConversationItem conversation) =>
      conversation.preferences.mutedUntil?.isAfter(DateTime.now().toUtc()) ==
      true;

  String _preview(ConversationItem conversation) {
    final message = conversation.lastMessage;
    if (message == null) return '还没有消息';
    if (message.isRecalled) return '';
    final content = const {'TEXT', 'SYSTEM'}.contains(message.type)
        ? (message.content?.text ?? '')
        : switch (message.type) {
            'IMAGE' => '[图片]',
            'GIF' => '[GIF]',
            'STICKER' => '[表情]',
            'STICKER_PACK' => '[表情包]',
            'VOICE' => '[语音]',
            'VIDEO' => '[视频]',
            'FILE' => '[文件]',
            _ => '[${message.type}]',
          };
    if (conversation.type != 'GROUP') return content;
    final sender = conversation.lastMessageSender;
    if (sender == null) return content;
    final senderName = sender.id == widget.currentUserId
        ? '我'
        : sender.effectiveDisplayName;
    if (senderName.isEmpty) return content;
    return content.isEmpty ? senderName : '$senderName：$content';
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

class _ConversationSwipeActions extends StatefulWidget {
  const _ConversationSwipeActions({
    required this.conversationId,
    required this.child,
    required this.pinned,
    required this.muted,
    required this.archived,
    required this.onPin,
    required this.onRead,
    required this.onMute,
    required this.onArchive,
    required this.onDelete,
  });

  final String conversationId;
  final Widget child;
  final bool pinned;
  final bool muted;
  final bool archived;
  final Future<void> Function() onPin;
  final Future<void> Function() onRead;
  final Future<void> Function() onMute;
  final Future<void> Function() onArchive;
  final Future<void> Function() onDelete;

  @override
  State<_ConversationSwipeActions> createState() =>
      _ConversationSwipeActionsState();
}

enum _ConversationSwipeState { closed, leadingOpen, trailingOpen }

class _ConversationSwipeActionsState extends State<_ConversationSwipeActions> {
  static const double _actionWidth = 72;
  static const double _rightReveal = _actionWidth * 2;
  static const double _leftReveal = _actionWidth * 3;
  static const double _settleThreshold = 38;
  double _offset = 0;
  bool _dragging = false;
  bool _busy = false;
  _ConversationSwipeState _state = _ConversationSwipeState.closed;
  _ConversationSwipeState _dragOriginState = _ConversationSwipeState.closed;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Stack(
        children: [
          Positioned.fill(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    _action(
                      key: Key(
                        'conversation-swipe-pin-${widget.conversationId}',
                      ),
                      color: const Color(0xFFFFA940),
                      icon: widget.pinned
                          ? Icons.push_pin_outlined
                          : Icons.push_pin_rounded,
                      label: widget.pinned ? '取消置顶' : '置顶',
                      onTap: widget.onPin,
                    ),
                    _action(
                      key: Key(
                        'conversation-swipe-read-${widget.conversationId}',
                      ),
                      color: const Color(0xFF4E9BEA),
                      icon: Icons.mark_chat_read_rounded,
                      label: '已读',
                      onTap: widget.onRead,
                    ),
                  ],
                ),
                Row(
                  children: [
                    _action(
                      key: Key(
                        'conversation-swipe-mute-${widget.conversationId}',
                      ),
                      color: const Color(0xFF8A8A8A),
                      icon: widget.muted
                          ? Icons.notifications_active_rounded
                          : Icons.notifications_off_rounded,
                      label: widget.muted ? '取消静音' : '静音',
                      onTap: widget.onMute,
                    ),
                    _action(
                      key: Key(
                        'conversation-swipe-archive-${widget.conversationId}',
                      ),
                      color: const Color(0xFF5B8FF9),
                      icon: widget.archived
                          ? Icons.unarchive_rounded
                          : Icons.archive_rounded,
                      label: widget.archived ? '取消归档' : '归档',
                      onTap: widget.onArchive,
                    ),
                    _action(
                      key: Key(
                        'conversation-swipe-delete-${widget.conversationId}',
                      ),
                      color: DdColors.danger,
                      icon: Icons.delete_outline_rounded,
                      label: '删除',
                      onTap: widget.onDelete,
                    ),
                  ],
                ),
              ],
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: (_) {
              if (_busy) return;
              setState(() {
                _dragging = true;
                _dragOriginState = _state;
              });
            },
            onHorizontalDragUpdate: (details) {
              if (_busy) return;
              var minOffset = -_leftReveal;
              var maxOffset = _rightReveal;
              switch (_dragOriginState) {
                case _ConversationSwipeState.closed:
                  break;
                case _ConversationSwipeState.leadingOpen:
                  minOffset = 0;
                  break;
                case _ConversationSwipeState.trailingOpen:
                  maxOffset = 0;
                  break;
              }
              setState(() {
                _offset = (_offset + details.delta.dx).clamp(
                  minOffset,
                  maxOffset,
                );
              });
            },
            onHorizontalDragEnd: (details) {
              if (_busy) return;
              final targetState = _settledStateFor(
                details.primaryVelocity ?? 0,
              );
              setState(() {
                _dragging = false;
                _state = targetState;
                _offset = _offsetForState(targetState);
              });
            },
            onHorizontalDragCancel: () {
              if (!mounted) return;
              setState(() {
                _dragging = false;
                final targetState = _busy ? _state : _dragOriginState;
                _state = targetState;
                _offset = _offsetForState(targetState);
              });
            },
            child: AnimatedContainer(
              duration: _dragging
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              transform: Matrix4.translationValues(_offset, 0, 0),
              child: widget.child,
            ),
          ),
        ],
      ),
    );
  }

  double _offsetForState(_ConversationSwipeState state) => switch (state) {
    _ConversationSwipeState.closed => 0,
    _ConversationSwipeState.leadingOpen => _rightReveal,
    _ConversationSwipeState.trailingOpen => -_leftReveal,
  };

  _ConversationSwipeState _settledStateFor(double velocity) {
    switch (_dragOriginState) {
      case _ConversationSwipeState.closed:
        if (velocity > 450 || _offset > _settleThreshold) {
          return _ConversationSwipeState.leadingOpen;
        }
        if (velocity < -450 || _offset < -_settleThreshold) {
          return _ConversationSwipeState.trailingOpen;
        }
        return _ConversationSwipeState.closed;
      case _ConversationSwipeState.leadingOpen:
        if (velocity < -450 || _offset <= _rightReveal - _settleThreshold) {
          return _ConversationSwipeState.closed;
        }
        return _ConversationSwipeState.leadingOpen;
      case _ConversationSwipeState.trailingOpen:
        if (velocity > 450 || _offset >= -_leftReveal + _settleThreshold) {
          return _ConversationSwipeState.closed;
        }
        return _ConversationSwipeState.trailingOpen;
    }
  }

  Widget _action({
    required Key key,
    required Color color,
    required IconData icon,
    required String label,
    required Future<void> Function() onTap,
  }) {
    return SizedBox(
      key: key,
      width: _actionWidth,
      child: Material(
        color: color,
        child: InkWell(
          onTap: _busy
              ? null
              : () async {
                  setState(() {
                    _busy = true;
                    _dragging = false;
                    _offset = _offsetForState(_state);
                  });
                  try {
                    await onTap();
                  } finally {
                    if (mounted) {
                      setState(() {
                        _busy = false;
                        _state = _ConversationSwipeState.closed;
                        _dragOriginState = _ConversationSwipeState.closed;
                        _offset = 0;
                      });
                    }
                  }
                },
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: Colors.white, size: 22),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                style: const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CreateMenuRow extends StatelessWidget {
  const _CreateMenuRow({
    required this.icon,
    required this.label,
    this.lightOnDark = false,
  });

  final IconData icon;
  final String label;
  final bool lightOnDark;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          Icon(icon, size: 18, color: lightOnDark ? Colors.white : null),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: lightOnDark ? Colors.white : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
