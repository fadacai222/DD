import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:realtime_poc/realtime_poc.dart';

import '../../../core/logging/client_log.dart';
import '../data/media_api_client.dart';
import '../data/media_transfer_history_store.dart';
import '../data/messaging_api_client.dart';
import '../data/messaging_local_store.dart';
import '../domain/messaging_models.dart';
import 'media_transfer_controller.dart';
import 'message_notification_preview.dart';

final class MessagingCoordinator extends ChangeNotifier {
  MessagingCoordinator({
    required this.origin,
    required this.accessToken,
    required this.currentUserId,
    required this.deviceId,
    MessagingGateway? gateway,
    MessagingLocalStore? localStore,
    RealtimeClient? realtimeClient,
    MediaTransferController? mediaTransfers,
    this.onUnauthorized,
  }) : _gateway = gateway ?? MessagingApiClient(),
       _ownsGateway = gateway == null,
       _localStore =
           localStore ??
           SecureMessagingLocalStore(userId: currentUserId, deviceId: deviceId),
       _mediaTransfers = mediaTransfers ??
           MediaTransferController(
             maxConcurrent: 3,
             historyStore: MediaTransferHistoryStore(userId: currentUserId),
           ),
       _ownsMediaTransfers = mediaTransfers == null,
       _transferMediaApi = MediaApiClient(),
       _realtime =
           realtimeClient ??
           RealtimeClient(
             baseUri: origin,
             clientId: deviceId,
             webSocketPath: '/api/v1/realtime',
             accessToken: accessToken,
             protocolVersion: '1',
           ),
       _ownsRealtime = realtimeClient == null;

  final Uri origin;
  String accessToken;
  final String currentUserId;
  final String deviceId;
  final MessagingGateway _gateway;
  final bool _ownsGateway;
  final MessagingLocalStore _localStore;
  final MediaTransferController _mediaTransfers;
  final bool _ownsMediaTransfers;
  final MediaApiClient _transferMediaApi;
  final RealtimeClient _realtime;
  final bool _ownsRealtime;
  final Future<String?> Function()? onUnauthorized;

  final StreamController<IncomingMessageNotice> _incomingMessageController =
      StreamController<IncomingMessageNotice>.broadcast();
  final StreamController<RelationshipNotice> _relationshipController =
      StreamController<RelationshipNotice>.broadcast();
  final StreamController<String> _eventAvailableReasonController =
      StreamController<String>.broadcast();
  final Map<String, List<ChatMessage>> _messages = {};
  final Map<String, int?> _nextBeforeSequence = {};
  final Map<String, bool> _hasMore = {};
  List<ConversationItem> _conversations = const [];
  List<PendingTextMessage> _pending = const [];
  Map<String, String> _drafts = const {};
  List<String> _recentEmoji = const [];
  String _stickerPanelTabKey = 'emoji';
  List<String> _heardVoiceMessageIds = const [];
  StreamSubscription<RealtimeEvent>? _eventSubscription;
  StreamSubscription<RealtimeConnectionState>? _stateSubscription;
  int _syncCursor = 0;
  int _clientCounter = 0;
  bool _busy = false;
  bool _syncing = false;
  bool _disposed = false;
  String? _activeConversationId;
  String? _errorMessage;

  List<ConversationItem> get conversations => _conversations;
  List<PendingTextMessage> get pending => _pending;
  int get syncCursor => _syncCursor;
  bool get busy => _busy;
  String? get errorMessage => _errorMessage;
  RealtimeConnectionState get realtimeState => _realtime.state;
  Stream<IncomingMessageNotice> get incomingMessages =>
      _incomingMessageController.stream;
  Stream<RelationshipNotice> get relationshipNotices =>
      _relationshipController.stream;
  Stream<String> get eventAvailableReasons =>
      _eventAvailableReasonController.stream;
  int get totalUnreadCount => _conversations.fold<int>(
    0,
    (total, conversation) => total + conversation.unreadCount,
  );
  String? get activeConversationId => _activeConversationId;
  MediaTransferController get mediaTransfers => _mediaTransfers;
  MediaApiClient get transferMediaApi => _transferMediaApi;

  Future<void> updateAccessToken(String nextToken) async {
    final normalized = nextToken.trim();
    if (normalized.isEmpty || normalized == accessToken) return;
    accessToken = normalized;
    await _realtime.updateAccessToken(normalized);
    _errorMessage = null;
    _notify();
  }

  Future<T> withAuthorizedToken<T>(Future<T> Function(String token) action) =>
      _authorized(action);

  Future<T> _authorized<T>(Future<T> Function(String token) action) async {
    try {
      return await action(accessToken);
    } on MessagingApiException catch (error) {
      if (error.statusCode != 401 || onUnauthorized == null) rethrow;
      final refreshedToken = await onUnauthorized!.call();
      if (refreshedToken == null || refreshedToken.trim().isEmpty) rethrow;
      await updateAccessToken(refreshedToken);
      return action(accessToken);
    }
  }

  List<ChatMessage> messagesFor(String conversationId) => List.unmodifiable(
    (_messages[conversationId] ?? const <ChatMessage>[]).where(
      (message) => !message.isRecalled,
    ),
  );

  bool isMessageRecalled(String conversationId, String messageId) =>
      (_messages[conversationId] ?? const <ChatMessage>[]).any(
        (message) => message.id == messageId && message.isRecalled,
      );

  ConversationItem? conversationFor(String conversationId) {
    for (final conversation in _conversations) {
      if (conversation.id == conversationId) return conversation;
    }
    return null;
  }

  Future<ConversationItem?> resolveConversation(String conversationId) async {
    final cached = conversationFor(conversationId);
    if (cached != null) return cached;
    try {
      final conversation = await _authorized(
        (token) => _gateway.getConversation(
          origin: origin,
          accessToken: token,
          conversationId: conversationId,
        ),
      );
      _upsertConversation(conversation);
      return conversation;
    } catch (_) {
      return null;
    }
  }

  List<PendingTextMessage> pendingFor(String conversationId) => _pending
      .where((item) => item.conversationId == conversationId)
      .toList(growable: false);

  bool canLoadOlder(String conversationId) => _hasMore[conversationId] == true;
  String draftFor(String conversationId) => _drafts[conversationId] ?? '';
  List<String> get recentEmoji => List.unmodifiable(_recentEmoji);
  String get stickerPanelTabKey => _stickerPanelTabKey;
  bool isVoiceHeard(String messageId) =>
      _heardVoiceMessageIds.contains(messageId);

  Future<void> markVoiceHeard(String messageId) async {
    final id = messageId.trim();
    if (id.isEmpty || _heardVoiceMessageIds.contains(id)) return;
    final next = <String>[id, ..._heardVoiceMessageIds];
    _heardVoiceMessageIds = List.unmodifiable(next.take(500));
    await _persistLocalState();
    _notify();
  }

  Future<void> rememberRecentEmoji(String emoji) async {
    if (emoji.trim().isEmpty) return;
    final next = <String>[
      emoji,
      ..._recentEmoji.where((item) => item != emoji),
    ];
    _recentEmoji = List.unmodifiable(next.take(12));
    await _persistLocalState();
    _notify();
  }

  Future<void> rememberStickerPanelTab(String tabKey) async {
    final normalized = tabKey.trim();
    if (normalized.isEmpty || normalized == _stickerPanelTabKey) return;
    if (normalized != 'emoji' &&
        normalized != 'custom' &&
        !normalized.startsWith('pack:')) {
      return;
    }
    _stickerPanelTabKey = normalized;
    await _persistLocalState();
    _notify();
  }

  Future<void> setDraft(
    String conversationId,
    String text, {
    bool notify = true,
  }) async {
    final next = Map<String, String>.from(_drafts);
    if (text.isEmpty) {
      next.remove(conversationId);
    } else {
      next[conversationId] = text;
    }
    _drafts = Map.unmodifiable(next);
    await _persistLocalState();
    if (notify) _notify();
  }

  void activateConversation(String conversationId) {
    _activeConversationId = conversationId;
  }

  void deactivateConversation(String conversationId) {
    if (_activeConversationId == conversationId) {
      _activeConversationId = null;
    }
  }

  Future<void> initialize() async {
    if (_disposed) return;
    _setBusy(true);
    try {
      await _mediaTransfers.restoreHistory();
      final local = await _localStore.load();
      _syncCursor = local.syncCursor;
      _pending = local.pending;
      _drafts = Map.unmodifiable(local.drafts);
      _recentEmoji = List.unmodifiable(local.recentEmoji);
      _stickerPanelTabKey = local.stickerPanelTabKey.trim().isEmpty
          ? 'emoji'
          : local.stickerPanelTabKey.trim();
      _heardVoiceMessageIds = List.unmodifiable(local.heardVoiceMessageIds);
      _eventSubscription = _realtime.events.listen((event) {
        if (event.type == 'event_available') {
          final reason = event.payload['reason']?.toString().trim() ?? '';
          if (reason.isNotEmpty && !_eventAvailableReasonController.isClosed) {
            _eventAvailableReasonController.add(reason);
          }
          unawaited(syncNow());
        }
      });
      _stateSubscription = _realtime.states.listen((state) {
        if (state == RealtimeConnectionState.connected) {
          unawaited(flushPending());
          unawaited(syncNow());
        }
        _notify();
      });
      await refreshConversations();
      await flushPending();
      await syncNow();
      try {
        await _realtime.connect();
      } catch (_) {
        // REST + cursor sync remain authoritative; realtime reconnects itself.
      }
    } catch (error) {
      _setError(_friendlyError(error));
    } finally {
      _setBusy(false);
    }
  }

  Future<void> refreshConversations() async {
    final items = await _authorized(
      (token) => _gateway.listConversations(origin: origin, accessToken: token),
    );
    _conversations = items;
    _notify();
  }

  Future<ConversationItem> ensureDirectConversation(String userId) async {
    final conversation = await _authorized(
      (token) => _gateway.ensureDirectConversation(
        origin: origin,
        accessToken: token,
        userId: userId,
      ),
    );
    await refreshConversations();
    return conversation;
  }

  Future<ConversationItem> ensureSavedConversation() async {
    final conversation = await _authorized(
      (token) =>
          _gateway.ensureSavedConversation(origin: origin, accessToken: token),
    );
    await refreshConversations();
    return conversationFor(conversation.id) ?? conversation;
  }

  Future<void> loadMessages(
    String conversationId, {
    bool markRead = true,
  }) async {
    final page = await _authorized(
      (token) => _gateway.listMessages(
        origin: origin,
        accessToken: token,
        conversationId: conversationId,
        limit: 100,
      ),
    );
    final ordered = page.items.reversed.toList(growable: false);
    _messages[conversationId] = _deduplicateAndSort(ordered);
    _nextBeforeSequence[conversationId] = page.nextBeforeSequence;
    _hasMore[conversationId] = page.hasMore;
    _notify();
    if (markRead && ordered.isNotEmpty) {
      await markReadThrough(conversationId, ordered.last.sequence);
    }
  }

  Future<void> loadOlder(String conversationId) async {
    if (_hasMore[conversationId] != true) return;
    final before = _nextBeforeSequence[conversationId];
    if (before == null || before <= 0) return;
    final page = await _authorized(
      (token) => _gateway.listMessages(
        origin: origin,
        accessToken: token,
        conversationId: conversationId,
        beforeSequence: before,
        limit: 100,
      ),
    );
    final current = _messages[conversationId] ?? const <ChatMessage>[];
    _messages[conversationId] = _deduplicateAndSort([
      ...page.items.reversed,
      ...current,
    ]);
    _nextBeforeSequence[conversationId] = page.nextBeforeSequence;
    _hasMore[conversationId] = page.hasMore;
    _notify();
  }

  Future<void> sendText(
    String conversationId,
    String rawText, {
    String? replyToMessageId,
  }) async {
    final text = rawText;
    if (text.trim().isEmpty || text.runes.length > 4000) {
      throw const FormatException('消息内容需为 1-4000 个字符。');
    }
    final pending = PendingTextMessage(
      clientMessageId: _nextClientMessageId(),
      conversationId: conversationId,
      text: text,
      createdAt: DateTime.now().toUtc(),
      replyToMessageId: replyToMessageId,
    );
    _pending = [..._pending, pending];
    await _persistLocalState();
    _notify();
    await _tryDeliver(pending);
  }

  Future<void> sendImage(
    String conversationId, {
    required String mediaId,
    required int width,
    required int height,
    String? replyToMessageId,
  }) async {
    if (mediaId.trim().isEmpty ||
        width < 1 ||
        width > 20000 ||
        height < 1 ||
        height > 20000) {
      throw const FormatException('图片消息参数无效。');
    }
    final pending = PendingTextMessage(
      clientMessageId: _nextClientMessageId(),
      conversationId: conversationId,
      type: 'IMAGE',
      mediaId: mediaId.trim(),
      width: width,
      height: height,
      createdAt: DateTime.now().toUtc(),
      replyToMessageId: replyToMessageId,
    );
    _pending = [..._pending, pending];
    await _persistLocalState();
    _notify();
    await _tryDeliver(pending);
  }

  Future<void> sendMedia(
    String conversationId, {
    required String type,
    required String mediaId,
    String? posterMediaId,
    int? width,
    int? height,
    String? fileName,
    String? mimeType,
    int? sizeBytes,
    int? durationMs,
    String? replyToMessageId,
  }) async {
    final normalizedType = type.toUpperCase();
    if (!const {
          'GIF',
          'STICKER',
          'STICKER_PACK',
          'FILE',
          'VOICE',
          'VIDEO',
        }.contains(normalizedType) ||
        mediaId.trim().isEmpty) {
      throw const FormatException('媒体消息参数无效。');
    }
    if ((normalizedType == 'GIF' ||
            normalizedType == 'STICKER' ||
            normalizedType == 'STICKER_PACK') &&
        (width == null ||
            width < 1 ||
            width > 20000 ||
            height == null ||
            height < 1 ||
            height > 20000)) {
      throw const FormatException('图片表情尺寸无效。');
    }
    if (normalizedType == 'VOICE' &&
        (durationMs == null || durationMs < 250 || durationMs > 600000)) {
      throw const FormatException('语音时长无效。');
    }
    if (normalizedType == 'VIDEO' &&
        (posterMediaId == null ||
            posterMediaId.trim().isEmpty ||
            width == null ||
            width < 1 ||
            height == null ||
            height < 1 ||
            durationMs == null ||
            durationMs < 1)) {
      throw const FormatException('视频消息参数无效。');
    }
    final pending = PendingTextMessage(
      clientMessageId: _nextClientMessageId(),
      conversationId: conversationId,
      type: normalizedType,
      mediaId: mediaId.trim(),
      posterMediaId: posterMediaId?.trim(),
      width: width,
      height: height,
      fileName: fileName,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      durationMs: durationMs,
      createdAt: DateTime.now().toUtc(),
      replyToMessageId: replyToMessageId,
    );
    _pending = [..._pending, pending];
    await _persistLocalState();
    _notify();
    await _tryDeliver(pending);
  }

  Future<void> flushPending({bool includeFailed = false}) async {
    final snapshot = List<PendingTextMessage>.from(_pending);
    for (final item in snapshot) {
      if (!includeFailed && item.lastError != null) continue;
      await _tryDeliver(item);
    }
  }

  Future<void> retryPending(String clientMessageId) async {
    PendingTextMessage? target;
    _pending = _pending
        .map((item) {
          if (item.clientMessageId != clientMessageId) return item;
          target = PendingTextMessage(
            clientMessageId: item.clientMessageId,
            conversationId: item.conversationId,
            type: item.type,
            text: item.text,
            mediaId: item.mediaId,
            width: item.width,
            height: item.height,
            fileName: item.fileName,
            mimeType: item.mimeType,
            sizeBytes: item.sizeBytes,
            durationMs: item.durationMs,
            createdAt: item.createdAt,
            replyToMessageId: item.replyToMessageId,
          );
          return target!;
        })
        .toList(growable: false);
    await _persistLocalState();
    _notify();
    if (target != null) await _tryDeliver(target!);
  }

  Future<void> cancelPending(String clientMessageId) async {
    _pending = _pending
        .where((item) => item.clientMessageId != clientMessageId)
        .toList(growable: false);
    await _persistLocalState();
    _notify();
  }

  Future<void> retryFailed() async {
    _pending = _pending
        .map(
          (item) =>
              item.lastError == null ? item : item.copyWith(lastError: ''),
        )
        .map(
          (item) => item.lastError == ''
              ? PendingTextMessage(
                  clientMessageId: item.clientMessageId,
                  conversationId: item.conversationId,
                  type: item.type,
                  text: item.text,
                  mediaId: item.mediaId,
                  width: item.width,
                  height: item.height,
                  fileName: item.fileName,
                  mimeType: item.mimeType,
                  sizeBytes: item.sizeBytes,
                  durationMs: item.durationMs,
                  createdAt: item.createdAt,
                  replyToMessageId: item.replyToMessageId,
                )
              : item,
        )
        .toList(growable: false);
    await _persistLocalState();
    _notify();
    await flushPending(includeFailed: true);
  }

  Future<void> setPinned(ConversationItem conversation, bool isPinned) async {
    final updated = await _authorized(
      (token) => _gateway.updatePreferences(
        origin: origin,
        accessToken: token,
        conversationId: conversation.id,
        isPinned: isPinned,
      ),
    );
    _upsertConversation(updated);
  }

  Future<List<SavedMessageItem>> listSavedMessages() => _authorized(
    (token) => _gateway.listSavedMessages(origin: origin, accessToken: token),
  );

  Future<void> saveMessage(ChatMessage message) async {
    await _authorized(
      (token) => _gateway.saveMessage(
        origin: origin,
        accessToken: token,
        messageId: message.id,
      ),
    );
    final savedConversation = await ensureSavedConversation();
    if (_messages.containsKey(savedConversation.id)) {
      await loadMessages(savedConversation.id, markRead: false);
    }
    await refreshConversations();
  }

  Future<void> unsaveMessage(ChatMessage message) async {
    await _authorized(
      (token) => _gateway.unsaveMessage(
        origin: origin,
        accessToken: token,
        messageId: message.id,
      ),
    );
  }

  Future<List<PinnedMessageItem>> listPinnedMessages(String conversationId) =>
      _authorized(
        (token) => _gateway.listPinnedMessages(
          origin: origin,
          accessToken: token,
          conversationId: conversationId,
        ),
      );

  Future<void> pinMessage(ChatMessage message) async {
    await _authorized(
      (token) => _gateway.pinMessage(
        origin: origin,
        accessToken: token,
        messageId: message.id,
      ),
    );
  }

  Future<void> unpinMessage(ChatMessage message) async {
    await _authorized(
      (token) => _gateway.unpinMessage(
        origin: origin,
        accessToken: token,
        messageId: message.id,
      ),
    );
  }

  Future<ChatMessage> forwardMessage(
    ChatMessage message,
    String targetConversationId,
  ) async {
    final forwarded = await _authorized(
      (token) => _gateway.forwardMessage(
        origin: origin,
        accessToken: token,
        messageId: message.id,
        targetConversationId: targetConversationId,
        clientMessageId: _nextClientMessageId(),
      ),
    );
    if (_messages.containsKey(targetConversationId)) {
      await loadMessages(targetConversationId, markRead: false);
    }
    await refreshConversations();
    return forwarded;
  }

  Future<List<MessageSearchHit>> searchMessages(
    String query, {
    String? conversationId,
  }) => _authorized(
    (token) => _gateway.searchMessages(
      origin: origin,
      accessToken: token,
      query: query,
      conversationId: conversationId,
    ),
  );

  Future<void> hideConversation(ConversationItem conversation) async {
    await _authorized(
      (token) => _gateway.hideConversation(
        origin: origin,
        accessToken: token,
        conversationId: conversation.id,
      ),
    );
    _conversations = _conversations
        .where((item) => item.id != conversation.id)
        .toList(growable: false);
    if (_activeConversationId == conversation.id) {
      _activeConversationId = null;
    }
    _notify();
  }

  Future<void> setArchived(
    ConversationItem conversation,
    bool isArchived,
  ) async {
    final updated = await _authorized(
      (token) => _gateway.updatePreferences(
        origin: origin,
        accessToken: token,
        conversationId: conversation.id,
        isArchived: isArchived,
      ),
    );
    _upsertConversation(updated);
  }

  Future<void> muteUntil(ConversationItem conversation, DateTime until) async {
    final updated = await _authorized(
      (token) => _gateway.updatePreferences(
        origin: origin,
        accessToken: token,
        conversationId: conversation.id,
        mutedUntil: until,
      ),
    );
    _upsertConversation(updated);
  }

  Future<void> clearMute(ConversationItem conversation) async {
    final updated = await _authorized(
      (token) => _gateway.updatePreferences(
        origin: origin,
        accessToken: token,
        conversationId: conversation.id,
        clearMute: true,
      ),
    );
    _upsertConversation(updated);
  }

  Future<void> markReadThrough(String conversationId, int sequence) async {
    if (sequence <= 0) return;
    await _authorized(
      (token) => _gateway.markRead(
        origin: origin,
        accessToken: token,
        conversationId: conversationId,
        sequence: sequence,
      ),
    );
    await refreshConversations();
  }

  Future<ChatMessage> editMessage(ChatMessage message, String rawText) async {
    final text = rawText;
    if (text.trim().isEmpty || text.runes.length > 4000) {
      throw const FormatException('消息内容需为 1-4000 个字符。');
    }
    if (message.senderUserId != currentUserId ||
        message.type != 'TEXT' ||
        message.isRecalled) {
      throw const FormatException('这条消息当前不能编辑。');
    }
    try {
      final edited = await _authorized(
        (token) => _gateway.editMessage(
          origin: origin,
          accessToken: token,
          messageId: message.id,
          text: text,
          expectedEditVersion: message.editVersion,
        ),
      );
      final current =
          _messages[message.conversationId] ?? const <ChatMessage>[];
      _messages[message.conversationId] = _deduplicateAndSort([
        for (final item in current)
          if (item.id == edited.id) edited else item,
      ]);
      await refreshConversations();
      _errorMessage = null;
      _notify();
      return edited;
    } on MessagingApiException catch (error) {
      if (error.code == 'MESSAGE_EDIT_CONFLICT') {
        await loadMessages(message.conversationId, markRead: false);
        await refreshConversations();
        throw const FormatException('消息已在另一台设备更新，请确认最新内容后再编辑。');
      }
      if (error.code == 'MESSAGE_EDIT_FORBIDDEN') {
        throw const FormatException('这条消息已不可编辑。');
      }
      if (error.code == 'MESSAGE_EDIT_UNSUPPORTED') {
        throw const FormatException('当前消息类型暂不支持编辑。');
      }
      rethrow;
    }
  }

  Future<void> recall(ChatMessage message) async {
    await _authorized(
      (token) => _gateway.recallMessage(
        origin: origin,
        accessToken: token,
        messageId: message.id,
      ),
    );
    await loadMessages(message.conversationId, markRead: false);
    await syncNow();
  }

  Future<void> deleteLocally(ChatMessage message) async {
    await _authorized(
      (token) => _gateway.deleteMessageLocally(
        origin: origin,
        accessToken: token,
        messageId: message.id,
      ),
    );
    await loadMessages(message.conversationId, markRead: false);
    await syncNow();
  }

  Future<void> syncNow() async {
    if (_syncing || _disposed) return;
    _syncing = true;
    try {
      final previousConversations = <String, ConversationItem>{
        for (final conversation in _conversations)
          conversation.id: conversation,
      };
      final changedConversations = <String>{};
      var hasMore = true;
      while (hasMore) {
        final page = await _authorized(
          (token) => _gateway.sync(
            origin: origin,
            accessToken: token,
            cursor: _syncCursor,
          ),
        );
        for (final event in page.items) {
          final conversationId = event.conversationId;
          if (conversationId != null && conversationId.isNotEmpty) {
            changedConversations.add(conversationId);
          }
          if (event.type == 'RELATIONSHIP_BLOCKED_BY_PEER' &&
              !_relationshipController.isClosed) {
            _relationshipController.add(
              RelationshipNotice(
                type: event.type,
                peerUserId:
                    event.resourceId ??
                    (event.payload['blockedByUserId'] as String? ?? ''),
                message: '对方已将你拉黑',
              ),
            );
          }
        }
        if (page.nextCursor < _syncCursor) {
          throw StateError('服务端 Sync cursor 回退，已拒绝覆盖本地游标。');
        }
        _syncCursor = page.nextCursor;
        hasMore = page.hasMore;
        await _persistLocalState();
        if (page.items.isEmpty && page.hasMore) {
          throw StateError('服务端 Sync 返回空页但 hasMore=true。');
        }
      }
      var readStateChanged = false;
      await refreshConversations();
      _emitIncomingMessageNotices(previousConversations, changedConversations);
      for (final conversationId in changedConversations) {
        if (_messages.containsKey(conversationId)) {
          await loadMessages(conversationId, markRead: false);
          if (_activeConversationId == conversationId) {
            final messages = _messages[conversationId] ?? const <ChatMessage>[];
            if (messages.isNotEmpty) {
              await _authorized(
                (token) => _gateway.markRead(
                  origin: origin,
                  accessToken: token,
                  conversationId: conversationId,
                  sequence: messages.last.sequence,
                ),
              );
              readStateChanged = true;
            }
          }
        }
      }
      if (readStateChanged) {
        await refreshConversations();
      }
      _errorMessage = null;
    } catch (error) {
      _setError(_friendlyError(error));
    } finally {
      _syncing = false;
      _notify();
    }
  }

  Future<void> _tryDeliver(PendingTextMessage pending) async {
    if (!_pending.any(
      (item) => item.clientMessageId == pending.clientMessageId,
    )) {
      return;
    }
    try {
      if (pending.isImage) {
        final mediaId = pending.mediaId;
        final width = pending.width;
        final height = pending.height;
        if (mediaId == null || width == null || height == null) {
          _markPendingFailed(pending.clientMessageId, '图片消息数据不完整，无法继续发送。');
          await _persistLocalState();
          _notify();
          return;
        }
        await _authorized(
          (token) => _gateway.sendImage(
            origin: origin,
            accessToken: token,
            conversationId: pending.conversationId,
            clientMessageId: pending.clientMessageId,
            mediaId: mediaId,
            width: width,
            height: height,
            replyToMessageId: pending.replyToMessageId,
          ),
        );
      } else if (pending.isMedia) {
        final mediaId = pending.mediaId;
        if (mediaId == null) {
          _markPendingFailed(pending.clientMessageId, '媒体消息数据不完整，无法继续发送。');
          await _persistLocalState();
          _notify();
          return;
        }
        await _authorized(
          (token) => _gateway.sendMedia(
            origin: origin,
            accessToken: token,
            conversationId: pending.conversationId,
            clientMessageId: pending.clientMessageId,
            type: pending.type,
            mediaId: mediaId,
            posterMediaId: pending.posterMediaId,
            width: pending.width,
            height: pending.height,
            durationMs: pending.durationMs,
            replyToMessageId: pending.replyToMessageId,
          ),
        );
      } else {
        await _authorized(
          (token) => _gateway.sendText(
            origin: origin,
            accessToken: token,
            conversationId: pending.conversationId,
            clientMessageId: pending.clientMessageId,
            text: pending.text,
            replyToMessageId: pending.replyToMessageId,
          ),
        );
      }
      _pending = _pending
          .where((item) => item.clientMessageId != pending.clientMessageId)
          .toList(growable: false);
      await _persistLocalState();
      await loadMessages(pending.conversationId, markRead: false);
      await refreshConversations();
      _errorMessage = null;
      _notify();
    } on MessagingApiException catch (error) {
      if (error.statusCode == 401 && onUnauthorized != null) {
        // _authorized already attempted one single-flight refresh. If the
        // retry still reaches here, keep the durable pending message instead
        // of recursively refreshing the same expired session again.
        _setError('登录会话刷新失败，这条消息已保留，连接恢复后会自动重试。');
        return;
      }
      if (error.isRetryable) {
        _setError('消息暂未送达，将在恢复连接后自动重试：${error.message}');
        return;
      }
      final friendly = _friendlyMessagingRejection(error);
      _markPendingFailed(pending.clientMessageId, friendly);
      await _persistLocalState();
      _setError(friendly);
    } catch (error) {
      _setError('网络不可用，消息已保留在待发送队列：${_friendlyError(error)}');
    }
  }

  void _markPendingFailed(String clientMessageId, String error) {
    _pending = _pending
        .map(
          (item) => item.clientMessageId == clientMessageId
              ? item.copyWith(lastError: error)
              : item,
        )
        .toList(growable: false);
  }

  void _emitIncomingMessageNotices(
    Map<String, ConversationItem> previous,
    Set<String> changedConversations,
  ) {
    for (final conversationId in changedConversations) {
      final before = previous[conversationId];
      final after = conversationFor(conversationId);
      if (after == null) continue;
      if (after.unreadCount <= (before?.unreadCount ?? 0)) continue;
      final message = after.lastMessage;
      if (message == null ||
          message.isRecalled ||
          message.senderUserId == currentUserId) {
        continue;
      }
      final peer = after.peer;
      final senderName = after.type == 'GROUP'
          ? (after.group?.name ?? '群聊')
          : (peer?.displayName ?? '新消息');
      final preview = messageNotificationPreview(
        messageType: message.type,
        text: message.content?.text ?? '',
      );
      if (!_incomingMessageController.isClosed) {
        _incomingMessageController.add(
          IncomingMessageNotice(
            conversationId: conversationId,
            senderUserId: message.senderUserId,
            senderName: senderName,
            messageType: message.type,
            preview: preview,
            unreadCount: after.unreadCount,
            mentionedCurrentUser:
                message.content?.mentionsUser(currentUserId) == true,
            muted:
                after.preferences.mutedUntil?.isAfter(DateTime.now().toUtc()) ==
                true,
          ),
        );
      }
    }
  }

  void _upsertConversation(ConversationItem updated) {
    final next = <ConversationItem>[
      for (final conversation in _conversations)
        if (conversation.id != updated.id) conversation,
      updated,
    ];
    next.sort((a, b) {
      if (a.preferences.isArchived != b.preferences.isArchived) {
        return a.preferences.isArchived ? 1 : -1;
      }
      if (a.preferences.isPinned != b.preferences.isPinned) {
        return a.preferences.isPinned ? -1 : 1;
      }
      final updatedAt = b.updatedAt.compareTo(a.updatedAt);
      if (updatedAt != 0) return updatedAt;
      return b.id.compareTo(a.id);
    });
    _conversations = List.unmodifiable(next);
    _notify();
  }

  List<ChatMessage> _deduplicateAndSort(Iterable<ChatMessage> input) {
    final byId = <String, ChatMessage>{};
    for (final message in input) {
      byId[message.id] = message;
    }
    final result = byId.values.toList();
    result.sort((a, b) => a.sequence.compareTo(b.sequence));
    return result;
  }

  String _nextClientMessageId() {
    _clientCounter++;
    final micros = DateTime.now().microsecondsSinceEpoch;
    final compactDevice = deviceId.replaceAll('-', '');
    final suffix = compactDevice.length > 16
        ? compactDevice.substring(compactDevice.length - 16)
        : compactDevice;
    return 'dd-$suffix-$micros-$_clientCounter';
  }

  Future<void> _persistLocalState() => _localStore.save(
    syncCursor: _syncCursor,
    pending: _pending,
    drafts: _drafts,
    recentEmoji: _recentEmoji,
    stickerPanelTabKey: _stickerPanelTabKey,
    heardVoiceMessageIds: _heardVoiceMessageIds,
  );

  String _friendlyMessagingRejection(MessagingApiException error) {
    return switch (error.code) {
      'MESSAGING_BLOCKED' => '消息未发送：你或对方已将另一方加入黑名单。',
      'MESSAGING_FORBIDDEN' => '消息未发送：当前关系已被拉黑或会话不可写。',
      'MESSAGING_CONFLICT' => '消息未发送：会话状态已变化，请同步后重试。',
      'INVALID_REQUEST' => '消息未发送：消息内容或引用目标已失效。',
      _ => '消息未发送：${error.message}',
    };
  }

  String _friendlyError(Object error) {
    if (error is MessagingApiException) {
      if (error.statusCode == 401) return '登录会话已失效，正在尝试自动恢复。';
      return error.message;
    }
    if (error is FormatException) return error.message;
    return error.toString();
  }

  void _setBusy(bool value) {
    _busy = value;
    _notify();
  }

  void _setError(String message) {
    _errorMessage = message;
    unawaited(ClientLog.error('Messaging: $message'));
    _notify();
  }

  void clearError() {
    _errorMessage = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_eventSubscription?.cancel());
    unawaited(_stateSubscription?.cancel());
    unawaited(_incomingMessageController.close());
    unawaited(_relationshipController.close());
    unawaited(_eventAvailableReasonController.close());
    if (_ownsRealtime) unawaited(_realtime.dispose());
    if (_ownsMediaTransfers) _mediaTransfers.dispose();
    _transferMediaApi.close();
    if (_ownsGateway) _gateway.close();
    super.dispose();
  }
}

final class RelationshipNotice {
  const RelationshipNotice({
    required this.type,
    required this.peerUserId,
    required this.message,
  });

  final String type;
  final String peerUserId;
  final String message;
}

final class IncomingMessageNotice {
  const IncomingMessageNotice({
    required this.conversationId,
    required this.senderUserId,
    required this.senderName,
    required this.messageType,
    required this.preview,
    required this.unreadCount,
    required this.mentionedCurrentUser,
    required this.muted,
  });

  final String conversationId;
  final String senderUserId;
  final String senderName;
  final String messageType;
  final String preview;
  final int unreadCount;
  final bool mentionedCurrentUser;
  final bool muted;
}
