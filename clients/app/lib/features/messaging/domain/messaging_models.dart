final class MessagingUserPreview {
  const MessagingUserPreview({
    required this.id,
    required this.handle,
    required this.displayName,
  });

  factory MessagingUserPreview.fromJson(Map<String, dynamic> json) =>
      MessagingUserPreview(
        id: _requiredString(json, 'id'),
        handle: _requiredString(json, 'handle'),
        displayName: _requiredString(json, 'displayName'),
      );

  final String id;
  final String handle;
  final String displayName;
}

final class TextMessageContent {
  const TextMessageContent({required this.text});

  factory TextMessageContent.fromJson(Map<String, dynamic> json) =>
      TextMessageContent(
        text: json['text'] is String ? json['text'] as String : '',
      );

  final String text;
}

final class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.sequence,
    required this.senderUserId,
    required this.senderDeviceId,
    required this.clientMessageId,
    required this.type,
    required this.createdAt,
    this.content,
    this.replyToMessageId,
    this.recalledAt,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final rawContent = json['content'];
    return ChatMessage(
      id: _requiredString(json, 'id'),
      conversationId: _requiredString(json, 'conversationId'),
      sequence: _requiredInt(json, 'sequence'),
      senderUserId: _requiredString(json, 'senderUserId'),
      senderDeviceId: _requiredString(json, 'senderDeviceId'),
      clientMessageId: _requiredString(json, 'clientMessageId'),
      type: _requiredString(json, 'type'),
      content: rawContent is Map<String, dynamic>
          ? TextMessageContent.fromJson(rawContent)
          : null,
      replyToMessageId: json['replyToMessageId'] is String
          ? json['replyToMessageId'] as String
          : null,
      createdAt: _requiredDate(json, 'createdAt'),
      recalledAt: _optionalDate(json['recalledAt']),
    );
  }

  final String id;
  final String conversationId;
  final int sequence;
  final String senderUserId;
  final String senderDeviceId;
  final String clientMessageId;
  final String type;
  final TextMessageContent? content;
  final String? replyToMessageId;
  final DateTime createdAt;
  final DateTime? recalledAt;

  bool get isRecalled => recalledAt != null;
}

final class ConversationPreferences {
  const ConversationPreferences({required this.isPinned, this.mutedUntil});

  factory ConversationPreferences.fromJson(Map<String, dynamic> json) =>
      ConversationPreferences(
        isPinned: json['isPinned'] == true,
        mutedUntil: _optionalDate(json['mutedUntil']),
      );

  final bool isPinned;
  final DateTime? mutedUntil;
}

final class ConversationItem {
  const ConversationItem({
    required this.id,
    required this.type,
    required this.lastSequence,
    required this.lastReadSequence,
    required this.unreadCount,
    this.peerLastReadSequence,
    required this.preferences,
    required this.createdAt,
    required this.updatedAt,
    this.peer,
    this.lastMessage,
  });

  factory ConversationItem.fromJson(Map<String, dynamic> json) {
    final rawPeer = json['peer'];
    final rawLastMessage = json['lastMessage'];
    final rawPreferences = json['preferences'];
    if (rawPreferences is! Map<String, dynamic>) {
      throw const FormatException('Conversation preferences are malformed');
    }
    return ConversationItem(
      id: _requiredString(json, 'id'),
      type: _requiredString(json, 'type'),
      peer: rawPeer is Map<String, dynamic>
          ? MessagingUserPreview.fromJson(rawPeer)
          : null,
      lastSequence: _requiredInt(json, 'lastSequence'),
      lastReadSequence: _requiredInt(json, 'lastReadSequence'),
      peerLastReadSequence: json['peerLastReadSequence'] is int
          ? json['peerLastReadSequence'] as int
          : null,
      unreadCount: _requiredInt(json, 'unreadCount'),
      lastMessage: rawLastMessage is Map<String, dynamic>
          ? ChatMessage.fromJson(rawLastMessage)
          : null,
      preferences: ConversationPreferences.fromJson(rawPreferences),
      createdAt: _requiredDate(json, 'createdAt'),
      updatedAt: _requiredDate(json, 'updatedAt'),
    );
  }

  final String id;
  final String type;
  final MessagingUserPreview? peer;
  final int lastSequence;
  final int lastReadSequence;
  final int? peerLastReadSequence;
  final int unreadCount;
  final ChatMessage? lastMessage;
  final ConversationPreferences preferences;
  final DateTime createdAt;
  final DateTime updatedAt;
}

final class MessagePage {
  const MessagePage({
    required this.items,
    required this.hasMore,
    this.nextBeforeSequence,
  });

  factory MessagePage.fromJson(Map<String, dynamic> json) {
    final items = json['items'];
    if (items is! List) {
      throw const FormatException('Message page items are malformed');
    }
    return MessagePage(
      items: items
          .map((item) => ChatMessage.fromJson(item as Map<String, dynamic>))
          .toList(growable: false),
      hasMore: json['hasMore'] == true,
      nextBeforeSequence: json['nextBeforeSequence'] is int
          ? json['nextBeforeSequence'] as int
          : null,
    );
  }

  final List<ChatMessage> items;
  final bool hasMore;
  final int? nextBeforeSequence;
}

final class SyncEventItem {
  const SyncEventItem({
    required this.eventId,
    required this.cursor,
    required this.type,
    required this.occurredAt,
    this.resourceId,
    this.conversationId,
    this.sequence,
  });

  factory SyncEventItem.fromJson(Map<String, dynamic> json) => SyncEventItem(
    eventId: _requiredString(json, 'eventId'),
    cursor: _requiredInt(json, 'cursor'),
    type: _requiredString(json, 'type'),
    resourceId: json['resourceId'] is String
        ? json['resourceId'] as String
        : null,
    conversationId: json['conversationId'] is String
        ? json['conversationId'] as String
        : null,
    sequence: json['sequence'] is int ? json['sequence'] as int : null,
    occurredAt: _requiredDate(json, 'occurredAt'),
  );

  final String eventId;
  final int cursor;
  final String type;
  final String? resourceId;
  final String? conversationId;
  final int? sequence;
  final DateTime occurredAt;
}

final class SyncPage {
  const SyncPage({
    required this.items,
    required this.nextCursor,
    required this.hasMore,
  });

  factory SyncPage.fromJson(Map<String, dynamic> json) {
    final items = json['items'];
    if (items is! List) {
      throw const FormatException('Sync items are malformed');
    }
    return SyncPage(
      items: items
          .map((item) => SyncEventItem.fromJson(item as Map<String, dynamic>))
          .toList(growable: false),
      nextCursor: _requiredInt(json, 'nextCursor'),
      hasMore: json['hasMore'] == true,
    );
  }

  final List<SyncEventItem> items;
  final int nextCursor;
  final bool hasMore;
}

final class PendingTextMessage {
  const PendingTextMessage({
    required this.clientMessageId,
    required this.conversationId,
    required this.text,
    required this.createdAt,
    this.replyToMessageId,
    this.lastError,
  });

  factory PendingTextMessage.fromJson(Map<String, dynamic> json) =>
      PendingTextMessage(
        clientMessageId: _requiredString(json, 'clientMessageId'),
        conversationId: _requiredString(json, 'conversationId'),
        text: _requiredString(json, 'text'),
        createdAt: _requiredDate(json, 'createdAt'),
        replyToMessageId: json['replyToMessageId'] is String
            ? json['replyToMessageId'] as String
            : null,
        lastError: json['lastError'] is String
            ? json['lastError'] as String
            : null,
      );

  final String clientMessageId;
  final String conversationId;
  final String text;
  final DateTime createdAt;
  final String? replyToMessageId;
  final String? lastError;

  PendingTextMessage copyWith({String? lastError}) => PendingTextMessage(
    clientMessageId: clientMessageId,
    conversationId: conversationId,
    text: text,
    createdAt: createdAt,
    replyToMessageId: replyToMessageId,
    lastError: lastError,
  );

  Map<String, dynamic> toJson() => {
    'clientMessageId': clientMessageId,
    'conversationId': conversationId,
    'text': text,
    'createdAt': createdAt.toUtc().toIso8601String(),
    if (replyToMessageId != null) 'replyToMessageId': replyToMessageId,
    if (lastError != null) 'lastError': lastError,
  };
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value;
}

int _requiredInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int) throw FormatException('$key must be an integer');
  return value;
}

DateTime _requiredDate(Map<String, dynamic> json, String key) {
  final result = _optionalDate(json[key]);
  if (result == null) throw FormatException('$key must be an ISO date-time');
  return result;
}

DateTime? _optionalDate(Object? raw) {
  if (raw is! String || raw.trim().isEmpty) return null;
  return DateTime.tryParse(raw)?.toUtc();
}
