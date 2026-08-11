import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:im_client/features/groups/data/groups_api_client.dart';

void main() {
  test('creates group with bearer auth and stable member ids', () async {
    late http.Request captured;
    final client = GroupsApiClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'data': _groupJson(),
            'requestId': 'req-group-create',
          }),
          201,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(client.close);

    final group = await client.createGroup(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
      name: '项目群',
      memberIds: const [
        '018f0000-0000-7000-8000-000000000002',
        '018f0000-0000-7000-8000-000000000003',
      ],
    );

    expect(captured.method, 'POST');
    expect(captured.url.path, '/api/v1/groups');
    expect(captured.headers['authorization'], 'Bearer token');
    expect(jsonDecode(captured.body), {
      'name': '项目群',
      'memberIds': [
        '018f0000-0000-7000-8000-000000000002',
        '018f0000-0000-7000-8000-000000000003',
      ],
    });
    expect(group.name, '项目群');
    expect(group.memberCount, 3);
    expect(group.myRole, 'OWNER');
  });

  test('updates only explicitly supplied group fields', () async {
    late http.Request captured;
    final client = GroupsApiClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'data': _groupJson(joinMode: 'APPROVAL'),
              'requestId': 'req-group-update',
            }),
          ),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(client.close);

    await client.updateGroup(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
      groupId: '018f0000-0000-7000-8000-000000000001',
      joinMode: 'APPROVAL',
    );

    expect(captured.method, 'PATCH');
    expect(jsonDecode(captured.body), {'joinMode': 'APPROVAL'});
  });

  test('updates group avatar using only explicit media reference', () async {
    late http.Request captured;
    final avatarId = '018f0000-0000-7000-8000-000000000099';
    final client = GroupsApiClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'data': _groupJson(
              avatarMediaId: avatarId,
              avatarRevision: 4,
            ),
            'requestId': 'req-group-avatar',
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(client.close);

    final group = await client.updateGroup(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
      groupId: '018f0000-0000-7000-8000-000000000001',
      avatarMediaId: avatarId,
    );

    expect(captured.method, 'PATCH');
    expect(jsonDecode(captured.body), {'avatarMediaId': avatarId});
    expect(group.avatarMediaId, avatarId);
    expect(group.avatarRevision, 4);
  });

  test('lists group members and preserves role and nickname', () async {
    final client = GroupsApiClient(
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'data': {
              'items': [
                {
                  'user': {
                    'id': '018f0000-0000-7000-8000-000000000002',
                    'handle': 'alice01',
                    'displayName': 'Alice',
                  },
                  'role': 'ADMIN',
                  'nickname': 'A',
                  'joinedAt': '2026-08-10T10:00:00Z',
                },
              ],
            },
            'requestId': 'req-members',
          }),
          200,
        ),
      ),
    );
    addTearDown(client.close);

    final members = await client.listMembers(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
      groupId: '018f0000-0000-7000-8000-000000000001',
    );

    expect(members.single.role, 'ADMIN');
    expect(members.single.effectiveName, 'A');
  });

  test('stable group errors retain server machine code', () async {
    final client = GroupsApiClient(
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': {
              'code': 'GROUP_FORBIDDEN',
              'message': 'Group operation is not allowed',
              'requestId': 'req-denied',
            },
          }),
          403,
        ),
      ),
    );
    addTearDown(client.close);

    await expectLater(
      client.dissolveGroup(
        origin: Uri.parse('http://127.0.0.1:18473'),
        accessToken: 'token',
        groupId: '018f0000-0000-7000-8000-000000000001',
      ),
      throwsA(
        isA<GroupsApiException>()
            .having((error) => error.statusCode, 'status', 403)
            .having((error) => error.code, 'code', 'GROUP_FORBIDDEN')
            .having((error) => error.requestId, 'requestId', 'req-denied'),
      ),
    );
  });
}

Map<String, dynamic> _groupJson({
  String joinMode = 'INVITE_ONLY',
  String avatarMediaId = '',
  int avatarRevision = 0,
}) => {
  'id': '018f0000-0000-7000-8000-000000000001',
  'name': '项目群',
  'announcement': '',
  'joinMode': joinMode,
  'status': 'ACTIVE',
  'memberCount': 3,
  if (avatarMediaId.isNotEmpty) 'avatarMediaId': avatarMediaId,
  'avatarRevision': avatarRevision,
  'ownerUserId': '018f0000-0000-7000-8000-000000000010',
  'myRole': 'OWNER',
  'myNickname': '',
  'createdAt': '2026-08-10T10:00:00Z',
  'updatedAt': '2026-08-10T10:00:00Z',
};
