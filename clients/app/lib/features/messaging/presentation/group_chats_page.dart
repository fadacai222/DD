import 'dart:async';

import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
import '../domain/messaging_models.dart';
import 'widgets/group_avatar.dart';

class GroupChatsPage extends StatefulWidget {
  const GroupChatsPage({
    super.key,
    required this.origin,
    required this.accessToken,
    required this.conversations,
    required this.onOpenConversation,
  });

  final Uri origin;
  final String accessToken;
  final List<ConversationItem> conversations;
  final Future<void> Function(ConversationItem conversation) onOpenConversation;

  @override
  State<GroupChatsPage> createState() => _GroupChatsPageState();
}

class _GroupChatsPageState extends State<GroupChatsPage> {
  late final TextEditingController _searchController;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final groups = widget.conversations.where((conversation) {
      if (conversation.type != 'GROUP' || conversation.group == null) {
        return false;
      }
      if (_query.isEmpty) return true;
      return conversation.group!.name.toLowerCase().contains(_query);
    }).toList(growable: false)
      ..sort(
        (left, right) =>
            left.group!.name.toLowerCase().compareTo(right.group!.name.toLowerCase()),
      );

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '群聊',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Material(
              color: Theme.of(context).colorScheme.surface,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                child: SizedBox(
                  height: 36,
                  child: TextField(
                    key: const Key('group-chats-search'),
                    controller: _searchController,
                    textAlign: TextAlign.center,
                    onChanged: (value) => setState(
                      () => _query = value.trim().toLowerCase(),
                    ),
                    decoration: const InputDecoration(
                      hintText: '搜索群聊',
                      prefixIcon: Icon(
                        Icons.search_rounded,
                        size: 18,
                        color: DdColors.textSecondary,
                      ),
                      prefixIconConstraints: BoxConstraints(minWidth: 36),
                      contentPadding: EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: groups.isEmpty
                  ? const Center(
                      child: Text(
                        '暂无群聊',
                        style: TextStyle(color: DdColors.textTertiary),
                      ),
                    )
                  : ListView.separated(
                      itemCount: groups.length,
                      separatorBuilder: (_, _) => const Divider(
                        height: 1,
                        indent: 66,
                        thickness: 0.5,
                      ),
                      itemBuilder: (context, index) {
                        final conversation = groups[index];
                        final group = conversation.group!;
                        return Material(
                          color: Theme.of(context).colorScheme.surface,
                          child: InkWell(
                            key: Key('group-chat-${conversation.id}'),
                            onTap: () => unawaited(
                              widget.onOpenConversation(conversation),
                            ),
                            child: SizedBox(
                              height: 62,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                child: Row(
                                  children: [
                                    GroupAvatar(
                                      origin: widget.origin,
                                      accessToken: widget.accessToken,
                                      groupId: group.id,
                                      groupName: group.name,
                                      avatarMediaId: group.avatarMediaId,
                                      avatarRevision: group.avatarRevision,
                                      members: group.avatarMembers,
                                      size: 40,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            group.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(fontSize: 16),
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            '${group.memberCount} 位成员',
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
                                      size: 20,
                                      color: DdColors.textTertiary,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
