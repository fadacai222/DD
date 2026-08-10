import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:im_client/features/calls/data/http_call_session_api.dart';
import 'package:im_client/features/calls/domain/call_session.dart';

void main() {
  test('formal create call uses bearer principal and does not send caller identity', () async {
    late http.Request captured;
    final api = HttpCallSessionApi(
      accessTokenProvider: () async => 'fresh-token',
      client: MockClient((request) async {
        captured = request;
        return http.Response.bytes(
          utf8.encode(jsonEncode({'data': _ringingCall(), 'requestId': 'req-1'})),
          201,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(api.close);

    final call = await api.createCall(
      apiBaseUri: Uri.parse('http://127.0.0.1:18473'),
      callerIdentity: 'caller-spoof-must-not-be-sent',
      callerName: 'Spoof',
      calleeIdentity: '018f0000-0000-7000-8000-000000000002',
      kind: CallKind.video,
    );

    expect(captured.url.path, '/api/v1/calls');
    expect(captured.headers['authorization'], 'Bearer fresh-token');
    expect(jsonDecode(captured.body), {
      'calleeUserId': '018f0000-0000-7000-8000-000000000002',
      'kind': 'video',
    });
    expect(captured.body, isNot(contains('caller_identity')));
    expect(captured.body, isNot(contains('caller_name')));
    expect(call.status, CallSessionStatus.ringing);
  });

  test('formal active call ignores participant identity query parameter', () async {
    late http.Request captured;
    final api = HttpCallSessionApi(
      accessTokenProvider: () async => 'token',
      client: MockClient((request) async {
        captured = request;
        return http.Response('', 204);
      }),
    );
    addTearDown(api.close);

    final call = await api.activeCall(
      apiBaseUri: Uri.parse('http://127.0.0.1:18473'),
      participantIdentity: 'spoofed-user',
    );

    expect(call, isNull);
    expect(captured.url.path, '/api/v1/calls/active');
    expect(captured.url.query, isEmpty);
    expect(captured.headers['authorization'], 'Bearer token');
  });

  test('formal actions and token issuance use authenticated identity only', () async {
    final requests = <http.Request>[];
    final api = HttpCallSessionApi(
      accessTokenProvider: () async => 'token-2',
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/token')) {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'data': {
                  'server_url': 'wss://rtc.example.invalid',
                  'token': 'jwt-token',
                  'room_name': 'dd-call-room',
                  'participant_identity': '018f0000-0000-7000-8000-000000000001',
                  'expires_in_seconds': 300,
                },
                'requestId': 'req-token',
              }),
            ),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        final accepted = _ringingCall()..['status'] = 'accepted';
        accepted['accepted_at'] = '2026-08-10T12:00:04Z';
        return http.Response.bytes(
          utf8.encode(jsonEncode({'data': accepted, 'requestId': 'req-action'})),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(api.close);

    await api.applyAction(
      apiBaseUri: Uri.parse('http://127.0.0.1:18473'),
      callId: '018f0000-0000-7000-8000-000000000100',
      participantIdentity: 'spoofed-user',
      action: 'accept',
    );
    final token = await api.issueJoinToken(
      apiBaseUri: Uri.parse('http://127.0.0.1:18473'),
      callId: '018f0000-0000-7000-8000-000000000100',
      participantIdentity: 'spoofed-user',
      participantName: 'Spoof Name',
    );

    expect(jsonDecode(requests[0].body), {'action': 'accept'});
    expect(requests[0].body, isNot(contains('participant_identity')));
    expect(requests[1].body, isEmpty);
    expect(requests.every((request) => request.headers['authorization'] == 'Bearer token-2'), isTrue);
    expect(token.participantToken, 'jwt-token');
    expect(token.serverUrl, Uri.parse('wss://rtc.example.invalid'));
  });

  test('formal mode refuses missing access token instead of falling back to legacy endpoint', () async {
    var requested = false;
    final api = HttpCallSessionApi(
      accessTokenProvider: () async => null,
      client: MockClient((_) async {
        requested = true;
        return http.Response('', 500);
      }),
    );
    addTearDown(api.close);

    await expectLater(
      api.activeCall(
        apiBaseUri: Uri.parse('http://127.0.0.1:18473'),
        participantIdentity: 'user-a',
      ),
      throwsA(
        isA<CallApiException>().having((error) => error.code, 'code', 'AUTH_REQUIRED'),
      ),
    );
    expect(requested, isFalse);
  });
}

Map<String, dynamic> _ringingCall() => {
  'id': '018f0000-0000-7000-8000-000000000100',
  'room_name': 'dd-call-room',
  'caller_identity': '018f0000-0000-7000-8000-000000000001',
  'caller_name': 'Alice',
  'callee_identity': '018f0000-0000-7000-8000-000000000002',
  'callee_name': 'Bob',
  'kind': 'video',
  'status': 'ringing',
  'created_at': '2026-08-10T12:00:00Z',
  'ring_timeout_seconds': 30,
};
