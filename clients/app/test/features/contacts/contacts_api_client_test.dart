import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:im_client/features/contacts/data/contacts_api_client.dart';

void main() {
  test('exact handle search uses bearer auth and never needs email', () async {
    late http.Request captured;
    final client = ContactsApiClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'data': {
              'user': {
                'id': '018f0000-0000-7000-8000-000000000101',
                'handle': 'bob_01',
                'displayName': 'Bob',
                'bio': 'hello',
              },
              'relationship': 'NONE',
            },
            'requestId': 'req_contact',
          }),
          200,
        );
      }),
    );
    addTearDown(client.close);

    final result = await client.searchByHandle(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'access-token',
      handle: 'bob_01',
    );

    expect(captured.url.path, '/api/v1/users/by-handle/bob_01');
    expect(captured.headers['authorization'], 'Bearer access-token');
    expect(result.user.handle, 'bob_01');
    expect(result.relationship, 'NONE');
  });

  test('send request accepts mutual auto-accept response', () async {
    late http.Request captured;
    final client = ContactsApiClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'data': _requestJson(status: 'ACCEPTED'),
            'requestId': 'req_mutual',
          }),
          200,
        );
      }),
    );
    addTearDown(client.close);

    final result = await client.sendRequest(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'access-token',
      targetHandle: 'bob_01',
      message: 'hi',
    );

    expect(captured.method, 'POST');
    expect(captured.url.path, '/api/v1/contact-requests');
    expect(jsonDecode(captured.body), {
      'targetHandle': 'bob_01',
      'message': 'hi',
    });
    expect(result.status, 'ACCEPTED');
    expect(result.conversationId, isNotEmpty);
  });

  test('relationship error keeps stable API code', () async {
    final client = ContactsApiClient(
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': {
              'code': 'RELATIONSHIP_UNAVAILABLE',
              'message': 'Relationship action is unavailable',
              'requestId': 'req_hidden',
            },
          }),
          409,
        ),
      ),
    );
    addTearDown(client.close);

    await expectLater(
      client.sendRequest(
        origin: Uri.parse('http://127.0.0.1:18473'),
        accessToken: 'access-token',
        targetHandle: 'bob_01',
      ),
      throwsA(
        isA<ContactsApiException>().having(
          (error) => error.code,
          'code',
          'RELATIONSHIP_UNAVAILABLE',
        ),
      ),
    );
  });
}

Map<String, dynamic> _requestJson({required String status}) => {
  'id': '018f0000-0000-7000-8000-000000000201',
  'sender': {
    'id': '018f0000-0000-7000-8000-000000000202',
    'handle': 'alice_01',
    'displayName': 'Alice',
    'bio': '',
  },
  'receiver': {
    'id': '018f0000-0000-7000-8000-000000000203',
    'handle': 'bob_01',
    'displayName': 'Bob',
    'bio': '',
  },
  'message': 'hi',
  'status': status,
  'createdAt': '2026-08-08T03:00:00Z',
  'expiresAt': '2026-09-07T03:00:00Z',
  'resolvedAt': status == 'PENDING' ? null : '2026-08-08T03:01:00Z',
  'conversationId': status == 'ACCEPTED'
      ? '018f0000-0000-7000-8000-000000000204'
      : null,
};
