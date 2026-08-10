import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/messaging/domain/messaging_models.dart';
import 'package:im_client/features/messaging/presentation/group_chats_page.dart';

void main() {
  testWidgets('group directory filters group conversations and opens selected chat', (
    tester,
  ) async {
    String? openedConversationId;
    await tester.pumpWidget(
      MaterialApp(
        home: GroupChatsPage(
          origin: Uri.parse('http://127.0.0.1:18473'),
          accessToken: 'token',
          conversations: [
            _groupConversation('group-a', '研发群', 8),
            _groupConversation('group-b', '夜班群', 5),
            _directConversation(),
          ],
          onOpenConversation: (conversation) async {
            openedConversationId = conversation.id;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('研发群'), findsOneWidget);
    expect(find.text('夜班群'), findsOneWidget);
    expect(find.text('Bob'), findsNothing);

    await tester.enterText(find.byKey(const Key('group-chats-search')), '夜班');
    await tester.pumpAndSettle();
    expect(find.text('研发群'), findsNothing);
    expect(find.text('夜班群'), findsOneWidget);

    await tester.tap(find.text('夜班群'));
    await tester.pumpAndSettle();
    expect(openedConversationId, 'group-b');
  });
}

ConversationItem _groupConversation(String id, String name, int memberCount) =>
    ConversationItem(
      id: id,
      type: 'GROUP',
      group: MessagingGroupPreview(
        id: id,
        name: name,
        memberCount: memberCount,
      ),
      lastSequence: 0,
      lastReadSequence: 0,
      unreadCount: 0,
      preferences: const ConversationPreferences(isPinned: false),
      createdAt: DateTime.utc(2026, 8, 11),
      updatedAt: DateTime.utc(2026, 8, 11),
    );

ConversationItem _directConversation() => ConversationItem(
  id: 'direct-a',
  type: 'DIRECT',
  peer: const MessagingUserPreview(
    id: 'user-b',
    handle: 'bob_01',
    displayName: 'Bob',
  ),
  lastSequence: 0,
  lastReadSequence: 0,
  unreadCount: 0,
  preferences: const ConversationPreferences(isPinned: false),
  createdAt: DateTime.utc(2026, 8, 11),
  updatedAt: DateTime.utc(2026, 8, 11),
);
