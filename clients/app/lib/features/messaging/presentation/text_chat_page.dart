import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../theme/app_theme.dart';
import '../../auth/presentation/widgets/profile_avatar.dart';
import '../../calls/domain/call_session.dart';
import '../application/messaging_coordinator.dart';
import '../domain/messaging_models.dart';

class TextChatPage extends StatefulWidget {
  const TextChatPage({
    super.key,
    required this.coordinator,
    required this.conversation,
    required this.currentUserId,
    this.currentUserDisplayName = '',
    this.currentUserAvatarRevision = 0,
    this.onStartCall,
    this.embedded = false,
  });

  final MessagingCoordinator coordinator;
  final ConversationItem conversation;
  final String currentUserId;
  final String currentUserDisplayName;
  final int currentUserAvatarRevision;
  final Future<void> Function(String peerId, String peerName, CallKind kind)?
  onStartCall;
  final bool embedded;

  @override
  State<TextChatPage> createState() => _TextChatPageState();
}

class _TextChatPageState extends State<TextChatPage> {
  static const _emoji = <String>[
    '😀',
    '😃',
    '😄',
    '😁',
    '😆',
    '🥹',
    '😂',
    '🙂',
    '🙃',
    '😉',
    '😊',
    '🥰',
    '😍',
    '😘',
    '😋',
    '😎',
    '🤔',
    '🫡',
    '😴',
    '😭',
    '😤',
    '😡',
    '🤯',
    '🥳',
    '👍',
    '👎',
    '👌',
    '✌️',
    '🤝',
    '👏',
    '🙏',
    '💪',
    '❤️',
    '💔',
    '🔥',
    '✨',
    '🎉',
    '💯',
    '👀',
    '🚀',
  ];

  late final TextEditingController _composer;
  late final FocusNode _composerFocusNode;
  late final ScrollController _scrollController;
  Timer? _draftSaveTimer;
  ChatMessage? _replyingTo;

  bool get _keyboardSendEnabled =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;

  @override
  void initState() {
    super.initState();
    _composer = TextEditingController(
      text: widget.coordinator.draftFor(widget.conversation.id),
    );
    _composer.addListener(_scheduleDraftSave);
    _composerFocusNode = FocusNode(debugLabel: 'chat-composer');
    _scrollController = ScrollController();
    widget.coordinator.activateConversation(widget.conversation.id);
    unawaited(_load());
  }

  @override
  void dispose() {
    _draftSaveTimer?.cancel();
    unawaited(
      widget.coordinator.setDraft(widget.conversation.id, _composer.text),
    );
    widget.coordinator.deactivateConversation(widget.conversation.id);
    _composer.removeListener(_scheduleDraftSave);
    _composerFocusNode.dispose();
    _composer.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.coordinator,
      builder: (context, _) {
        final conversation =
            widget.coordinator.conversationFor(widget.conversation.id) ??
            widget.conversation;
        final messages = widget.coordinator.messagesFor(conversation.id);
        final pending = widget.coordinator.pendingFor(conversation.id);
        final body = ColoredBox(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF1D1D1D)
              : DdColors.chatBackground,
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                if (widget.embedded) _desktopHeader(conversation),
                if (widget.coordinator.errorMessage != null)
                  _errorBar(widget.coordinator.errorMessage!),
                Expanded(
                  child: messages.isEmpty && pending.isEmpty
                      ? _emptyState(conversation)
                      : _messageList(conversation, messages, pending),
                ),
                _composerBar(),
              ],
            ),
          ),
        );

        if (widget.embedded) return body;
        return Scaffold(
          backgroundColor: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF1D1D1D)
              : DdColors.chatBackground,
          appBar: AppBar(
            titleSpacing: 0,
            title: _chatTitle(conversation),
            actions: [
              IconButton(
                key: const Key('chat-audio-call-mobile'),
                tooltip: '语音通话',
                onPressed: () => _startCall(CallKind.audio),
                icon: const Icon(Icons.call_outlined, size: 21),
              ),
              IconButton(
                key: const Key('chat-video-call-mobile'),
                tooltip: '视频通话',
                onPressed: () => _startCall(CallKind.video),
                icon: const Icon(Icons.videocam_outlined, size: 23),
              ),
              IconButton(
                key: const Key('chat-sync'),
                tooltip: '更多',
                onPressed: _sync,
                icon: const Icon(Icons.more_horiz_rounded),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: body,
        );
      },
    );
  }

  Widget _desktopHeader(ConversationItem conversation) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: const Border(
          bottom: BorderSide(color: DdColors.divider, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          Expanded(child: _chatTitle(conversation)),
          IconButton(
            key: const Key('chat-audio-call'),
            tooltip: '语音通话',
            onPressed: () => _startCall(CallKind.audio),
            icon: const Icon(Icons.call_outlined, size: 20),
          ),
          IconButton(
            key: const Key('chat-video-call'),
            tooltip: '视频通话',
            onPressed: () => _startCall(CallKind.video),
            icon: const Icon(Icons.videocam_outlined, size: 22),
          ),
          IconButton(
            key: const Key('chat-sync'),
            tooltip: '更多',
            onPressed: _sync,
            icon: const Icon(Icons.more_horiz_rounded),
          ),
        ],
      ),
    );
  }

  Widget _chatTitle(ConversationItem conversation) {
    final peer = conversation.peer;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          peer?.displayName ?? '聊天',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        if (peer != null)
          Text(
            '@${peer.handle}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              color: DdColors.textSecondary,
              fontWeight: FontWeight.w400,
            ),
          ),
      ],
    );
  }

  Widget _emptyState(ConversationItem conversation) {
    final name = conversation.peer?.displayName ?? '对方';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _avatar(conversation.peer?.id ?? '', name, size: 58),
            const SizedBox(height: 14),
            Text(
              '和 $name 开始聊天',
              style: const TextStyle(
                fontSize: 15,
                color: DdColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorBar(String message) {
    return Material(
      color: const Color(0xFFFFE8E8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 7, 6, 7),
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
                message,
                style: const TextStyle(fontSize: 12, color: Color(0xFF9D2323)),
              ),
            ),
            IconButton(
              tooltip: '关闭',
              visualDensity: VisualDensity.compact,
              onPressed: widget.coordinator.clearError,
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  Widget _messageList(
    ConversationItem conversation,
    List<ChatMessage> messages,
    List<PendingTextMessage> pending,
  ) {
    final hasOlder = widget.coordinator.canLoadOlder(conversation.id);
    final offset = hasOlder ? 1 : 0;
    final count = offset + messages.length + pending.length;
    return ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.fromLTRB(
        widget.embedded ? 24 : 12,
        18,
        widget.embedded ? 24 : 12,
        18,
      ),
      itemCount: count,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemBuilder: (_, index) {
        if (hasOlder && index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Center(
              child: TextButton(
                key: const Key('chat-load-older'),
                onPressed: _loadOlder,
                child: const Text('查看更多消息'),
              ),
            ),
          );
        }
        final contentIndex = index - offset;
        if (contentIndex < messages.length) {
          return RepaintBoundary(
            child: _messageRow(conversation, messages[contentIndex]),
          );
        }
        return RepaintBoundary(
          child: _pendingRow(pending[contentIndex - messages.length]),
        );
      },
    );
  }

  Widget _messageRow(ConversationItem conversation, ChatMessage message) {
    final mine = message.senderUserId == widget.currentUserId;
    final peerName = conversation.peer?.displayName ?? '对方';
    final bubble = _messageBubble(conversation, message, mine);
    final row = Padding(
      key: Key('message-${message.id}'),
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        mainAxisAlignment: mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!mine) ...[
            _avatar(conversation.peer?.id ?? '', peerName),
            const SizedBox(width: 9),
          ],
          Flexible(child: bubble),
          if (mine) ...[
            const SizedBox(width: 9),
            _avatar(
              widget.currentUserId,
              widget.currentUserDisplayName.isEmpty
                  ? '我'
                  : widget.currentUserDisplayName,
              mine: true,
            ),
          ],
        ],
      ),
    );

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPress: () => _showMessageActions(message, mine),
      onSecondaryTapDown: (details) =>
          _showMessageMenuAt(message, mine, details.globalPosition),
      child: row,
    );
  }

  Widget _messageBubble(
    ConversationItem conversation,
    ChatMessage message,
    bool mine,
  ) {
    final recalled = message.isRecalled;
    final maxWidth = widget.embedded ? 520.0 : 290.0;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Container(
            padding: recalled
                ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4)
                : const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            decoration: recalled
                ? null
                : BoxDecoration(
                    color: mine
                        ? DdColors.ownBubble
                        : Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(5),
                  ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (message.replyToMessageId != null && !recalled) ...[
                  _replyReference(message.replyToMessageId!, mine),
                  const SizedBox(height: 6),
                ],
                Text(
                  recalled
                      ? '你${mine ? '' : '的好友'}撤回了一条消息'
                      : (message.content?.text ?? '[${message.type}]'),
                  style: TextStyle(
                    fontSize: recalled ? 12 : 15,
                    height: 1.38,
                    fontStyle: recalled ? FontStyle.italic : FontStyle.normal,
                    color: recalled
                        ? DdColors.textSecondary
                        : (Theme.of(context).brightness == Brightness.dark
                              ? Colors.white
                              : DdColors.textPrimary),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 3),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _shortTime(message.createdAt.toLocal()),
                style: const TextStyle(
                  fontSize: 10,
                  color: DdColors.textTertiary,
                ),
              ),
              if (mine && !recalled) ...[
                const SizedBox(width: 5),
                Text(
                  _messageDeliveryLabel(conversation, message),
                  key: Key('message-status-${message.id}'),
                  style: TextStyle(
                    fontSize: 10,
                    color: _messageDeliveryLabel(conversation, message) == '已读'
                        ? DdColors.greenPressed
                        : DdColors.textTertiary,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  String _messageDeliveryLabel(
    ConversationItem conversation,
    ChatMessage message,
  ) {
    final peerRead = conversation.peerLastReadSequence;
    if (peerRead != null && peerRead >= message.sequence) return '已读';
    return '已发送';
  }

  Widget _pendingRow(PendingTextMessage item) {
    final failed = item.lastError != null;
    final row = Padding(
      key: Key('pending-${item.clientMessageId}'),
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: widget.embedded ? 520 : 290,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: failed
                          ? const Color(0xFFFFDCDC)
                          : DdColors.ownBubble,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      item.text,
                      style: const TextStyle(
                        fontSize: 15,
                        height: 1.38,
                        color: DdColors.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (failed)
                        const Icon(
                          Icons.error_rounded,
                          size: 12,
                          color: DdColors.danger,
                        ),
                      if (failed) const SizedBox(width: 3),
                      Text(
                        failed ? '发送失败' : '发送中…',
                        style: TextStyle(
                          fontSize: 10,
                          color: failed
                              ? DdColors.danger
                              : DdColors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 9),
          _avatar(
            widget.currentUserId,
            widget.currentUserDisplayName.isEmpty
                ? '我'
                : widget.currentUserDisplayName,
            mine: true,
          ),
        ],
      ),
    );
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPress: () => _showPendingActions(item),
      onSecondaryTapDown: (details) =>
          _showPendingMenuAt(item, details.globalPosition),
      child: row,
    );
  }

  Widget _avatar(
    String userId,
    String name, {
    double size = 38,
    bool mine = false,
  }) {
    if (userId.isEmpty) {
      final letter = name.trim().isEmpty ? '?' : name.trim().characters.first;
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: mine ? const Color(0xFF6EBB5A) : const Color(0xFF6F9FCA),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(
          letter,
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.42,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    return ProfileAvatar(
      origin: widget.coordinator.origin,
      accessToken: widget.coordinator.accessToken,
      userId: userId,
      displayName: name,
      size: size,
      revision: mine ? widget.currentUserAvatarRevision : 0,
      fallbackColor: mine ? const Color(0xFF6EBB5A) : const Color(0xFF6F9FCA),
    );
  }

  Widget _composerBar() {
    final replyingTo = _replyingTo;
    final surface = Theme.of(context).colorScheme.surface;
    return Material(
      color: surface,
      child: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: DdColors.divider, width: 0.5)),
        ),
        padding: EdgeInsets.fromLTRB(
          widget.embedded ? 14 : 8,
          8,
          widget.embedded ? 14 : 8,
          10,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (replyingTo != null) _replyPreview(replyingTo),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  key: const Key('chat-voice'),
                  tooltip: '语音条（媒体阶段接入）',
                  onPressed: null,
                  icon: const Icon(Icons.mic_none_rounded, size: 25),
                ),
                Expanded(child: _composerField()),
                IconButton(
                  key: const Key('chat-emoji'),
                  tooltip: 'Emoji',
                  onPressed: _showEmojiPicker,
                  icon: const Icon(
                    Icons.sentiment_satisfied_alt_rounded,
                    size: 25,
                  ),
                ),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _composer,
                  builder: (context, value, _) {
                    final hasText = value.text.trim().isNotEmpty;
                    if (hasText) {
                      return Padding(
                        padding: const EdgeInsets.only(left: 2, bottom: 3),
                        child: SizedBox(
                          height: 34,
                          child: FilledButton(
                            key: const Key('chat-send'),
                            onPressed: _send,
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                              ),
                              minimumSize: const Size(0, 34),
                            ),
                            child: const Text(
                              '发送',
                              style: TextStyle(fontSize: 13),
                            ),
                          ),
                        ),
                      );
                    }
                    return IconButton(
                      key: const Key('chat-more'),
                      tooltip: '更多',
                      onPressed: _showMoreMenu,
                      icon: const Icon(
                        Icons.add_circle_outline_rounded,
                        size: 26,
                      ),
                    );
                  },
                ),
              ],
            ),
            if (_keyboardSendEnabled)
              const Padding(
                padding: EdgeInsets.only(top: 3, right: 46),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    'Enter 发送 · Shift+Enter 换行',
                    style: TextStyle(fontSize: 9, color: DdColors.textTertiary),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _composerField() {
    final field = TextField(
      key: const Key('chat-composer'),
      controller: _composer,
      focusNode: _composerFocusNode,
      minLines: 1,
      maxLines: 5,
      maxLength: 4000,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      decoration: const InputDecoration(
        hintText: '输入消息',
        counterText: '',
        filled: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      ),
    );
    if (!_keyboardSendEnabled) return field;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.enter): _sendFromKeyboard,
      },
      child: field,
    );
  }

  Widget _replyPreview(ChatMessage message) {
    return Container(
      key: const Key('chat-reply-preview'),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF2C2C2C)
            : const Color(0xFFF1F1F1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Container(width: 2, height: 24, color: DdColors.green),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message.isRecalled
                  ? '回复：该消息已撤回'
                  : '回复：${message.content?.text ?? '[${message.type}]'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                color: DdColors.textSecondary,
              ),
            ),
          ),
          IconButton(
            key: const Key('chat-cancel-reply'),
            tooltip: '取消回复',
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _replyingTo = null),
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        ],
      ),
    );
  }

  Future<void> _load() async {
    try {
      await widget.coordinator.loadMessages(widget.conversation.id);
      _scrollToBottom(immediate: true);
    } catch (_) {
      // Coordinator/API state already carries the actionable error.
    }
  }

  Future<void> _loadOlder() async {
    await widget.coordinator.loadOlder(widget.conversation.id);
  }

  Future<void> _sync() async {
    await widget.coordinator.flushPending();
    await widget.coordinator.syncNow();
    await widget.coordinator.loadMessages(widget.conversation.id);
    _scrollToBottom();
  }

  Future<void> _startCall(CallKind kind) async {
    final conversation =
        widget.coordinator.conversationFor(widget.conversation.id) ??
        widget.conversation;
    final peer = conversation.peer;
    final handler = widget.onStartCall;
    if (peer == null || handler == null) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('当前入口尚未连接通话服务。')));
      }
      return;
    }
    await handler(peer.id, peer.displayName, kind);
  }

  void _sendFromKeyboard() {
    final composing = _composer.value.composing;
    if (composing.isValid && !composing.isCollapsed) return;
    unawaited(_send());
  }

  Future<void> _send() async {
    final text = _composer.text;
    if (text.trim().isEmpty) return;
    final replyToMessageId = _replyingTo?.id;
    if (_replyingTo != null) {
      setState(() => _replyingTo = null);
    }
    _composer.clear();
    // 不要在发送期间 disable TextField。Android IME 在 enabled true/false 切换时
    // 会重建 input connection，既掉帧又会把输入焦点吃掉。
    _composerFocusNode.requestFocus();
    unawaited(
      widget.coordinator.setDraft(widget.conversation.id, '', notify: false),
    );
    await widget.coordinator.sendText(
      widget.conversation.id,
      text,
      replyToMessageId: replyToMessageId,
    );
    if (mounted) {
      _composerFocusNode.requestFocus();
      _scrollToBottom();
    }
  }

  Future<void> _showEmojiPicker() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 520),
      builder: (context) => SafeArea(
        child: SizedBox(
          height: 280,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Text(
                  'Emoji',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(10, 4, 10, 16),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 52,
                    mainAxisExtent: 48,
                  ),
                  itemCount: _emoji.length,
                  itemBuilder: (_, index) => InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: () => Navigator.pop(context, _emoji[index]),
                    child: Center(
                      child: Text(
                        _emoji[index],
                        style: const TextStyle(fontSize: 25),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    _insertAtSelection(selected);
    _composerFocusNode.requestFocus();
  }

  void _insertAtSelection(String text) {
    final value = _composer.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final start = selection.start.clamp(0, value.text.length);
    final end = selection.end.clamp(0, value.text.length);
    final nextText = value.text.replaceRange(start, end, text);
    _composer.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
  }

  Future<void> _showMoreMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 520),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Row(
            children: const [
              _DisabledComposerAction(icon: Icons.image_outlined, label: '图片'),
              SizedBox(width: 14),
              _DisabledComposerAction(
                icon: Icons.gif_box_outlined,
                label: 'GIF',
              ),
              SizedBox(width: 14),
              _DisabledComposerAction(
                icon: Icons.insert_drive_file_outlined,
                label: '文件',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showPendingActions(PendingTextMessage item) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.refresh_rounded),
              title: const Text('立即重试'),
              onTap: () => Navigator.pop(context, 'retry'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('取消发送'),
              onTap: () => Navigator.pop(context, 'cancel'),
            ),
          ],
        ),
      ),
    );
    await _applyPendingAction(item, action);
  }

  Future<void> _showPendingMenuAt(
    PendingTextMessage item,
    Offset globalPosition,
  ) async {
    final action = await _showContextMenu(globalPosition, [
      _contextMenuItem(
        value: 'retry',
        icon: Icons.refresh_rounded,
        label: '立即重试',
      ),
      _contextMenuItem(
        value: 'cancel',
        icon: Icons.close_rounded,
        label: '取消发送',
        destructive: true,
      ),
    ]);
    await _applyPendingAction(item, action);
  }

  Future<void> _applyPendingAction(
    PendingTextMessage item,
    String? action,
  ) async {
    if (action == 'retry') {
      await widget.coordinator.retryPending(item.clientMessageId);
    } else if (action == 'cancel') {
      await widget.coordinator.cancelPending(item.clientMessageId);
    }
  }

  Future<void> _showMessageActions(ChatMessage message, bool mine) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) =>
          SafeArea(child: Wrap(children: _messageActionTiles(message, mine))),
    );
    await _applyMessageAction(message, action);
  }

  Future<void> _showMessageMenuAt(
    ChatMessage message,
    bool mine,
    Offset globalPosition,
  ) async {
    final entries = <PopupMenuEntry<String>>[
      if (!message.isRecalled)
        _contextMenuItem(
          value: 'reply',
          icon: Icons.reply_rounded,
          label: '回复',
        ),
      if (!message.isRecalled && message.content?.text.isNotEmpty == true)
        _contextMenuItem(
          value: 'copy',
          icon: Icons.content_copy_rounded,
          label: '复制文字',
        ),
      if (mine && !message.isRecalled)
        _contextMenuItem(
          value: 'recall',
          icon: Icons.undo_rounded,
          label: '撤回',
        ),
      const PopupMenuDivider(height: 5),
      _contextMenuItem(
        value: 'delete',
        icon: Icons.delete_outline_rounded,
        label: '仅本地删除',
        destructive: true,
      ),
    ];
    final action = await _showContextMenu(globalPosition, entries);
    await _applyMessageAction(message, action);
  }

  List<Widget> _messageActionTiles(ChatMessage message, bool mine) => [
    if (!message.isRecalled)
      ListTile(
        leading: const Icon(Icons.reply_rounded),
        title: const Text('回复'),
        onTap: () => Navigator.pop(context, 'reply'),
      ),
    if (!message.isRecalled && message.content?.text.isNotEmpty == true)
      ListTile(
        leading: const Icon(Icons.copy_rounded),
        title: const Text('复制'),
        onTap: () => Navigator.pop(context, 'copy'),
      ),
    if (mine && !message.isRecalled)
      ListTile(
        leading: const Icon(Icons.undo_rounded),
        title: const Text('撤回'),
        subtitle: const Text('自己的消息默认不限时'),
        onTap: () => Navigator.pop(context, 'recall'),
      ),
    ListTile(
      leading: const Icon(Icons.delete_outline_rounded),
      title: const Text('仅本地删除'),
      onTap: () => Navigator.pop(context, 'delete'),
    ),
  ];

  Future<void> _applyMessageAction(ChatMessage message, String? action) async {
    if (action == 'reply') {
      setState(() => _replyingTo = message);
    } else if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: message.content?.text ?? ''));
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已复制')));
      }
    } else if (action == 'recall') {
      await widget.coordinator.recall(message);
    } else if (action == 'delete') {
      await widget.coordinator.deleteLocally(message);
    }
  }

  PopupMenuItem<String> _contextMenuItem({
    required String value,
    required IconData icon,
    required String label,
    bool destructive = false,
  }) {
    final color = destructive
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

  Future<String?> _showContextMenu(
    Offset globalPosition,
    List<PopupMenuEntry<String>> items,
  ) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    return showMenu<String>(
      context: context,
      color: Theme.of(context).colorScheme.surface,
      elevation: 10,
      shadowColor: Colors.black.withValues(alpha: 0.22),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      menuPadding: const EdgeInsets.symmetric(vertical: 5),
      constraints: const BoxConstraints(minWidth: 180, maxWidth: 224),
      position: RelativeRect.fromRect(
        Rect.fromPoints(globalPosition, globalPosition),
        Offset.zero & overlay.size,
      ),
      items: items,
    );
  }

  Widget _replyReference(String messageId, bool mine) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: mine
            ? Colors.white.withValues(alpha: 0.35)
            : const Color(0xFFF3F3F3),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        _replyLabel(messageId),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11, color: DdColors.textSecondary),
      ),
    );
  }

  String _replyLabel(String messageId) {
    final messages = widget.coordinator.messagesFor(widget.conversation.id);
    for (final message in messages) {
      if (message.id != messageId) continue;
      if (message.isRecalled) return '该消息已撤回';
      final text = message.content?.text;
      if (text != null && text.isNotEmpty) return text;
      return '[${message.type}]';
    }
    return '引用消息';
  }

  void _scheduleDraftSave() {
    _draftSaveTimer?.cancel();
    _draftSaveTimer = Timer(const Duration(milliseconds: 700), () {
      unawaited(
        widget.coordinator.setDraft(
          widget.conversation.id,
          _composer.text,
          notify: false,
        ),
      );
    });
  }

  void _scrollToBottom({bool immediate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      if (immediate) {
        _scrollController.jumpTo(target);
        return;
      }
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
      );
    });
  }

  String _shortTime(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
}

class _DisabledComposerAction extends StatelessWidget {
  const _DisabledComposerAction({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Opacity(
        opacity: 0.42,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Icon(icon, size: 25),
            ),
            const SizedBox(height: 7),
            Text(label, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 2),
            const Text(
              '开发中',
              style: TextStyle(fontSize: 9, color: DdColors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}
