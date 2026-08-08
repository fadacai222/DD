import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/messaging/application/messaging_coordinator.dart';
import 'package:im_client/features/messaging/data/messaging_api_client.dart';
import 'package:im_client/features/messaging/data/messaging_local_store.dart';
import 'package:im_client/features/messaging/domain/messaging_models.dart';
import 'package:im_client/features/messaging/presentation/text_chat_page.dart';
import 'package:im_client/theme/app_theme.dart';
import 'package:realtime_poc/realtime_poc.dart';

void main() {
  testWidgets('own message shows peer read receipt when allowed', (
    tester,
  ) async {
    final gateway = _ChatGateway(
      peerLastReadSequence: 7,
      history: [
        ChatMessage(
          id: 'message-read-1',
          conversationId: 'conversation-1',
          sequence: 7,
          senderUserId: 'user-a',
          senderDeviceId: 'device-a',
          clientMessageId: 'client-read-0001',
          type: 'TEXT',
          content: const TextMessageContent(text: 'read me'),
          createdAt: DateTime.utc(2026, 8, 8, 8),
        ),
      ],
    );
    final harness = _Harness(gateway);
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: TextChatPage(
          coordinator: harness.coordinator,
          conversation: _conversation(peerLastReadSequence: 7),
          currentUserId: 'user-a',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));

    expect(
      find.byKey(const Key('message-status-message-read-1')),
      findsOneWidget,
    );
    expect(find.text('已读'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden desktop chat does not mark incoming messages as read', (
    tester,
  ) async {
    final gateway = _ChatGateway(
      history: [
        ChatMessage(
          id: 'message-unread-1',
          conversationId: 'conversation-1',
          sequence: 7,
          senderUserId: 'user-b',
          senderDeviceId: 'device-b',
          clientMessageId: 'client-unread-0001',
          type: 'TEXT',
          content: const TextMessageContent(text: 'do not auto read'),
          createdAt: DateTime.utc(2026, 8, 8, 8),
        ),
      ],
    );
    final harness = _Harness(gateway);
    addTearDown(harness.dispose);
    final conversation = _conversation(lastReadSequence: 0, unreadCount: 1);

    Widget page({required bool visible}) => MaterialApp(
      theme: AppTheme.light(),
      home: TextChatPage(
        coordinator: harness.coordinator,
        conversation: conversation,
        currentUserId: 'user-a',
        hostVisible: visible,
        embedded: true,
      ),
    );

    await tester.pumpWidget(page(visible: false));
    await tester.pump(const Duration(milliseconds: 150));
    expect(gateway.markedReads, isEmpty);

    await tester.pumpWidget(page(visible: true));
    await tester.pump(const Duration(milliseconds: 150));
    expect(gateway.markedReads, [('conversation-1', 7)]);
  });

  testWidgets('Android blank tap dismisses composer keyboard', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final gateway = _ChatGateway();
      final harness = _Harness(gateway);
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: TextChatPage(
            coordinator: harness.coordinator,
            conversation: _conversation(),
            currentUserId: 'user-a',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 80));

      final composer = find.byKey(const Key('chat-composer'));
      await tester.tap(composer);
      await tester.pump();
      expect(tester.widget<TextField>(composer).focusNode?.hasFocus, isTrue);

      await tester.tap(find.byKey(const Key('chat-message-surface')));
      await tester.pump();
      expect(tester.widget<TextField>(composer).focusNode?.hasFocus, isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Android destructive local delete action is red', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final gateway = _ChatGateway(
        history: [
          ChatMessage(
            id: 'message-menu-1',
            conversationId: 'conversation-1',
            sequence: 7,
            senderUserId: 'user-b',
            senderDeviceId: 'device-b',
            clientMessageId: 'client-menu-0001',
            type: 'TEXT',
            content: const TextMessageContent(text: 'menu me'),
            createdAt: DateTime.utc(2026, 8, 8, 8),
          ),
        ],
      );
      final harness = _Harness(gateway);
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: TextChatPage(
            coordinator: harness.coordinator,
            conversation: _conversation(),
            currentUserId: 'user-a',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 120));

      await tester.longPress(find.text('menu me'));
      await tester.pumpAndSettle();

      final deleteText = tester.widget<Text>(find.text('仅本地删除'));
      expect(deleteText.style?.color, DdColors.danger);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Windows Enter sends while Shift+Enter keeps editing', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final gateway = _ChatGateway();
      final harness = _Harness(gateway);
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: TextChatPage(
            coordinator: harness.coordinator,
            conversation: _conversation(),
            currentUserId: 'user-a',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 80));

      final composer = find.byKey(const Key('chat-composer'));
      await tester.tap(composer);
      await tester.enterText(composer, 'first line');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      expect(gateway.sentTexts, isEmpty);
      final field = tester.widget<TextField>(composer);
      expect(field.controller!.text, contains('first line'));

      await tester.enterText(composer, 'send with enter');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 120));

      expect(gateway.sentTexts, ['send with enter']);
      final fieldAfterSend = tester.widget<TextField>(composer);
      expect(fieldAfterSend.focusNode?.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

ConversationItem _conversation({
  int? peerLastReadSequence,
  int lastReadSequence = 7,
  int unreadCount = 0,
}) => ConversationItem(
  id: 'conversation-1',
  type: 'DIRECT',
  peer: const MessagingUserPreview(
    id: 'user-b',
    handle: 'bob',
    displayName: 'Bob',
  ),
  lastSequence: 7,
  lastReadSequence: lastReadSequence,
  peerLastReadSequence: peerLastReadSequence,
  unreadCount: unreadCount,
  preferences: const ConversationPreferences(isPinned: false),
  createdAt: DateTime.utc(2026, 8, 8),
  updatedAt: DateTime.utc(2026, 8, 8),
);

final class _Harness {
  _Harness(_ChatGateway gateway)
    : realtime = RealtimeClient(
        baseUri: Uri.parse('http://127.0.0.1:19999'),
        clientId: 'device-a',
        channelFactory: (_) => throw StateError('not used'),
      ),
      store = _ChatStore() {
    coordinator = MessagingCoordinator(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
      currentUserId: 'user-a',
      deviceId: 'device-a',
      gateway: gateway,
      localStore: store,
      realtimeClient: realtime,
    );
  }

  final RealtimeClient realtime;
  final _ChatStore store;
  late final MessagingCoordinator coordinator;

  Future<void> dispose() async {
    coordinator.dispose();
    await realtime.dispose();
  }
}

final class _ChatStore implements MessagingLocalStore {
  MessagingLocalState state = const MessagingLocalState(
    syncCursor: 0,
    pending: [],
  );

  @override
  Future<void> clear() async {
    state = const MessagingLocalState(syncCursor: 0, pending: []);
  }

  @override
  Future<MessagingLocalState> load() async => state;

  @override
  Future<void> save({
    required int syncCursor,
    required List<PendingTextMessage> pending,
    required Map<String, String> drafts,
    required List<String> recentEmoji,
  }) async {
    state = MessagingLocalState(
      syncCursor: syncCursor,
      pending: List<PendingTextMessage>.from(pending),
      drafts: Map<String, String>.from(drafts),
      recentEmoji: List<String>.from(recentEmoji),
    );
  }
}

final class _ChatGateway implements MessagingGateway {
  _ChatGateway({
    List<ChatMessage> history = const [],
    this.peerLastReadSequence,
  }) : history = List<ChatMessage>.from(history);

  final List<ChatMessage> history;
  final int? peerLastReadSequence;
  final List<String> sentTexts = [];
  final List<(String, int)> markedReads = [];

  @override
  Future<List<ConversationItem>> listConversations({
    required Uri origin,
    required String accessToken,
  }) async => [_conversation(peerLastReadSequence: peerLastReadSequence)];

  @override
  Future<ConversationItem> ensureDirectConversation({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async => _conversation();

  @override
  Future<MessagePage> listMessages({
    required Uri origin,
    required String accessToken,
    required String conversationId,
    int beforeSequence = 0,
    int limit = 50,
  }) async => MessagePage(items: history.reversed.toList(), hasMore: false);

  @override
  Future<ChatMessage> sendText({
    required Uri origin,
    required String accessToken,
    required String conversationId,
    required String clientMessageId,
    required String text,
    String? replyToMessageId,
  }) async {
    sentTexts.add(text);
    final message = ChatMessage(
      id: 'sent-${sentTexts.length}',
      conversationId: conversationId,
      sequence: history.length + 1,
      senderUserId: 'user-a',
      senderDeviceId: 'device-a',
      clientMessageId: clientMessageId,
      type: 'TEXT',
      content: TextMessageContent(text: text),
      replyToMessageId: replyToMessageId,
      createdAt: DateTime.utc(2026, 8, 8, 8, sentTexts.length),
    );
    history.add(message);
    return message;
  }

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
  }) async {
    final message = ChatMessage(
      id: 'image-${history.length + 1}',
      conversationId: conversationId,
      sequence: history.length + 1,
      senderUserId: 'user-a',
      senderDeviceId: 'device-a',
      clientMessageId: clientMessageId,
      type: 'IMAGE',
      content: TextMessageContent(mediaId: mediaId, width: width, height: height),
      replyToMessageId: replyToMessageId,
      createdAt: DateTime.utc(2026, 8, 8, 9),
    );
    history.add(message);
    return message;
  }

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
  }) async {
    final message = ChatMessage(
      id: 'media-${history.length + 1}',
      conversationId: conversationId,
      sequence: history.length + 1,
      senderUserId: 'user-a',
      senderDeviceId: 'device-a',
      clientMessageId: clientMessageId,
      type: type,
      content: TextMessageContent(
        mediaId: mediaId,
        width: width,
        height: height,
        durationMs: durationMs,
      ),
      replyToMessageId: replyToMessageId,
      createdAt: DateTime.utc(2026, 8, 8, 9),
    );
    history.add(message);
    return message;
  }

  @override
  Future<ConversationItem> updatePreferences({
    required Uri origin,
    required String accessToken,
    required String conversationId,
    bool? isPinned,
    DateTime? mutedUntil,
    bool clearMute = false,
  }) async => _conversation();

  @override
  Future<int> markRead({
    required Uri origin,
    required String accessToken,
    required String conversationId,
    required int sequence,
  }) async {
    markedReads.add((conversationId, sequence));
    return sequence;
  }

  @override
  Future<ChatMessage> recallMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
  }) async => history.firstWhere((message) => message.id == messageId);

  @override
  Future<void> deleteMessageLocally({
    required Uri origin,
    required String accessToken,
    required String messageId,
  }) async {}

  @override
  Future<SyncPage> sync({
    required Uri origin,
    required String accessToken,
    required int cursor,
    int limit = 200,
  }) async => SyncPage(items: const [], nextCursor: cursor, hasMore: false);

  @override
  void close() {}
}
