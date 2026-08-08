import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/messaging/application/messaging_coordinator.dart';
import 'package:im_client/features/messaging/data/messaging_api_client.dart';
import 'package:im_client/features/messaging/data/messaging_local_store.dart';
import 'package:im_client/features/messaging/domain/messaging_models.dart';
import 'package:im_client/features/messaging/presentation/conversations_page.dart';
import 'package:im_client/theme/app_theme.dart';
import 'package:realtime_poc/realtime_poc.dart';

void main() {
  testWidgets('Android unread conversation exposes mark-as-read action', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway = _ConversationGateway();
    final realtime = RealtimeClient(
      baseUri: Uri.parse('http://127.0.0.1:19999'),
      clientId: 'device-a',
      channelFactory: (_) => throw StateError('not used'),
    );
    final coordinator = MessagingCoordinator(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
      currentUserId: 'user-a',
      deviceId: 'device-a',
      gateway: gateway,
      localStore: _ConversationStore(),
      realtimeClient: realtime,
    );
    addTearDown(() async {
      coordinator.dispose();
      await realtime.dispose();
    });
    await coordinator.refreshConversations();

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: ConversationsPage(
          origin: Uri.parse('http://127.0.0.1:18473'),
          accessToken: 'token',
          currentUserId: 'user-a',
          deviceId: 'device-a',
          currentUserDisplayName: 'Alice',
          coordinator: coordinator,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(
      find.byKey(const Key('conversation-conversation-1')),
    );
    await tester.pumpAndSettle();
    expect(find.text('标为已读'), findsOneWidget);

    await tester.tap(find.text('标为已读'));
    await tester.pumpAndSettle();
    expect(gateway.markedReads, [('conversation-1', 7)]);
    expect(coordinator.conversationFor('conversation-1')?.unreadCount, 0);
  });
}

final class _ConversationGateway implements MessagingGateway {
  int unreadCount = 1;
  final List<(String, int)> markedReads = [];

  ConversationItem get conversation => ConversationItem(
    id: 'conversation-1',
    type: 'DIRECT',
    peer: const MessagingUserPreview(
      id: 'user-b',
      handle: 'bob',
      displayName: 'Bob',
    ),
    lastSequence: 7,
    lastReadSequence: unreadCount == 0 ? 7 : 6,
    unreadCount: unreadCount,
    lastMessage: ChatMessage(
      id: 'message-7',
      conversationId: 'conversation-1',
      sequence: 7,
      senderUserId: 'user-b',
      senderDeviceId: 'device-b',
      clientMessageId: 'client-7',
      type: 'TEXT',
      content: const TextMessageContent(text: 'hello'),
      createdAt: DateTime.utc(2026, 8, 8, 8),
    ),
    preferences: const ConversationPreferences(isPinned: false),
    createdAt: DateTime.utc(2026, 8, 8),
    updatedAt: DateTime.utc(2026, 8, 8, 8),
  );

  @override
  Future<List<ConversationItem>> listConversations({
    required Uri origin,
    required String accessToken,
  }) async => [conversation];

  @override
  Future<int> markRead({
    required Uri origin,
    required String accessToken,
    required String conversationId,
    required int sequence,
  }) async {
    markedReads.add((conversationId, sequence));
    unreadCount = 0;
    return sequence;
  }

  @override
  Future<MessagePage> listMessages({
    required Uri origin,
    required String accessToken,
    required String conversationId,
    int beforeSequence = 0,
    int limit = 50,
  }) async => const MessagePage(items: [], hasMore: false);

  @override
  Future<SyncPage> sync({
    required Uri origin,
    required String accessToken,
    required int cursor,
    int limit = 200,
  }) async => SyncPage(items: const [], nextCursor: cursor, hasMore: false);

  @override
  Future<ConversationItem> updatePreferences({
    required Uri origin,
    required String accessToken,
    required String conversationId,
    bool? isPinned,
    DateTime? mutedUntil,
    bool clearMute = false,
  }) async => conversation;

  @override
  Future<ConversationItem> ensureDirectConversation({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async => conversation;

  @override
  Future<ChatMessage> sendText({
    required Uri origin,
    required String accessToken,
    required String conversationId,
    required String clientMessageId,
    required String text,
    String? replyToMessageId,
  }) => throw UnimplementedError();

  @override
  Future<ChatMessage> sendImage({
    required Uri origin,
    required String accessToken,
    required String conversationId,
    required String clientMessageId,
    required String mediaId,
    required int width,
    required int height,
    String? replyToMessageId,
  }) => throw UnimplementedError();

  @override
  Future<ChatMessage> sendMedia({
    required Uri origin,
    required String accessToken,
    required String conversationId,
    required String clientMessageId,
    required String type,
    required String mediaId,
    int? width,
    int? height,
    int? durationMs,
    String? replyToMessageId,
  }) => throw UnimplementedError();

  @override
  Future<ChatMessage> recallMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
  }) => throw UnimplementedError();

  @override
  Future<void> deleteMessageLocally({
    required Uri origin,
    required String accessToken,
    required String messageId,
  }) async {}

  @override
  void close() {}
}

final class _ConversationStore implements MessagingLocalStore {
  @override
  Future<MessagingLocalState> load() async =>
      const MessagingLocalState(syncCursor: 0, pending: []);

  @override
  Future<void> save({
    required int syncCursor,
    required List<PendingTextMessage> pending,
    required Map<String, String> drafts,
    required List<String> recentEmoji,
    required List<String> heardVoiceMessageIds,
  }) async {}

  @override
  Future<void> clear() async {}
}
