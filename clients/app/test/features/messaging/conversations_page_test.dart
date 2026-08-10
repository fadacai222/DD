import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/messaging/application/messaging_coordinator.dart';
import 'package:im_client/features/messaging/data/messaging_api_client.dart';
import 'package:im_client/features/messaging/data/messaging_local_store.dart';
import 'package:im_client/features/messaging/domain/messaging_models.dart';
import 'package:im_client/features/messaging/presentation/conversations_page.dart';
import 'package:im_client/features/messaging/presentation/conversations_page_controller.dart';
import 'package:im_client/theme/app_theme.dart';
import 'package:realtime_poc/realtime_poc.dart';

void main() {
  testWidgets('external navigation selects a desktop conversation in-place', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(881, 657);
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
    final navigation = ConversationsPageController();
    addTearDown(() async {
      navigation.dispose();
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
          coordinator: coordinator,
          navigationController: navigation,
          embedded: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const Key('desktop-conversation-sidebar'))).width,
      DdDesktopTokens.sidebarWidth,
    );
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('desktop-chat-conversation-1')),
      findsNothing,
    );

    navigation.openConversation('conversation-1');
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('desktop-chat-conversation-1')),
      findsOneWidget,
    );
  });

  testWidgets(
    'mobile message header uses DD and exposes WeChat-style create menu',
    (tester) async {
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
            coordinator: coordinator,
            onOpenContacts: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('DD'), findsOneWidget);
      expect(
        find.byKey(const Key('saved-messages-conversation-entry')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('saved-messages-pin')), findsOneWidget);
      final titleCenter = tester.getCenter(
        find.byKey(const Key('messaging-mobile-title')),
      );
      final createCenter = tester.getCenter(
        find.byKey(const Key('messaging-create-menu')),
      );
      expect(titleCenter.dx, closeTo(180, 2));
      expect(createCenter.dx, greaterThan(320));
      expect((createCenter.dx - titleCenter.dx).abs(), greaterThan(120));

      await tester.tap(find.byKey(const Key('messaging-create-menu')));
      await tester.pumpAndSettle();
      expect(find.text('发起群聊'), findsOneWidget);
      expect(find.text('添加联系人'), findsOneWidget);
      expect(find.text('收藏'), findsNothing);
      expect(find.text('扫一扫'), findsOneWidget);
    },
  );

  testWidgets('mobile search launcher opens secondary search page', (
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
          coordinator: coordinator,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('messaging-mobile-search-launcher')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('messaging-mobile-search-launcher')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('messaging-global-search-field')),
      findsOneWidget,
    );
  });

  testWidgets('archived conversation stays behind archived entry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway = _ConversationGateway(
      archivedAt: DateTime.utc(2026, 8, 9, 1),
    );
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
          coordinator: coordinator,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('archived-conversations-entry')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('conversation-conversation-1')), findsNothing);

    await tester.tap(find.byKey(const Key('archived-conversations-entry')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('conversation-conversation-1')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('archive-back')), findsOneWidget);
  });

  testWidgets('pinned conversation exposes explicit pin icon', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway = _ConversationGateway(isPinned: true);
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
          coordinator: coordinator,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('conversation-pin-conversation-1')),
      findsOneWidget,
    );
  });

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

  testWidgets('Android right swipe exposes pin/read and pin action works', (
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
          coordinator: coordinator,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tile = find.byKey(const Key('conversation-conversation-1'));
    final initialX = tester.getTopLeft(tile).dx;
    await tester.drag(tile, const Offset(180, 0));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(tile).dx, greaterThan(initialX + 100));
    expect(
      find.byKey(const Key('conversation-swipe-pin-conversation-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('conversation-swipe-read-conversation-1')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('conversation-swipe-pin-conversation-1')),
    );
    await tester.pumpAndSettle();
    expect(gateway.isPinned, isTrue);
    expect(
      find.byKey(const Key('conversation-pin-conversation-1')),
      findsOneWidget,
    );
  });

  testWidgets(
    'Android left swipe exposes mute/archive/delete and delete hides',
    (tester) async {
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
            coordinator: coordinator,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final tile = find.byKey(const Key('conversation-conversation-1'));
      final initialX = tester.getTopLeft(tile).dx;
      await tester.drag(tile, const Offset(-260, 0));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(tile).dx, lessThan(initialX - 150));
      expect(
        find.byKey(const Key('conversation-swipe-mute-conversation-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('conversation-swipe-archive-conversation-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('conversation-swipe-delete-conversation-1')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('conversation-swipe-delete-conversation-1')),
      );
      await tester.pumpAndSettle();
      expect(find.text('删除会话？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();

      expect(gateway.hiddenConversationIds, ['conversation-1']);
      expect(
        find.byKey(const Key('conversation-conversation-1')),
        findsNothing,
      );
    },
  );
}

final class _ConversationGateway implements MessagingGateway {
  _ConversationGateway({this.isPinned = false, this.archivedAt});

  int unreadCount = 1;
  bool isPinned;
  DateTime? archivedAt;
  DateTime? mutedUntil;
  final List<(String, int)> markedReads = [];
  final List<String> hiddenConversationIds = [];

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
    preferences: ConversationPreferences(
      isPinned: isPinned,
      mutedUntil: mutedUntil,
      archivedAt: archivedAt,
    ),
    createdAt: DateTime.utc(2026, 8, 8),
    updatedAt: DateTime.utc(2026, 8, 8, 8),
  );

  @override
  Future<List<ConversationItem>> listConversations({
    required Uri origin,
    required String accessToken,
  }) async => [conversation];

  @override
  Future<ConversationItem> getConversation({
    required Uri origin,
    required String accessToken,
    required String conversationId,
  }) async => conversation;

  @override
  Future<void> hideConversation({
    required Uri origin,
    required String accessToken,
    required String conversationId,
  }) async {
    hiddenConversationIds.add(conversationId);
  }

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
  Future<List<SavedMessageItem>> listSavedMessages({
    required Uri origin,
    required String accessToken,
  }) async => const [];

  @override
  Future<void> saveMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
  }) async {}

  @override
  Future<void> unsaveMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
  }) async {}

  @override
  Future<List<PinnedMessageItem>> listPinnedMessages({
    required Uri origin,
    required String accessToken,
    required String conversationId,
  }) async => const [];

  @override
  Future<void> pinMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
  }) async {}

  @override
  Future<void> unpinMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
  }) async {}

  @override
  Future<ChatMessage> forwardMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
    required String targetConversationId,
    required String clientMessageId,
  }) => throw UnimplementedError();

  @override
  Future<List<MessageSearchHit>> searchMessages({
    required Uri origin,
    required String accessToken,
    required String query,
    String? conversationId,
  }) async => const [];

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
    bool? isArchived,
  }) async {
    if (isPinned != null) this.isPinned = isPinned;
    if (isArchived != null) {
      archivedAt = isArchived ? DateTime.utc(2026, 8, 9, 1) : null;
    }
    if (clearMute) mutedUntil = null;
    if (mutedUntil != null) this.mutedUntil = mutedUntil;
    return conversation;
  }

  @override
  Future<ConversationItem> ensureDirectConversation({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async => conversation;

  @override
  Future<ConversationItem> ensureSavedConversation({
    required Uri origin,
    required String accessToken,
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
    String? posterMediaId,
    int? width,
    int? height,
    int? durationMs,
    String? replyToMessageId,
  }) => throw UnimplementedError();

  @override
  Future<ChatMessage> editMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
    required String text,
    required int expectedEditVersion,
  }) async => throw UnimplementedError();

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
