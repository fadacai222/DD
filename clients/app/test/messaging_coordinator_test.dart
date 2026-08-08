import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:im_client/features/messaging/application/messaging_coordinator.dart';
import 'package:im_client/features/messaging/data/messaging_api_client.dart';
import 'package:im_client/features/messaging/data/messaging_local_store.dart';
import 'package:im_client/features/messaging/domain/messaging_models.dart';
import 'package:realtime_poc/realtime_poc.dart';

void main() {
  test('image message is retained in durable queue until delivery succeeds', () async {
    final store = _MemoryMessagingStore();
    final gateway = _FakeMessagingGateway()..failNextSend = true;
    final realtime = RealtimeClient(
      baseUri: Uri.parse('http://127.0.0.1:19999'),
      clientId: 'device-test-image',
      channelFactory: (_) => throw StateError('not used'),
    );
    final coordinator = MessagingCoordinator(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
      currentUserId: 'user-a',
      deviceId: 'device-test-image',
      gateway: gateway,
      localStore: store,
      realtimeClient: realtime,
    );
    addTearDown(() async {
      coordinator.dispose();
      await realtime.dispose();
    });

    await coordinator.sendImage(
      'conversation-a',
      mediaId: '00000000-0000-0000-0000-000000000123',
      width: 1080,
      height: 1440,
    );
    expect(coordinator.pending, hasLength(1));
    expect(coordinator.pending.single.type, 'IMAGE');
    expect(store.state.pending.single.mediaId, '00000000-0000-0000-0000-000000000123');

    await coordinator.flushPending();
    expect(coordinator.pending, isEmpty);
    expect(gateway.sentImageIds, ['00000000-0000-0000-0000-000000000123']);
  });

  test('gif message stays durable while offline and retries with same media', () async {
    final store = _MemoryMessagingStore();
    final gateway = _FakeMessagingGateway()..failNextSend = true;
    final realtime = RealtimeClient(
      baseUri: Uri.parse('http://127.0.0.1:19999'),
      clientId: 'device-test-gif',
      channelFactory: (_) => throw StateError('not used'),
    );
    final coordinator = MessagingCoordinator(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
      currentUserId: 'user-a',
      deviceId: 'device-test-gif',
      gateway: gateway,
      localStore: store,
      realtimeClient: realtime,
    );
    addTearDown(() async {
      coordinator.dispose();
      await realtime.dispose();
    });

    await coordinator.sendMedia(
      'conversation-a',
      type: 'GIF',
      mediaId: '00000000-0000-0000-0000-000000000456',
      width: 480,
      height: 320,
    );
    expect(coordinator.pending, hasLength(1));
    final clientMessageId = coordinator.pending.single.clientMessageId;
    expect(coordinator.pending.single.type, 'GIF');
    expect(store.state.pending.single.clientMessageId, clientMessageId);

    await coordinator.flushPending();
    expect(coordinator.pending, isEmpty);
    expect(gateway.sentMediaTypes, ['GIF']);
    expect(gateway.sentMediaIds, ['00000000-0000-0000-0000-000000000456']);
  });

  test('voice message stays durable while offline and preserves duration', () async {
    final store = _MemoryMessagingStore();
    final gateway = _FakeMessagingGateway()..failNextSend = true;
    final realtime = RealtimeClient(
      baseUri: Uri.parse('http://127.0.0.1:19999'),
      clientId: 'device-test-voice',
      channelFactory: (_) => throw StateError('not used'),
    );
    final coordinator = MessagingCoordinator(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
      currentUserId: 'user-a',
      deviceId: 'device-test-voice',
      gateway: gateway,
      localStore: store,
      realtimeClient: realtime,
    );
    addTearDown(() async {
      coordinator.dispose();
      await realtime.dispose();
    });

    await coordinator.sendMedia(
      'conversation-a',
      type: 'VOICE',
      mediaId: '00000000-0000-0000-0000-000000000789',
      durationMs: 4200,
      mimeType: 'audio/wav',
      sizeBytes: 64000,
    );
    expect(coordinator.pending, hasLength(1));
    expect(coordinator.pending.single.type, 'VOICE');
    expect(coordinator.pending.single.durationMs, 4200);
    expect(store.state.pending.single.durationMs, 4200);

    await coordinator.flushPending();
    expect(coordinator.pending, isEmpty);
    expect(gateway.sentMediaTypes, ['VOICE']);
    expect(gateway.sentMediaIds, ['00000000-0000-0000-0000-000000000789']);
  });

  test('recent emoji is deduplicated, ordered and capped', () async {
    final store = _MemoryMessagingStore();
    final realtime = RealtimeClient(
      baseUri: Uri.parse('http://127.0.0.1:19999'),
      clientId: 'device-test-emoji',
      channelFactory: (_) => throw StateError('not used'),
    );
    final coordinator = MessagingCoordinator(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
      currentUserId: 'user-a',
      deviceId: 'device-test-emoji',
      gateway: _FakeMessagingGateway(),
      localStore: store,
      realtimeClient: realtime,
    );
    addTearDown(() async {
      coordinator.dispose();
      await realtime.dispose();
    });

    for (var i = 0; i < 14; i++) {
      await coordinator.rememberRecentEmoji('emoji-$i');
    }
    await coordinator.rememberRecentEmoji('emoji-5');

    expect(coordinator.recentEmoji, hasLength(12));
    expect(coordinator.recentEmoji.first, 'emoji-5');
    expect(coordinator.recentEmoji.where((item) => item == 'emoji-5'), hasLength(1));
    expect(store.state.recentEmoji, coordinator.recentEmoji);
  });

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

  test(
    'expired access token keeps pending message and requests refresh',
    () async {
      final gateway = _FakeMessagingGateway()
        ..nextSendApiError = const MessagingApiException(
          statusCode: 401,
          code: 'UNAUTHORIZED',
          message: 'Access token expired',
        );
      final store = _MemoryMessagingStore();
      final realtime = RealtimeClient(
        baseUri: Uri.parse('http://127.0.0.1:19999'),
        clientId: 'device-test-refresh',
        channelFactory: (_) => throw StateError('not used'),
      );
      var refreshCalls = 0;
      final coordinator = MessagingCoordinator(
        origin: Uri.parse('http://127.0.0.1:18473'),
        accessToken: 'expired-token',
        currentUserId: 'user-a',
        deviceId: 'device-test-refresh',
        gateway: gateway,
        localStore: store,
        realtimeClient: realtime,
        onUnauthorized: () async {
          refreshCalls++;
        },
      );
      addTearDown(() async {
        coordinator.dispose();
        await realtime.dispose();
      });

      await coordinator.sendText('conversation-1', 'keep me');
      await Future<void>.delayed(Duration.zero);

      expect(refreshCalls, 1);
      expect(coordinator.pending, hasLength(1));
      expect(coordinator.pending.single.lastError, isNull);
      expect(store.state.pending, hasLength(1));
      expect(coordinator.errorMessage, contains('会话正在刷新'));
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

final class _FakeMessagingGateway implements MessagingGateway {
  bool failNextSend = false;
  MessagingApiException? nextSendApiError;
  final List<String> sentClientIds = [];
  final List<String?> sentReplyIds = [];
  final List<String> sentImageIds = [];
  final List<String> sentMediaIds = [];
  final List<String> sentMediaTypes = [];
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
    final apiError = nextSendApiError;
    if (apiError != null) {
      nextSendApiError = null;
      throw apiError;
    }
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
    if (failNextSend) {
      failNextSend = false;
      throw http.ClientException('offline');
    }
    sentImageIds.add(mediaId);
    return ChatMessage(
      id: 'image-$clientMessageId',
      conversationId: conversationId,
      sequence: sentClientIds.length + sentImageIds.length,
      senderUserId: 'user-a',
      senderDeviceId: 'device-a',
      clientMessageId: clientMessageId,
      type: 'IMAGE',
      content: TextMessageContent(mediaId: mediaId, width: width, height: height),
      replyToMessageId: replyToMessageId,
      createdAt: DateTime.utc(2026, 8, 8),
    );
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
    if (failNextSend) {
      failNextSend = false;
      throw http.ClientException('offline');
    }
    sentMediaIds.add(mediaId);
    sentMediaTypes.add(type);
    return ChatMessage(
      id: 'media-$clientMessageId',
      conversationId: conversationId,
      sequence: sentClientIds.length + sentImageIds.length + sentMediaIds.length,
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
