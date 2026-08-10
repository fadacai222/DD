import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/messaging/domain/messaging_models.dart';
import 'package:im_client/features/messaging/presentation/saved_messages_page.dart';
import 'package:im_client/theme/app_theme.dart';

void main() {
  testWidgets(
    'saved messages render as a chat stream instead of a settings list',
    (tester) async {
      tester.view.physicalSize = const Size(390, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final message = ChatMessage(
        id: 'saved-1',
        conversationId: 'conversation-1',
        sequence: 9,
        senderUserId: 'user-b',
        senderDeviceId: 'device-b',
        clientMessageId: 'saved-client-1',
        type: 'TEXT',
        content: const TextMessageContent(text: '这是一条收藏的消息'),
        createdAt: DateTime.utc(2026, 8, 9, 2, 10),
      );
      final item = SavedMessageItem(
        message: message,
        savedAt: DateTime.utc(2026, 8, 9, 2, 15),
      );
      final conversation = ConversationItem(
        id: 'conversation-1',
        type: 'DIRECT',
        peer: const MessagingUserPreview(
          id: 'user-b',
          handle: 'bob',
          displayName: 'Bob',
        ),
        lastSequence: 9,
        lastReadSequence: 9,
        unreadCount: 0,
        preferences: const ConversationPreferences(isPinned: false),
        createdAt: DateTime.utc(2026, 8, 9),
        updatedAt: DateTime.utc(2026, 8, 9, 2, 15),
      );

      ChatMessage? opened;
      ChatMessage? removed;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SavedMessagesConversationView(
              items: [item],
              currentUserId: 'user-a',
              conversationFor: (_) => conversation,
              onOpenMessage: (value) async => opened = value,
              onRemoveMessage: (value) async => removed = value,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('saved-messages-chat-stream')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('saved-bubble-saved-1')), findsOneWidget);
      expect(find.text('来自 Bob'), findsOneWidget);
      expect(find.text('这是一条收藏的消息'), findsOneWidget);
      expect(find.text('从其他聊天收藏或转发到这里'), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);

      await tester.tap(find.byKey(const Key('saved-bubble-saved-1')));
      await tester.pump();
      expect(opened?.id, 'saved-1');

      await tester.longPress(find.byKey(const Key('saved-bubble-saved-1')));
      await tester.pumpAndSettle();
      expect(find.text('查看原消息'), findsOneWidget);
      expect(find.text('取消收藏'), findsOneWidget);
      await tester.tap(find.text('取消收藏'));
      await tester.pumpAndSettle();
      expect(removed?.id, 'saved-1');
    },
  );

  testWidgets(
    'saved media uses compact chat cards instead of bracket placeholders',
    (tester) async {
      final items = <SavedMessageItem>[
        SavedMessageItem(
          message: ChatMessage(
            id: 'file-1',
            conversationId: 'conversation-1',
            sequence: 1,
            senderUserId: 'user-a',
            senderDeviceId: 'device-a',
            clientMessageId: 'file-client-1',
            type: 'FILE',
            content: const TextMessageContent(
              mediaId: 'media-file-1',
              fileName: 'design.pdf',
              mimeType: 'application/pdf',
              sizeBytes: 1048576,
            ),
            createdAt: DateTime.utc(2026, 8, 9, 1),
          ),
          savedAt: DateTime.utc(2026, 8, 9, 1, 1),
        ),
        SavedMessageItem(
          message: ChatMessage(
            id: 'voice-1',
            conversationId: 'conversation-1',
            sequence: 2,
            senderUserId: 'user-b',
            senderDeviceId: 'device-b',
            clientMessageId: 'voice-client-1',
            type: 'VOICE',
            content: const TextMessageContent(
              mediaId: 'media-voice-1',
              durationMs: 8200,
            ),
            createdAt: DateTime.utc(2026, 8, 9, 1, 2),
          ),
          savedAt: DateTime.utc(2026, 8, 9, 1, 3),
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SavedMessagesConversationView(
              items: items,
              currentUserId: 'user-a',
              conversationFor: (_) => null,
              onOpenMessage: (_) async {},
              onRemoveMessage: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('design.pdf'), findsOneWidget);
      expect(find.text('1.0 MiB'), findsOneWidget);
      expect(find.text('9″'), findsOneWidget);
      expect(find.text('[文件] design.pdf'), findsNothing);
      expect(find.text('[语音]'), findsNothing);
    },
  );
}
