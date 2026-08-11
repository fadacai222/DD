import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:im_client/features/calls/data/group_call_api_client.dart';
import 'package:im_client/features/calls/presentation/group_call_page.dart';

void main() {
  test('group call start and join use formal group routes', () async {
    final requests = <http.Request>[];
    final client = GroupCallApiClient(
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'data': request.url.path.endsWith('/calls')
                ? _joinJson()
                : _joinJson(),
            'requestId': 'req-1',
          }),
          request.url.path.endsWith('/calls') ? 201 : 200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(client.close);
    final origin = Uri.parse('http://127.0.0.1:18473');
    const groupId = '018f0000-0000-7000-8000-000000000001';
    const callId = '018f0000-0000-7000-8000-000000000011';

    final started = await client.start(
      origin: origin,
      accessToken: 'token',
      groupId: groupId,
      kind: 'video',
    );
    expect(started.call.isVideo, isTrue);
    expect(jsonDecode(requests.first.body), {'kind': 'VIDEO'});
    expect(requests.first.url.path, '/api/v1/groups/$groupId/calls');

    await client.join(
      origin: origin,
      accessToken: 'token',
      groupId: groupId,
      callId: callId,
    );
    expect(
      requests.last.url.path,
      '/api/v1/groups/$groupId/calls/$callId/join',
    );
  });

  test('active group call treats 404 as normal empty state', () async {
    final client = GroupCallApiClient(
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    addTearDown(client.close);

    final active = await client.active(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
      groupId: '018f0000-0000-7000-8000-000000000001',
    );
    expect(active, isNull);
  });

  test('participant grid scales beyond two-party calls', () {
    expect(groupCallGridColumns(1, 800), 1);
    expect(groupCallGridColumns(2, 800), 2);
    expect(groupCallGridColumns(4, 800), 2);
    expect(groupCallGridColumns(5, 800), 3);
    expect(groupCallGridColumns(8, 1200), 4);
  });
}

Map<String, dynamic> _joinJson() => {
  'call': {
    'id': '018f0000-0000-7000-8000-000000000011',
    'groupId': '018f0000-0000-7000-8000-000000000001',
    'kind': 'VIDEO',
    'status': 'ACTIVE',
    'startedBy': {
      'id': '018f0000-0000-7000-8000-000000000021',
      'handle': 'alice',
      'displayName': 'Alice',
    },
    'startedAt': '2026-08-11T00:00:00Z',
    'maxParticipants': 32,
    'participants': [
      {
        'user': {
          'id': '018f0000-0000-7000-8000-000000000021',
          'handle': 'alice',
          'displayName': 'Alice',
        },
        'joinedAt': '2026-08-11T00:00:00Z',
      },
      {
        'user': {
          'id': '018f0000-0000-7000-8000-000000000022',
          'handle': 'bob',
          'displayName': 'Bob',
        },
        'joinedAt': '2026-08-11T00:00:01Z',
      },
      {
        'user': {
          'id': '018f0000-0000-7000-8000-000000000023',
          'handle': 'carol',
          'displayName': 'Carol',
        },
        'joinedAt': '2026-08-11T00:00:02Z',
      },
    ],
  },
  'livekitUrl': 'wss://livekit.example.invalid',
  'token': 'jwt-token',
};
