import 'dart:async';

import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
import '../../contacts/data/contacts_api_client.dart';
import '../../contacts/domain/contact_models.dart';
import '../application/messaging_coordinator.dart';
import '../domain/messaging_models.dart';

class MessagingSearchPage extends StatefulWidget {
  const MessagingSearchPage({
    super.key,
    required this.coordinator,
    required this.onOpenConversation,
  });

  final MessagingCoordinator coordinator;
  final Future<void> Function(ConversationItem conversation, String? messageId)
  onOpenConversation;

  @override
  State<MessagingSearchPage> createState() => _MessagingSearchPageState();
}

class _MessagingSearchPageState extends State<MessagingSearchPage> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  late final ContactsApiClient _contactsApi;
  Timer? _searchDebounce;
  String _query = '';
  bool _searching = false;
  ContactSearchResult? _userResult;
  List<MessageSearchHit> _serverHits = const [];

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _focusNode = FocusNode(debugLabel: 'messaging-global-search');
    _contactsApi = ContactsApiClient();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _contactsApi.close();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query;
    final conversations = query.isEmpty
        ? const <ConversationItem>[]
        : widget.coordinator.conversations
              .where((conversation) {
                final peer = conversation.peer;
                return (peer?.displayName.toLowerCase().contains(query) ??
                        false) ||
                    (peer?.handle.toLowerCase().contains(query) ?? false);
              })
              .toList(growable: false);
    final messages = query.isEmpty ? const <_MessageHit>[] : _messageHits();

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(right: 12),
          child: SizedBox(
            height: 36,
            child: TextField(
              key: const Key('messaging-global-search-field'),
              controller: _controller,
              focusNode: _focusNode,
              onChanged: _onQueryChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '搜索联系人和聊天记录',
                prefixIcon: const Icon(Icons.search_rounded, size: 18),
                prefixIconConstraints: const BoxConstraints(minWidth: 36),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除',
                        onPressed: () {
                          _controller.clear();
                          _searchDebounce?.cancel();
                          setState(() {
                            _query = '';
                            _serverHits = const [];
                            _userResult = null;
                            _searching = false;
                          });
                        },
                        icon: const Icon(Icons.cancel_rounded, size: 17),
                      ),
                filled: true,
                fillColor: Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xFF2B2B2B)
                    : const Color(0xFFEDEDED),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(DdRadii.pill),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(DdRadii.pill),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(DdRadii.pill),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 7),
              ),
            ),
          ),
        ),
      ),
      body: query.isEmpty
          ? const _SearchHint()
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                if (_userResult case final result?
                    when result.relationship != 'SELF') ...[
                  const _SectionLabel('DDID'),
                  _userResultTile(result),
                ],
                if (conversations.isNotEmpty) ...[
                  const _SectionLabel('联系人 / 会话'),
                  for (final conversation in conversations)
                    _conversationResult(conversation),
                ],
                if (_searching)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                if (messages.isNotEmpty) ...[
                  const _SectionLabel('聊天记录'),
                  for (final hit in messages) _messageResult(hit),
                ],
                if (!_searching &&
                    _userResult == null &&
                    conversations.isEmpty &&
                    messages.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 90),
                    child: Center(
                      child: Text(
                        '没有匹配结果',
                        style: TextStyle(color: DdColors.textSecondary),
                      ),
                    ),
                  ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 18, 16, 0),
                  child: Text(
                    '聊天记录搜索由服务端覆盖全部当前可见会话；点击结果会定位到原消息。',
                    style: TextStyle(
                      fontSize: 11,
                      color: DdColors.textTertiary,
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  void _onQueryChanged(String value) {
    final query = value.trim().toLowerCase();
    _searchDebounce?.cancel();
    setState(() {
      _query = query;
      if (query.isEmpty) {
        _serverHits = const [];
        _userResult = null;
        _searching = false;
      } else {
        _searching = true;
      }
    });
    if (query.isEmpty) return;
    _searchDebounce = Timer(const Duration(milliseconds: 280), () {
      unawaited(_searchServer(query));
    });
  }

  Future<void> _searchServer(String query) async {
    List<MessageSearchHit> hits = const [];
    ContactSearchResult? userResult;
    try {
      hits = await widget.coordinator.searchMessages(query);
      for (final hit in hits) {
        if (!mounted || _query != query) return;
        await widget.coordinator.resolveConversation(
          hit.message.conversationId,
        );
      }
    } catch (_) {
      hits = const [];
    }
    final ddid = query.startsWith('@') ? query.substring(1) : query;
    if (ddid.length >= 2 && !ddid.contains(' ')) {
      try {
        userResult = await _contactsApi.searchByHandle(
          origin: widget.coordinator.origin,
          accessToken: widget.coordinator.accessToken,
          handle: ddid,
        );
      } catch (_) {
        userResult = null;
      }
    }
    if (!mounted || _query != query) return;
    setState(() {
      _serverHits = hits;
      _userResult = userResult;
      _searching = false;
    });
  }

  List<_MessageHit> _messageHits() {
    final hits = <_MessageHit>[];
    for (final hit in _serverHits) {
      final conversation = widget.coordinator.conversationFor(
        hit.message.conversationId,
      );
      if (conversation == null) continue;
      hits.add(_MessageHit(conversation: conversation, message: hit.message));
    }
    return hits;
  }

  Widget _userResultTile(ContactSearchResult result) {
    final user = result.user;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: ListTile(
        key: Key('search-ddid-${user.id}'),
        leading: const CircleAvatar(
          radius: 20,
          backgroundColor: Color(0xFF6F9FCA),
          child: Icon(Icons.person_rounded, color: Colors.white, size: 21),
        ),
        title: Text(user.displayName),
        subtitle: Text(switch (result.relationship) {
          'BLOCKED_BY_PEER' => 'DDID：${user.handle} · 对方已将你拉黑',
          'BLOCKED_BY_ME' => 'DDID：${user.handle} · 你已将对方拉黑',
          _ => 'DDID：${user.handle}',
        }),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () async {
          FocusScope.of(context).unfocus();
          if (result.relationship == 'BLOCKED_BY_PEER' ||
              result.relationship == 'BLOCKED_BY_ME') {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  result.relationship == 'BLOCKED_BY_PEER'
                      ? '对方已将你拉黑，无法继续发送消息。'
                      : '你已将对方拉黑，解除拉黑后才能继续聊天。',
                ),
              ),
            );
            return;
          }
          try {
            final conversation = await widget.coordinator
                .ensureDirectConversation(user.id);
            if (!mounted) return;
            await widget.onOpenConversation(conversation, null);
          } catch (error) {
            if (!mounted) return;
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('暂时无法打开会话：$error')));
          }
        },
      ),
    );
  }

  Widget _conversationResult(ConversationItem conversation) {
    final peer = conversation.peer;
    final name = peer?.displayName ?? '会话';
    final ddid = peer?.handle ?? '';
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: ListTile(
        key: Key('search-conversation-${conversation.id}'),
        leading: const CircleAvatar(
          radius: 20,
          backgroundColor: Color(0xFF6F9FCA),
          child: Icon(Icons.person_rounded, color: Colors.white, size: 21),
        ),
        title: Text(name),
        subtitle: ddid.isEmpty ? null : Text('DDID：$ddid'),
        onTap: () async {
          FocusScope.of(context).unfocus();
          await widget.onOpenConversation(conversation, null);
        },
      ),
    );
  }

  Widget _messageResult(_MessageHit hit) {
    final peer = hit.conversation.peer;
    final text = hit.message.content?.text ?? '';
    final senderName =
        hit.message.senderUserId == widget.coordinator.currentUserId
        ? '我'
        : (peer?.displayName ?? '对方');
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: ListTile(
        key: Key('search-message-${hit.message.id}'),
        leading: const Icon(Icons.chat_bubble_outline_rounded, size: 22),
        title: Text(peer?.displayName ?? '聊天记录'),
        subtitle: Text(
          '$senderName：$text',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Text(
          _shortDate(hit.message.createdAt.toLocal()),
          style: const TextStyle(fontSize: 10, color: DdColors.textTertiary),
        ),
        onTap: () async {
          FocusScope.of(context).unfocus();
          await widget.onOpenConversation(hit.conversation, hit.message.id);
        },
      ),
    );
  }

  String _shortDate(DateTime value) =>
      '${value.month}/${value.day} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
}

class _MessageHit {
  const _MessageHit({required this.conversation, required this.message});

  final ConversationItem conversation;
  final ChatMessage message;
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    height: 34,
    alignment: Alignment.centerLeft,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    color: Theme.of(context).scaffoldBackgroundColor,
    child: Text(
      text,
      style: const TextStyle(fontSize: 12, color: DdColors.textSecondary),
    ),
  );
}

class _SearchHint extends StatelessWidget {
  const _SearchHint();

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: const [
        SizedBox(height: 20),
        _SectionLabel('搜索指定内容'),
        ListTile(
          leading: Icon(
            Icons.person_search_outlined,
            color: DdColors.greenPressed,
          ),
          title: Text('联系人 / DDID'),
        ),
        ListTile(
          leading: Icon(Icons.chat_outlined, color: DdColors.greenPressed),
          title: Text('聊天记录'),
        ),
        Divider(height: 1),
        Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            '输入关键词后再显示候选，不在消息首页直接抢输入焦点。',
            style: TextStyle(fontSize: 12, color: DdColors.textTertiary),
          ),
        ),
      ],
    );
  }
}
