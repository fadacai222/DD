import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:im_client/features/messaging/application/messaging_coordinator.dart';
import 'package:im_client/features/messaging/data/messaging_api_client.dart';
import 'package:im_client/features/messaging/data/messaging_local_store.dart';
import 'package:im_client/features/messaging/domain/messaging_models.dart';
import 'package:realtime_poc/realtime_poc.dart';

void main() {
  test(
    'offline retry reuses the same clientMessageId and clears durable queue',
    () async {
      final gateway = _FakeMessagingGateway()..failNextSend = true;
      final store = _MemoryMessagingStore();
      final realtime = RealtimeClient(
        baseUri: Uri.parse('http://127.0.0.1:19999'),
        clientId: 'device-test-0001',
        channelFactory: (_) => throw StateError('not used'),
      );
      final coordinator = MessagingCoordinator(
        origin: Uri.parse('http://127.0.0.1:18473'),
        accessToken: 'token',
        currentUserId: 'user-a',
        deviceId: 'device-test-0001',
        gateway: gateway,
        localStore: store,
        realtimeClient: realtime,
      );
      addTearDown(() async {
        coordinator.dispose();
        await realtime.dispose();
      });

      await coordinator.sendText(
        'conversation-1',
        'hello offline',
        replyToMessageId: 'reply-target-0001',
      );
      expect(coordinator.pending, hasLength(1));
      final firstClientId = coordinator.pending.single.clientMessageId;
      expect(store.state.pending.single.clientMessageId, firstClientId);
      expect(store.state.pending.single.replyToMessageId, 'reply-target-0001');
      expect(gateway.sentClientIds, [firstClientId]);
      expect(gateway.sentReplyIds, ['reply-target-0001']);

      await coordinator.flushPending();
      expect(gateway.sentClientIds, [firstClientId, firstClientId]);
      expect(gateway.sentReplyIds, ['reply-target-0001', 'reply-target-0001']);
      expect(coordinator.pending, isEmpty);
      expect(store.state.pending, isEmpty);
    },
  );

  test('pending message can be cancelled from durable queue', () async {
    final gateway = _FakeMessagingGateway()..failNextSend = true;
    final store = _MemoryMessagingStore();
    final realtime = RealtimeClient(
      baseUri: Uri.parse('http://127.0.0.1:19999'),
      clientId: 'device-test-cancel',
      channelFactory: (_) => throw StateError('not used'),
    );
    final coordinator = MessagingCoordinator(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
      currentUserId: 'user-a',
      deviceId: 'device-test-cancel',
      gateway: gateway,
      localStore: store,
      realtimeClient: realtime,
    );
    addTearDown(() async {
      coordinator.dispose();
      await realtime.dispose();
    });

    await coordinator.sendText('conversation-1', 'cancel me');
    final clientMessageId = coordinator.pending.single.clientMessageId;
    await coordinator.cancelPending(clientMessageId);
    expect(coordinator.pending, isEmpty);
    expect(store.state.pending, isEmpty);
  });

  test('conversation preferences are forwarded to the gateway', () async {
    final gateway = _FakeMessagingGateway();
    final store = _MemoryMessagingStore();
    final realtime = RealtimeClient(
      baseUri: Uri.parse('http://127.0.0.1:19999'),
      clientId: 'device-test-preferences',
      channelFactory: (_) => throw StateError('not used'),
    );
    final coordinator = MessagingCoordinator(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
      currentUserId: 'user-a',
      deviceId: 'device-test-preferences',
      gateway: gateway,
      localStore: store,
      realtimeClient: realtime,
    );
    addTearDown(() async {
      coordinator.dispose();
      await realtime.dispose();
    });
    final conversation = _testConversation();
    final mutedUntil = DateTime.utc(2026, 8, 9);

    await coordinator.setPinned(conversation, true);
    expect(gateway.lastPinned, isTrue);
    expect(
      coordinator.conversationFor(conversation.id)?.preferences.isPinned,
      isTrue,
    );

    await coordinator.muteUntil(
      coordinator.conversationFor(conversation.id)!,
      mutedUntil,
    );
    expect(gateway.lastMutedUntil, mutedUntil);
    expect(
      coordinator.conversationFor(conversation.id)?.preferences.mutedUntil,
      mutedUntil,
    );
    expect(
      coordinator.conversationFor(conversation.id)?.preferences.isPinned,
      isTrue,
    );

    await coordinator.clearMute(coordinator.conversationFor(conversation.id)!);
    expect(gateway.clearMuteCalls, 1);
    expect(
      coordinator.conversationFor(conversation.id)?.preferences.mutedUntil,
      isNull,
    );
    expect(
      coordinator.conversationFor(conversation.id)?.preferences.isPinned,
      isTrue,
    );
  });

  test(
    'draft is persisted and cleared independently of pending queue',
    () async {
      final gateway = _FakeMessagingGateway();
      final store = _MemoryMessagingStore();
      final realtime = RealtimeClient(
        baseUri: Uri.parse('http://127.0.0.1:19999'),
        clientId: 'device-test-draft',
        channelFactory: (_) => throw StateError('not used'),
      );
      final coordinator = MessagingCoordinator(
        origin: Uri.parse('http://127.0.0.1:18473'),
        accessToken: 'token',
        currentUserId: 'user-a',
        deviceId: 'device-test-draft',
        gateway: gateway,
        localStore: store,
        realtimeClient: realtime,
      );
      addTearDown(() async {
        coordinator.dispose();
        await realtime.dispose();
      });

      await coordinator.setDraft('conversation-1', 'half typed');
      expect(coordinator.draftFor('conversation-1'), 'half typed');
      expect(store.state.drafts['conversation-1'], 'half typed');
      await coordinator.setDraft('conversation-1', '');
      expect(coordinator.draftFor('conversation-1'), isEmpty);
      expect(store.state.drafts, isNot(contains('conversation-1')));
    },
  );

  test('active conversation advances read state after sync', () async {
    final message = ChatMessage(
      id: 'message-active-1',
      conversationId: 'conversation-1',
      sequence: 1,
      senderUserId: 'user-b',
      senderDeviceId: 'device-b',
      clientMessageId: 'client-active-0001',
      type: 'TEXT',
      content: const TextMessageContent(text: 'incoming'),
      createdAt: DateTime.utc(2026, 8, 8),
    );
    final gateway = _FakeMessagingGateway()
      ..history = [message]
      ..syncPages.add(
        SyncPage(
          items: [
            SyncEventItem(
              eventId: 'event-active-1',
              cursor: 1,
              type: 'MESSAGE_CREATED',
              conversationId: 'conversation-1',
              sequence: 1,
              occurredAt: DateTime.utc(2026, 8, 8),
            ),
          ],
          nextCursor: 1,
          hasMore: false,
        ),
      );
    final store = _MemoryMessagingStore();
    final realtime = RealtimeClient(
      baseUri: Uri.parse('http://127.0.0.1:19999'),
      clientId: 'device-test-active',
      channelFactory: (_) => throw StateError('not used'),
    );
    final coordinator = MessagingCoordinator(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
      currentUserId: 'user-a',
      deviceId: 'device-test-active',
      gateway: gateway,
      localStore: store,
      realtimeClient: realtime,
    );
    addTearDown(() async {
      coordinator.dispose();
      await realtime.dispose();
    });

    await coordinator.loadMessages('conversation-1', markRead: false);
    coordinator.activateConversation('conversation-1');
    await coordinator.syncNow();
    expect(gateway.markedReads, [('conversation-1', 1)]);
  });

  test('sync cursor only advances and is persisted', () async {
    final gateway = _FakeMessagingGateway()
      ..syncPages.addAll([
        SyncPage(
          items: [
            SyncEventItem(
              eventId: 'event-1',
              cursor: 5,
              type: 'MESSAGE_CREATED',
              conversationId: 'conversation-1',
              occurredAt: DateTime.utc(2026, 8, 8),
            ),
          ],
          nextCursor: 5,
          hasMore: true,
        ),
        const SyncPage(items: [], nextCursor: 5, hasMore: false),
      ]);
    final store = _MemoryMessagingStore(initialCursor: 2);
    final realtime = RealtimeClient(
      baseUri: Uri.parse('http://127.0.0.1:19999'),
      clientId: 'device-test-0002',
      channelFactory: (_) => throw StateError('not used'),
    );
    final coordinator = MessagingCoordinator(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
      currentUserId: 'user-a',
      deviceId: 'device-test-0002',
      gateway: gateway,
      localStore: store,
      realtimeClient: realtime,
    );
    addTearDown(() async {
      coordinator.dispose();
      await realtime.dispose();
    });

    await coordinator.initialize();
    expect(coordinator.syncCursor, 5);
    expect(store.state.syncCursor, 5);
  });
}

ConversationItem _testConversation({
  bool isPinned = false,
  DateTime? mutedUntil,
}) => ConversationItem(
  id: 'conversation-1',
  type: 'DIRECT',
  lastSequence: 0,
  lastReadSequence: 0,
  unreadCount: 0,
  preferences: ConversationPreferences(
    isPinned: isPinned,
    mutedUntil: mutedUntil,
  ),
  createdAt: DateTime.utc(2026, 8, 8),
  updatedAt: DateTime.utc(2026, 8, 8),
);

final class _MemoryMessagingStore implements MessagingLocalStore {
  _MemoryMessagingStore({int initialCursor = 0})
    : state = MessagingLocalState(syncCursor: initialCursor, pending: const []);

  MessagingLocalState state;

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
  }) async {
    state = MessagingLocalState(
      syncCursor: syncCursor,
      pending: List<PendingTextMessage>.from(pending),
      drafts: Map<String, String>.from(drafts),
    );
  }
}

final class _FakeMessagingGateway implements MessagingGateway {
  bool failNextSend = false;
  final List<String> sentClientIds = [];
  final List<String?> sentReplyIds = [];
  final List<SyncPage> syncPages = [];
  List<ChatMessage> history = const [];
  final List<(String, int)> markedReads = [];
  bool? lastPinned;
  DateTime? lastMutedUntil;
  int clearMuteCalls = 0;
  bool preferencePinned = false;
  DateTime? preferenceMutedUntil;

  @override
  Future<ChatMessage> sendText({
    required Uri origin,
    required String accessToken,
    required String conversationId,
    required String clientMessageId,
    required String text,
    String? replyToMessageId,
  }) async {
    sentClientIds.add(clientMessageId);
    sentReplyIds.add(replyToMessageId);
    if (failNextSend) {
      failNextSend = false;
      throw http.ClientException('offline');
    }
    return ChatMessage(
      id: 'message-${sentClientIds.length}',
      conversationId: conversationId,
      sequence: sentClientIds.length,
      senderUserId: 'user-a',
      senderDeviceId: 'device-a',
      clientMessageId: clientMessageId,
      type: 'TEXT',
      content: TextMessageContent(text: text),
      createdAt: DateTime.utc(2026, 8, 8),
    );
  }

  @override
  Future<List<ConversationItem>> listConversations({
    required Uri origin,
    required String accessToken,
  }) async => const [];

  @override
  Future<MessagePage> listMessages({
    required Uri origin,
    required String accessToken,
    required String conversationId,
    int beforeSequence = 0,
    int limit = 50,
  }) async => MessagePage(items: history.reversed.toList(), hasMore: false);

  @override
  Future<SyncPage> sync({
    required Uri origin,
    required String accessToken,
    required int cursor,
    int limit = 200,
  }) async {
    if (syncPages.isEmpty) {
      return SyncPage(items: const [], nextCursor: cursor, hasMore: false);
    }
    return syncPages.removeAt(0);
  }

  @override
  Future<ConversationItem> ensureDirectConversation({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ConversationItem> updatePreferences({
    required Uri origin,
    required String accessToken,
    required String conversationId,
    bool? isPinned,
    DateTime? mutedUntil,
    bool clearMute = false,
  }) async {
    if (isPinned != null) {
      lastPinned = isPinned;
      preferencePinned = isPinned;
    }
    if (mutedUntil != null) {
      lastMutedUntil = mutedUntil;
      preferenceMutedUntil = mutedUntil;
    }
    if (clearMute) {
      clearMuteCalls++;
      preferenceMutedUntil = null;
    }
    return _testConversation(
      isPinned: preferencePinned,
      mutedUntil: preferenceMutedUntil,
    );
  }

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
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteMessageLocally({
    required Uri origin,
    required String accessToken,
    required String messageId,
  }) async {}

  @override
  void close() {}
}
