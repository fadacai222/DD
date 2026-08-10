import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../auth/data/auth_api_client.dart' show normalizeAuthOrigin;
import '../../auth/data/auth_http_client.dart';
import '../domain/messaging_models.dart';

abstract interface class MessagingGateway {
  Future<List<ConversationItem>> listConversations({
    required Uri origin,
    required String accessToken,
  });

  Future<ConversationItem> getConversation({
    required Uri origin,
    required String accessToken,
    required String conversationId,
  });

  Future<ConversationItem> ensureDirectConversation({
    required Uri origin,
    required String accessToken,
    required String userId,
  });

  Future<ConversationItem> ensureSavedConversation({
    required Uri origin,
    required String accessToken,
  });

  Future<MessagePage> listMessages({
    required Uri origin,
    required String accessToken,
    required String conversationId,
    int beforeSequence = 0,
    int limit = 50,
  });

  Future<ChatMessage> sendText({
    required Uri origin,
    required String accessToken,
    required String conversationId,
    required String clientMessageId,
    required String text,
    String? replyToMessageId,
  });

  Future<ChatMessage> sendImage({
    required Uri origin,
    required String accessToken,
    required String conversationId,
    required String clientMessageId,
    required String mediaId,
    required int width,
    required int height,
    String? replyToMessageId,
  });

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
  });

  Future<ConversationItem> updatePreferences({
    required Uri origin,
    required String accessToken,
    required String conversationId,
    bool? isPinned,
    DateTime? mutedUntil,
    bool clearMute = false,
    bool? isArchived,
  });

  Future<void> hideConversation({
    required Uri origin,
    required String accessToken,
    required String conversationId,
  });

  Future<int> markRead({
    required Uri origin,
    required String accessToken,
    required String conversationId,
    required int sequence,
  });

  Future<ChatMessage> editMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
    required String text,
    required int expectedEditVersion,
  });

  Future<ChatMessage> recallMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
  });

  Future<void> deleteMessageLocally({
    required Uri origin,
    required String accessToken,
    required String messageId,
  });

  Future<List<SavedMessageItem>> listSavedMessages({
    required Uri origin,
    required String accessToken,
  });

  Future<void> saveMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
  });

  Future<void> unsaveMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
  });

  Future<List<PinnedMessageItem>> listPinnedMessages({
    required Uri origin,
    required String accessToken,
    required String conversationId,
  });

  Future<void> pinMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
  });

  Future<void> unpinMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
  });

  Future<ChatMessage> forwardMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
    required String targetConversationId,
    required String clientMessageId,
  });

  Future<List<MessageSearchHit>> searchMessages({
    required Uri origin,
    required String accessToken,
    required String query,
    String? conversationId,
  });

  Future<SyncPage> sync({
    required Uri origin,
    required String accessToken,
    required int cursor,
    int limit = 200,
  });

  void close();
}

final class MessagingApiException implements Exception {
  const MessagingApiException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.requestId,
  });

  final int statusCode;
  final String code;
  final String message;
  final String? requestId;

  bool get isRetryable =>
      statusCode == 408 || statusCode == 429 || statusCode >= 500;

  @override
  String toString() => '$message${requestId == null ? '' : ' · $requestId'}';
}

final class MessagingApiClient implements MessagingGateway {
  MessagingApiClient({http.Client? httpClient})
    : _client = httpClient ?? createAuthHttpClient();

  final http.Client _client;

  @override
  Future<List<ConversationItem>> listConversations({
    required Uri origin,
    required String accessToken,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/conversations?limit=100',
      accessToken,
    );
    final data = _decodeData(response, const {200});
    final items = data['items'];
    if (items is! List) {
      throw const FormatException('Conversation list is malformed');
    }
    return items
        .map((item) => ConversationItem.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  @override
  Future<ConversationItem> getConversation({
    required Uri origin,
    required String accessToken,
    required String conversationId,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/conversations/$conversationId',
      accessToken,
    );
    return ConversationItem.fromJson(_decodeData(response, const {200}));
  }

  @override
  Future<ConversationItem> ensureDirectConversation({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/conversations/direct',
      accessToken,
      method: 'POST',
      body: {'userId': userId},
    );
    return ConversationItem.fromJson(_decodeData(response, const {200}));
  }

  @override
  Future<ConversationItem> ensureSavedConversation({
    required Uri origin,
    required String accessToken,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/saved-messages/conversation',
      accessToken,
      method: 'PUT',
    );
    return ConversationItem.fromJson(_decodeData(response, const {200}));
  }

  @override
  Future<MessagePage> listMessages({
    required Uri origin,
    required String accessToken,
    required String conversationId,
    int beforeSequence = 0,
    int limit = 50,
  }) async {
    final query = Uri(
      queryParameters: {
        if (beforeSequence > 0) 'beforeSequence': '$beforeSequence',
        'limit': '$limit',
      },
    ).query;
    final response = await _authorized(
      origin,
      '/api/v1/conversations/$conversationId/messages?$query',
      accessToken,
    );
    return MessagePage.fromJson(_decodeData(response, const {200}));
  }

  @override
  Future<ChatMessage> sendText({
    required Uri origin,
    required String accessToken,
    required String conversationId,
    required String clientMessageId,
    required String text,
    String? replyToMessageId,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/conversations/$conversationId/messages',
      accessToken,
      method: 'POST',
      body: {
        'clientMessageId': clientMessageId,
        'type': 'TEXT',
        'content': {'text': text},
        'replyToMessageId': ?replyToMessageId,
      },
    );
    return ChatMessage.fromJson(_decodeData(response, const {201}));
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
    final response = await _authorized(
      origin,
      '/api/v1/conversations/$conversationId/messages',
      accessToken,
      method: 'POST',
      body: {
        'clientMessageId': clientMessageId,
        'type': 'IMAGE',
        'content': {'mediaId': mediaId, 'width': width, 'height': height},
        'replyToMessageId': ?replyToMessageId,
      },
    );
    return ChatMessage.fromJson(_decodeData(response, const {201}));
  }

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
  }) async {
    final normalizedType = type.toUpperCase();
    if (!const {
      'GIF',
      'STICKER',
      'FILE',
      'VOICE',
      'VIDEO',
    }.contains(normalizedType)) {
      throw const FormatException('Unsupported media message type');
    }
    final response = await _authorized(
      origin,
      '/api/v1/conversations/$conversationId/messages',
      accessToken,
      method: 'POST',
      body: {
        'clientMessageId': clientMessageId,
        'type': normalizedType,
        'content': {
          'mediaId': mediaId,
          'posterMediaId': ?posterMediaId,
          'width': ?width,
          'height': ?height,
          'durationMs': ?durationMs,
        },
        'replyToMessageId': ?replyToMessageId,
      },
    );
    return ChatMessage.fromJson(_decodeData(response, const {201}));
  }

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
    if (isPinned == null &&
        mutedUntil == null &&
        !clearMute &&
        isArchived == null) {
      throw const FormatException(
        'At least one conversation preference is required',
      );
    }
    final response = await _authorized(
      origin,
      '/api/v1/conversations/$conversationId/preferences',
      accessToken,
      method: 'PATCH',
      body: {
        'isPinned': ?isPinned,
        'mutedUntil': ?mutedUntil?.toUtc().toIso8601String(),
        if (clearMute) 'clearMute': true,
        'isArchived': ?isArchived,
      },
    );
    return ConversationItem.fromJson(_decodeData(response, const {200}));
  }

  @override
  Future<void> hideConversation({
    required Uri origin,
    required String accessToken,
    required String conversationId,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/conversations/$conversationId',
      accessToken,
      method: 'DELETE',
    );
    if (response.statusCode != 204) {
      _decodeData(response, const {204});
    }
  }

  @override
  Future<int> markRead({
    required Uri origin,
    required String accessToken,
    required String conversationId,
    required int sequence,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/conversations/$conversationId/read',
      accessToken,
      method: 'POST',
      body: {'sequence': sequence},
    );
    final data = _decodeData(response, const {200});
    final value = data['lastReadSequence'];
    if (value is! int) {
      throw const FormatException('Read sequence is malformed');
    }
    return value;
  }

  @override
  Future<ChatMessage> editMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
    required String text,
    required int expectedEditVersion,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/messages/$messageId',
      accessToken,
      method: 'PATCH',
      body: {'text': text, 'expectedEditVersion': expectedEditVersion},
    );
    return ChatMessage.fromJson(_decodeData(response, const {200}));
  }

  @override
  Future<ChatMessage> recallMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/messages/$messageId/recall',
      accessToken,
      method: 'POST',
      body: const {},
    );
    return ChatMessage.fromJson(_decodeData(response, const {200}));
  }

  @override
  Future<void> deleteMessageLocally({
    required Uri origin,
    required String accessToken,
    required String messageId,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/messages/$messageId/local',
      accessToken,
      method: 'DELETE',
    );
    _decodeData(response, const {200});
  }

  @override
  Future<List<SavedMessageItem>> listSavedMessages({
    required Uri origin,
    required String accessToken,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/saved-messages?limit=100',
      accessToken,
    );
    final data = _decodeData(response, const {200});
    final items = data['items'];
    if (items is! List) {
      throw const FormatException('Saved message list is malformed');
    }
    return items
        .map((item) => SavedMessageItem.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  @override
  Future<void> saveMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/messages/$messageId/save',
      accessToken,
      method: 'PUT',
    );
    _decodeData(response, const {200});
  }

  @override
  Future<void> unsaveMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/messages/$messageId/save',
      accessToken,
      method: 'DELETE',
    );
    _decodeData(response, const {200});
  }

  @override
  Future<List<PinnedMessageItem>> listPinnedMessages({
    required Uri origin,
    required String accessToken,
    required String conversationId,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/conversations/$conversationId/pinned-messages?limit=100',
      accessToken,
    );
    final data = _decodeData(response, const {200});
    final items = data['items'];
    if (items is! List) {
      throw const FormatException('Pinned message list is malformed');
    }
    return items
        .map((item) => PinnedMessageItem.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  @override
  Future<void> pinMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/messages/$messageId/pin',
      accessToken,
      method: 'PUT',
    );
    _decodeData(response, const {200});
  }

  @override
  Future<void> unpinMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/messages/$messageId/pin',
      accessToken,
      method: 'DELETE',
    );
    _decodeData(response, const {200});
  }

  @override
  Future<ChatMessage> forwardMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
    required String targetConversationId,
    required String clientMessageId,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/messages/$messageId/forward',
      accessToken,
      method: 'POST',
      body: {
        'targetConversationId': targetConversationId,
        'clientMessageId': clientMessageId,
      },
    );
    return ChatMessage.fromJson(_decodeData(response, const {201}));
  }

  @override
  Future<List<MessageSearchHit>> searchMessages({
    required Uri origin,
    required String accessToken,
    required String query,
    String? conversationId,
  }) async {
    final encoded = Uri(
      queryParameters: {
        'q': query,
        'limit': '100',
        if (conversationId != null && conversationId.isNotEmpty)
          'conversationId': conversationId,
      },
    ).query;
    final response = await _authorized(
      origin,
      '/api/v1/messages/search?$encoded',
      accessToken,
    );
    final data = _decodeData(response, const {200});
    final items = data['items'];
    if (items is! List) {
      throw const FormatException('Message search result is malformed');
    }
    return items
        .map((item) => MessageSearchHit.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  @override
  Future<SyncPage> sync({
    required Uri origin,
    required String accessToken,
    required int cursor,
    int limit = 200,
  }) async {
    final query = Uri(
      queryParameters: {'cursor': '$cursor', 'limit': '$limit'},
    ).query;
    final response = await _authorized(
      origin,
      '/api/v1/sync?$query',
      accessToken,
    );
    return SyncPage.fromJson(_decodeData(response, const {200}));
  }

  Future<http.Response> _authorized(
    Uri rawOrigin,
    String path,
    String accessToken, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) {
    final request = http.Request(
      method,
      normalizeAuthOrigin(rawOrigin).resolve(path),
    );
    request.headers.addAll({
      'Accept': 'application/json',
      'Authorization': 'Bearer $accessToken',
      if (body != null) 'Content-Type': 'application/json',
    });
    if (body != null) request.body = jsonEncode(body);
    return _client.send(request).then(http.Response.fromStream);
  }

  Map<String, dynamic> _decodeData(
    http.Response response,
    Set<int> expectedStatuses,
  ) {
    if (!expectedStatuses.contains(response.statusCode)) {
      throw _exception(response);
    }
    final body = _decodeObject(response.body);
    final data = body['data'];
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Messaging response data is missing');
    }
    return data;
  }

  MessagingApiException _exception(http.Response response) {
    var code = 'HTTP_ERROR';
    var message = 'HTTP ${response.statusCode}';
    String? requestId = response.headers['x-request-id'];
    try {
      final body = _decodeObject(response.body);
      final error = body['error'];
      if (error is Map<String, dynamic>) {
        if (error['code'] case final String value when value.isNotEmpty) {
          code = value;
        }
        if (error['message'] case final String value when value.isNotEmpty) {
          message = value;
        }
        if (error['requestId'] case final String value when value.isNotEmpty) {
          requestId = value;
        }
      }
    } catch (_) {
      // Keep generic proxy/transport HTTP information.
    }
    return MessagingApiException(
      statusCode: response.statusCode,
      code: code,
      message: message,
      requestId: requestId,
    );
  }

  @override
  void close() => _client.close();
}

Map<String, dynamic> _decodeObject(String source) {
  if (source.trim().isEmpty) {
    throw const FormatException('消息服务返回了空响应。');
  }
  final decoded = jsonDecode(source);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('API response must be a JSON object');
  }
  return decoded;
}
