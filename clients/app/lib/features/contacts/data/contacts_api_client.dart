import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../auth/data/auth_api_client.dart' show normalizeAuthOrigin;
import '../../auth/data/auth_http_client.dart';
import '../domain/contact_models.dart';

abstract interface class ContactsGateway {
  Future<ContactSearchResult> searchByHandle({
    required Uri origin,
    required String accessToken,
    required String handle,
  });

  Future<ContactSearchResult> getUserById({
    required Uri origin,
    required String accessToken,
    required String userId,
  });

  Future<ContactRequestItem> sendRequest({
    required Uri origin,
    required String accessToken,
    required String targetHandle,
    String message,
  });

  Future<RelationshipPage<ContactRequestItem>> listRequests({
    required Uri origin,
    required String accessToken,
    required String direction,
  });

  Future<ContactRequestItem> acceptRequest({
    required Uri origin,
    required String accessToken,
    required String requestId,
  });

  Future<ContactRequestItem> rejectRequest({
    required Uri origin,
    required String accessToken,
    required String requestId,
  });

  Future<ContactRequestItem> cancelRequest({
    required Uri origin,
    required String accessToken,
    required String requestId,
  });

  Future<RelationshipPage<ContactItem>> listContacts({
    required Uri origin,
    required String accessToken,
  });

  Future<ContactItem> addContact({
    required Uri origin,
    required String accessToken,
    required String userId,
  });

  Future<ContactItem> updateContact({
    required Uri origin,
    required String accessToken,
    required String userId,
    String? remark,
    bool? isStarred,
    List<String>? tags,
  });

  Future<void> deleteContact({
    required Uri origin,
    required String accessToken,
    required String userId,
  });

  Future<BlockedUserItem> blockUser({
    required Uri origin,
    required String accessToken,
    required String userId,
  });

  Future<RelationshipPage<BlockedUserItem>> listBlocks({
    required Uri origin,
    required String accessToken,
  });

  Future<void> unblockUser({
    required Uri origin,
    required String accessToken,
    required String userId,
  });

  void close();
}

final class ContactsApiException implements Exception {
  const ContactsApiException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.requestId,
  });

  final int statusCode;
  final String code;
  final String message;
  final String? requestId;

  @override
  String toString() => '$message${requestId == null ? '' : ' · $requestId'}';
}

final class ContactsApiClient implements ContactsGateway {
  ContactsApiClient({http.Client? httpClient})
    : _client = httpClient ?? createAuthHttpClient();

  final http.Client _client;

  @override
  Future<ContactSearchResult> searchByHandle({
    required Uri origin,
    required String accessToken,
    required String handle,
  }) async {
    final encoded = Uri.encodeComponent(handle.trim());
    final response = await _authorized(
      origin,
      '/api/v1/users/by-handle/$encoded',
      accessToken,
    );
    final data = _decodeData(response, expectedStatuses: const {200});
    return ContactSearchResult.fromJson(data);
  }

  @override
  Future<ContactSearchResult> getUserById({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async {
    final encoded = Uri.encodeComponent(userId.trim());
    final response = await _authorized(
      origin,
      '/api/v1/users/$encoded',
      accessToken,
    );
    final data = _decodeData(response, expectedStatuses: const {200});
    return ContactSearchResult.fromJson(data);
  }

  Future<List<ContactMentionSuggestion>> suggestMentions({
    required Uri origin,
    required String accessToken,
    required String query,
    required String conversationId,
    int limit = 8,
  }) async {
    final parameters = <String, String>{
      'q': query.trim(),
      'limit': '$limit',
      if (conversationId.trim().isNotEmpty)
        'conversationId': conversationId.trim(),
    };
    final encodedQuery = Uri(queryParameters: parameters).query;
    final response = await _authorized(
      origin,
      '/api/v1/users/mention-suggestions?$encodedQuery',
      accessToken,
    );
    final data = _decodeData(response, expectedStatuses: const {200});
    final rawItems = data['items'];
    if (rawItems is! List) {
      throw const FormatException('Mention suggestion items are malformed');
    }
    return rawItems
        .whereType<Map<String, dynamic>>()
        .map(ContactMentionSuggestion.fromJson)
        .toList(growable: false);
  }

  @override
  Future<ContactRequestItem> sendRequest({
    required Uri origin,
    required String accessToken,
    required String targetHandle,
    String message = '',
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/contact-requests',
      accessToken,
      method: 'POST',
      body: {'targetHandle': targetHandle.trim(), 'message': message.trim()},
    );
    return ContactRequestItem.fromJson(
      _decodeData(response, expectedStatuses: const {200, 201}),
    );
  }

  @override
  Future<RelationshipPage<ContactRequestItem>> listRequests({
    required Uri origin,
    required String accessToken,
    required String direction,
  }) async {
    final query = Uri(
      queryParameters: {'direction': direction, 'page': '1', 'pageSize': '100'},
    ).query;
    final response = await _authorized(
      origin,
      '/api/v1/contact-requests?$query',
      accessToken,
    );
    final data = _decodeData(response, expectedStatuses: const {200});
    return _decodePage(data, ContactRequestItem.fromJson);
  }

  @override
  Future<ContactRequestItem> acceptRequest({
    required Uri origin,
    required String accessToken,
    required String requestId,
  }) => _resolveRequest(
    origin: origin,
    accessToken: accessToken,
    requestId: requestId,
    action: 'accept',
  );

  @override
  Future<ContactRequestItem> rejectRequest({
    required Uri origin,
    required String accessToken,
    required String requestId,
  }) => _resolveRequest(
    origin: origin,
    accessToken: accessToken,
    requestId: requestId,
    action: 'reject',
  );

  @override
  Future<ContactRequestItem> cancelRequest({
    required Uri origin,
    required String accessToken,
    required String requestId,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/contact-requests/$requestId',
      accessToken,
      method: 'DELETE',
    );
    return ContactRequestItem.fromJson(
      _decodeData(response, expectedStatuses: const {200}),
    );
  }

  Future<ContactRequestItem> _resolveRequest({
    required Uri origin,
    required String accessToken,
    required String requestId,
    required String action,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/contact-requests/$requestId/$action',
      accessToken,
      method: 'POST',
      body: const {},
    );
    return ContactRequestItem.fromJson(
      _decodeData(response, expectedStatuses: const {200}),
    );
  }

  @override
  Future<RelationshipPage<ContactItem>> listContacts({
    required Uri origin,
    required String accessToken,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/contacts?page=1&pageSize=100',
      accessToken,
    );
    final data = _decodeData(response, expectedStatuses: const {200});
    return _decodePage(data, ContactItem.fromJson);
  }

  @override
  Future<ContactItem> addContact({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/contacts/$userId',
      accessToken,
      method: 'PUT',
    );
    return ContactItem.fromJson(
      _decodeData(response, expectedStatuses: const {200}),
    );
  }

  @override
  Future<ContactItem> updateContact({
    required Uri origin,
    required String accessToken,
    required String userId,
    String? remark,
    bool? isStarred,
    List<String>? tags,
  }) async {
    final body = <String, dynamic>{
      'remark': ?remark?.trim(),
      'isStarred': ?isStarred,
      'tags': ?tags,
    };
    final response = await _authorized(
      origin,
      '/api/v1/contacts/$userId',
      accessToken,
      method: 'PATCH',
      body: body,
    );
    return ContactItem.fromJson(
      _decodeData(response, expectedStatuses: const {200}),
    );
  }

  @override
  Future<void> deleteContact({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/contacts/$userId',
      accessToken,
      method: 'DELETE',
    );
    _decodeData(response, expectedStatuses: const {200});
  }

  @override
  Future<BlockedUserItem> blockUser({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/blocks',
      accessToken,
      method: 'POST',
      body: {'userId': userId},
    );
    return BlockedUserItem.fromJson(
      _decodeData(response, expectedStatuses: const {201}),
    );
  }

  @override
  Future<RelationshipPage<BlockedUserItem>> listBlocks({
    required Uri origin,
    required String accessToken,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/blocks?page=1&pageSize=100',
      accessToken,
    );
    final data = _decodeData(response, expectedStatuses: const {200});
    return _decodePage(data, BlockedUserItem.fromJson);
  }

  @override
  Future<void> unblockUser({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async {
    final response = await _authorized(
      origin,
      '/api/v1/blocks/$userId',
      accessToken,
      method: 'DELETE',
    );
    _decodeData(response, expectedStatuses: const {200});
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
    http.Response response, {
    required Set<int> expectedStatuses,
  }) {
    if (!expectedStatuses.contains(response.statusCode)) {
      throw _exception(response);
    }
    final body = _decodeObject(response.body);
    final data = body['data'];
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Contacts response data is missing');
    }
    return data;
  }

  RelationshipPage<T> _decodePage<T>(
    Map<String, dynamic> data,
    T Function(Map<String, dynamic>) decoder,
  ) {
    final rawItems = data['items'];
    if (rawItems is! List) {
      throw const FormatException('Relationship page items are malformed');
    }
    return RelationshipPage<T>(
      items: rawItems
          .map((item) => decoder(item as Map<String, dynamic>))
          .toList(growable: false),
      page: data['page'] as int,
      pageSize: data['pageSize'] as int,
      totalItems: data['totalItems'] as int,
      totalPages: data['totalPages'] as int,
    );
  }

  ContactsApiException _exception(http.Response response) {
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
      // Keep the generic HTTP error for proxy/HTML failures.
    }
    return ContactsApiException(
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
  final decoded = jsonDecode(source);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('API response must be a JSON object');
  }
  return decoded;
}
