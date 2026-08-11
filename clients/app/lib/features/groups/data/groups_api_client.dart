import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../auth/data/auth_api_client.dart' show normalizeAuthOrigin;
import '../../auth/data/auth_http_client.dart';
import '../domain/group_models.dart';

abstract interface class GroupsGateway {
  Future<GroupInfo> createGroup({
    required Uri origin,
    required String accessToken,
    required String name,
    required List<String> memberIds,
  });

  Future<GroupInfo> getGroup({
    required Uri origin,
    required String accessToken,
    required String groupId,
  });

  Future<GroupInfo> updateGroup({
    required Uri origin,
    required String accessToken,
    required String groupId,
    String? name,
    String? announcement,
    String? joinMode,
    String? avatarMediaId,
  });

  Future<List<GroupMemberItem>> listMembers({
    required Uri origin,
    required String accessToken,
    required String groupId,
  });

  Future<List<GroupMemberItem>> inviteMembers({
    required Uri origin,
    required String accessToken,
    required String groupId,
    required List<String> userIds,
  });

  Future<GroupMemberItem> updateMember({
    required Uri origin,
    required String accessToken,
    required String groupId,
    required String userId,
    String? role,
    String? nickname,
  });

  Future<void> removeMember({
    required Uri origin,
    required String accessToken,
    required String groupId,
    required String userId,
  });

  Future<void> leaveGroup({
    required Uri origin,
    required String accessToken,
    required String groupId,
  });

  Future<GroupInfo> transferOwnership({
    required Uri origin,
    required String accessToken,
    required String groupId,
    required String userId,
  });

  Future<void> dissolveGroup({
    required Uri origin,
    required String accessToken,
    required String groupId,
  });

  Future<GroupJoinRequestItem> createJoinRequest({
    required Uri origin,
    required String accessToken,
    required String groupId,
    String message = '',
  });

  Future<List<GroupJoinRequestItem>> listJoinRequests({
    required Uri origin,
    required String accessToken,
    required String groupId,
  });

  Future<GroupJoinRequestItem> resolveJoinRequest({
    required Uri origin,
    required String accessToken,
    required String groupId,
    required String requestId,
    required bool approve,
  });

  void close();
}

final class GroupsApiException implements Exception {
  const GroupsApiException({
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

final class GroupsApiClient implements GroupsGateway {
  GroupsApiClient({http.Client? httpClient})
    : _client = httpClient ?? createAuthHttpClient();

  final http.Client _client;

  @override
  Future<GroupInfo> createGroup({
    required Uri origin,
    required String accessToken,
    required String name,
    required List<String> memberIds,
  }) async => GroupInfo.fromJson(
    await _requestData(
      origin: origin,
      accessToken: accessToken,
      path: '/api/v1/groups',
      method: 'POST',
      body: {'name': name, 'memberIds': memberIds},
      expectedStatuses: const {201},
    ),
  );

  @override
  Future<GroupInfo> getGroup({
    required Uri origin,
    required String accessToken,
    required String groupId,
  }) async => GroupInfo.fromJson(
    await _requestData(
      origin: origin,
      accessToken: accessToken,
      path: '/api/v1/groups/${Uri.encodeComponent(groupId)}',
      expectedStatuses: const {200},
    ),
  );

  @override
  Future<GroupInfo> updateGroup({
    required Uri origin,
    required String accessToken,
    required String groupId,
    String? name,
    String? announcement,
    String? joinMode,
    String? avatarMediaId,
  }) async => GroupInfo.fromJson(
    await _requestData(
      origin: origin,
      accessToken: accessToken,
      path: '/api/v1/groups/${Uri.encodeComponent(groupId)}',
      method: 'PATCH',
      body: {
        'name': ?name,
        'announcement': ?announcement,
        'joinMode': ?joinMode,
        'avatarMediaId': ?avatarMediaId,
      },
      expectedStatuses: const {200},
    ),
  );

  @override
  Future<List<GroupMemberItem>> listMembers({
    required Uri origin,
    required String accessToken,
    required String groupId,
  }) async => _decodeItems(
    await _requestData(
      origin: origin,
      accessToken: accessToken,
      path: '/api/v1/groups/${Uri.encodeComponent(groupId)}/members',
      expectedStatuses: const {200},
    ),
    GroupMemberItem.fromJson,
  );

  @override
  Future<List<GroupMemberItem>> inviteMembers({
    required Uri origin,
    required String accessToken,
    required String groupId,
    required List<String> userIds,
  }) async => _decodeItems(
    await _requestData(
      origin: origin,
      accessToken: accessToken,
      path: '/api/v1/groups/${Uri.encodeComponent(groupId)}/members',
      method: 'POST',
      body: {'userIds': userIds},
      expectedStatuses: const {200},
    ),
    GroupMemberItem.fromJson,
  );

  @override
  Future<GroupMemberItem> updateMember({
    required Uri origin,
    required String accessToken,
    required String groupId,
    required String userId,
    String? role,
    String? nickname,
  }) async => GroupMemberItem.fromJson(
    await _requestData(
      origin: origin,
      accessToken: accessToken,
      path:
          '/api/v1/groups/${Uri.encodeComponent(groupId)}/members/${Uri.encodeComponent(userId)}',
      method: 'PATCH',
      body: {'role': ?role, 'nickname': ?nickname},
      expectedStatuses: const {200},
    ),
  );

  @override
  Future<void> removeMember({
    required Uri origin,
    required String accessToken,
    required String groupId,
    required String userId,
  }) async {
    await _requestData(
      origin: origin,
      accessToken: accessToken,
      path:
          '/api/v1/groups/${Uri.encodeComponent(groupId)}/members/${Uri.encodeComponent(userId)}',
      method: 'DELETE',
      expectedStatuses: const {200},
    );
  }

  @override
  Future<void> leaveGroup({
    required Uri origin,
    required String accessToken,
    required String groupId,
  }) async {
    await _requestData(
      origin: origin,
      accessToken: accessToken,
      path: '/api/v1/groups/${Uri.encodeComponent(groupId)}/leave',
      method: 'POST',
      expectedStatuses: const {200},
    );
  }

  @override
  Future<GroupInfo> transferOwnership({
    required Uri origin,
    required String accessToken,
    required String groupId,
    required String userId,
  }) async => GroupInfo.fromJson(
    await _requestData(
      origin: origin,
      accessToken: accessToken,
      path: '/api/v1/groups/${Uri.encodeComponent(groupId)}/transfer',
      method: 'POST',
      body: {'userId': userId},
      expectedStatuses: const {200},
    ),
  );

  @override
  Future<void> dissolveGroup({
    required Uri origin,
    required String accessToken,
    required String groupId,
  }) async {
    await _requestData(
      origin: origin,
      accessToken: accessToken,
      path: '/api/v1/groups/${Uri.encodeComponent(groupId)}',
      method: 'DELETE',
      expectedStatuses: const {200},
    );
  }

  @override
  Future<GroupJoinRequestItem> createJoinRequest({
    required Uri origin,
    required String accessToken,
    required String groupId,
    String message = '',
  }) async => GroupJoinRequestItem.fromJson(
    await _requestData(
      origin: origin,
      accessToken: accessToken,
      path: '/api/v1/groups/${Uri.encodeComponent(groupId)}/join-requests',
      method: 'POST',
      body: {'message': message},
      expectedStatuses: const {201},
    ),
  );

  @override
  Future<List<GroupJoinRequestItem>> listJoinRequests({
    required Uri origin,
    required String accessToken,
    required String groupId,
  }) async => _decodeItems(
    await _requestData(
      origin: origin,
      accessToken: accessToken,
      path: '/api/v1/groups/${Uri.encodeComponent(groupId)}/join-requests',
      expectedStatuses: const {200},
    ),
    GroupJoinRequestItem.fromJson,
  );

  @override
  Future<GroupJoinRequestItem> resolveJoinRequest({
    required Uri origin,
    required String accessToken,
    required String groupId,
    required String requestId,
    required bool approve,
  }) async => GroupJoinRequestItem.fromJson(
    await _requestData(
      origin: origin,
      accessToken: accessToken,
      path:
          '/api/v1/groups/${Uri.encodeComponent(groupId)}/join-requests/${Uri.encodeComponent(requestId)}/${approve ? 'approve' : 'reject'}',
      method: 'POST',
      expectedStatuses: const {200},
    ),
  );

  Future<Map<String, dynamic>> _requestData({
    required Uri origin,
    required String accessToken,
    required String path,
    required Set<int> expectedStatuses,
    String method = 'GET',
    Map<String, dynamic>? body,
  }) async {
    final url = normalizeAuthOrigin(origin).resolve(path);
    final headers = <String, String>{
      'Accept': 'application/json',
      'Authorization': 'Bearer $accessToken',
      if (body != null) 'Content-Type': 'application/json',
    };
    late http.Response response;
    switch (method) {
      case 'POST':
        response = await _client.post(
          url,
          headers: headers,
          body: body == null ? null : jsonEncode(body),
        );
      case 'PATCH':
        response = await _client.patch(
          url,
          headers: headers,
          body: body == null ? null : jsonEncode(body),
        );
      case 'DELETE':
        response = await _client.delete(url, headers: headers);
      default:
        response = await _client.get(url, headers: headers);
    }
    Map<String, dynamic>? payload;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) payload = decoded;
    } catch (_) {}
    if (!expectedStatuses.contains(response.statusCode)) {
      final error = payload?['error'];
      if (error is Map) {
        throw GroupsApiException(
          statusCode: response.statusCode,
          code: error['code']?.toString() ?? 'GROUP_REQUEST_FAILED',
          message: error['message']?.toString() ?? '群聊请求失败。',
          requestId: error['requestId']?.toString(),
        );
      }
      throw GroupsApiException(
        statusCode: response.statusCode,
        code: 'GROUP_REQUEST_FAILED',
        message: '群聊请求失败（HTTP ${response.statusCode}）。',
      );
    }
    final data = payload?['data'];
    if (data is! Map) throw const FormatException('群聊服务响应格式错误。');
    return data.map((key, value) => MapEntry(key.toString(), value));
  }

  static List<T> _decodeItems<T>(
    Map<String, dynamic> data,
    T Function(Map<String, dynamic>) decoder,
  ) {
    final raw = data['items'];
    if (raw is! List) throw const FormatException('群聊列表响应格式错误。');
    return raw
        .whereType<Map>()
        .map(
          (item) => decoder(
            item.map((key, value) => MapEntry(key.toString(), value)),
          ),
        )
        .toList(growable: false);
  }

  @override
  void close() => _client.close();
}
