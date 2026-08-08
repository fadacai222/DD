import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:realtime_poc/realtime_poc.dart';

import '../data/messaging_api_client.dart';
import '../data/messaging_local_store.dart';
import '../domain/messaging_models.dart';

final class MessagingCoordinator extends ChangeNotifier {
  MessagingCoordinator({
    required this.origin,
    required this.accessToken,
    required this.currentUserId,
    required this.deviceId,
    MessagingGateway? gateway,
    MessagingLocalStore? localStore,
    RealtimeClient? realtimeClient,
  }) : _gateway = gateway ?? MessagingApiClient(),
       _ownsGateway = gateway == null,
       _localStore =
           localStore ??
           SecureMessagingLocalStore(userId: currentUserId, deviceId: deviceId),
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
  final String accessToken;
  final String currentUserId;
  final String deviceId;
  final MessagingGateway _gateway;
  final bool _ownsGateway;
  final MessagingLocalStore _localStore;
  final RealtimeClient _realtime;
  final bool _ownsRealtime;

  final Map<String, List<ChatMessage>> _messages = {};
  final Map<String, int?> _nextBeforeSequence = {};
  final Map<String, bool> _hasMore = {};
  List<ConversationItem> _conversations = const [];
  List<PendingTextMessage> _pending = const [];
  Map<String, String> _drafts = const {};
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

  List<ChatMessage> messagesFor(String conversationId) =>
      List.unmodifiable(_messages[conversationId] ?? const []);

  ConversationItem? conversationFor(String conversationId) {
    for (final conversation in _conversations) {
      if (conversation.id == conversationId) return conversation;
    }
    return null;
  }

  List<PendingTextMessage> pendingFor(String conversationId) => _pending
      .where((item) => item.conversationId == conversationId)
      .toList(growable: false);

  bool canLoadOlder(String conversationId) => _hasMore[conversationId] == true;
  String draftFor(String conversationId) => _drafts[conversationId] ?? '';

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
      final local = await _localStore.load();
      _syncCursor = local.syncCursor;
      _pending = local.pending;
      _drafts = Map.unmodifiable(local.drafts);
      _eventSubscription = _realtime.events.listen((event) {
        if (event.type == 'event_available') {
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
    final items = await _gateway.listConversations(
      origin: origin,
      accessToken: accessToken,
    );
    _conversations = items;
    _notify();
  }

  Future<ConversationItem> ensureDirectConversation(String userId) async {
    final conversation = await _gateway.ensureDirectConversation(
      origin: origin,
      accessToken: accessToken,
      userId: userId,
    );
    await refreshConversations();
    return conversation;
  }

  Future<void> loadMessages(
    String conversationId, {
    bool markRead = true,
  }) async {
    final page = await _gateway.listMessages(
      origin: origin,
      accessToken: accessToken,
      conversationId: conversationId,
      limit: 100,
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
    final page = await _gateway.listMessages(
      origin: origin,
      accessToken: accessToken,
      conversationId: conversationId,
      beforeSequence: before,
      limit: 100,
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
            text: item.text,
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
                  text: item.text,
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
    final updated = await _gateway.updatePreferences(
      origin: origin,
      accessToken: accessToken,
      conversationId: conversation.id,
      isPinned: isPinned,
    );
    _upsertConversation(updated);
  }

  Future<void> muteUntil(ConversationItem conversation, DateTime until) async {
    final updated = await _gateway.updatePreferences(
      origin: origin,
      accessToken: accessToken,
      conversationId: conversation.id,
      mutedUntil: until,
    );
    _upsertConversation(updated);
  }

  Future<void> clearMute(ConversationItem conversation) async {
    final updated = await _gateway.updatePreferences(
      origin: origin,
      accessToken: accessToken,
      conversationId: conversation.id,
      clearMute: true,
    );
    _upsertConversation(updated);
  }

  Future<void> markReadThrough(String conversationId, int sequence) async {
    if (sequence <= 0) return;
    await _gateway.markRead(
      origin: origin,
      accessToken: accessToken,
      conversationId: conversationId,
      sequence: sequence,
    );
    await refreshConversations();
  }

  Future<void> recall(ChatMessage message) async {
    await _gateway.recallMessage(
      origin: origin,
      accessToken: accessToken,
      messageId: message.id,
    );
    await loadMessages(message.conversationId, markRead: false);
    await syncNow();
  }

  Future<void> deleteLocally(ChatMessage message) async {
    await _gateway.deleteMessageLocally(
      origin: origin,
      accessToken: accessToken,
      messageId: message.id,
    );
    await loadMessages(message.conversationId, markRead: false);
    await syncNow();
  }

  Future<void> syncNow() async {
    if (_syncing || _disposed) return;
    _syncing = true;
    try {
      final changedConversations = <String>{};
      var hasMore = true;
      while (hasMore) {
        final page = await _gateway.sync(
          origin: origin,
          accessToken: accessToken,
          cursor: _syncCursor,
        );
        for (final event in page.items) {
          final conversationId = event.conversationId;
          if (conversationId != null && conversationId.isNotEmpty) {
            changedConversations.add(conversationId);
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
      for (final conversationId in changedConversations) {
        if (_messages.containsKey(conversationId)) {
          await loadMessages(conversationId, markRead: false);
          if (_activeConversationId == conversationId) {
            final messages = _messages[conversationId] ?? const <ChatMessage>[];
            if (messages.isNotEmpty) {
              await _gateway.markRead(
                origin: origin,
                accessToken: accessToken,
                conversationId: conversationId,
                sequence: messages.last.sequence,
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
      await _gateway.sendText(
        origin: origin,
        accessToken: accessToken,
        conversationId: pending.conversationId,
        clientMessageId: pending.clientMessageId,
        text: pending.text,
        replyToMessageId: pending.replyToMessageId,
      );
      _pending = _pending
          .where((item) => item.clientMessageId != pending.clientMessageId)
          .toList(growable: false);
      await _persistLocalState();
      await loadMessages(pending.conversationId, markRead: false);
      await refreshConversations();
      _errorMessage = null;
      _notify();
    } on MessagingApiException catch (error) {
      if (error.isRetryable) {
        _setError('消息暂未送达，将在恢复连接后自动重试：${error.message}');
        return;
      }
      _markPendingFailed(pending.clientMessageId, error.message);
      await _persistLocalState();
      _setError('消息发送被服务端拒绝：${error.message}');
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

  void _upsertConversation(ConversationItem updated) {
    final next = <ConversationItem>[
      for (final conversation in _conversations)
        if (conversation.id != updated.id) conversation,
      updated,
    ];
    next.sort((a, b) {
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
  );

  String _friendlyError(Object error) {
    if (error is MessagingApiException) return error.message;
    if (error is FormatException) return error.message;
    return error.toString();
  }

  void _setBusy(bool value) {
    _busy = value;
    _notify();
  }

  void _setError(String message) {
    _errorMessage = message;
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
    if (_ownsRealtime) unawaited(_realtime.dispose());
    if (_ownsGateway) _gateway.close();
    super.dispose();
  }
}
