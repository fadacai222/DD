import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:im_client/features/moments/data/moments_api_client.dart';

void main() {
  test('feed uses bearer auth and bounded query', () async {
    late http.Request captured;
    final client = MomentsApiClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response.bytes(
          utf8.encode(jsonEncode({'data': {'items': [_momentJson()]}, 'requestId': 'req-feed'})),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(client.close);

    final items = await client.listFeed(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
      before: '018f0000-0000-7000-8000-000000000999',
      authorId: '018f0000-0000-7000-8000-000000000002',
      limit: 20,
    );

    expect(captured.url.path, '/api/v1/moments');
    expect(captured.url.queryParameters['limit'], '20');
    expect(captured.url.queryParameters['before'], '018f0000-0000-7000-8000-000000000999');
    expect(captured.url.queryParameters['authorId'], '018f0000-0000-7000-8000-000000000002');
    expect(captured.headers['authorization'], 'Bearer token');
    expect(items.single.text, 'hello moments');
    expect(items.single.likeUsers.single.displayName, 'Bob');
  });

  test('publish sends stable media ids and per-post audience only', () async {
    late http.Request captured;
    final client = MomentsApiClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response.bytes(
          utf8.encode(jsonEncode({'data': _momentJson(), 'requestId': 'req-create'})),
          201,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(client.close);

    await client.createMoment(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
      text: 'hello moments',
      mediaIds: const ['018f0000-0000-7000-8000-000000000301'],
      visibility: 'PRIVATE',
      visibilityUserIds: const ['018f0000-0000-7000-8000-000000000002'],
    );

    expect(captured.url.path, '/api/v1/moments');
    expect(jsonDecode(captured.body), {
      'text': 'hello moments',
      'mediaIds': ['018f0000-0000-7000-8000-000000000301'],
      'visibility': 'PRIVATE',
      'visibilityUserIds': ['018f0000-0000-7000-8000-000000000002'],
    });
  });

  test('like and unlike use idempotent PUT and DELETE', () async {
    final methods = <String>[];
    final client = MomentsApiClient(
      httpClient: MockClient((request) async {
        methods.add(request.method);
        return http.Response.bytes(
          utf8.encode(jsonEncode({'data': _momentJson(), 'requestId': 'req-like'})),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(client.close);

    const momentId = '018f0000-0000-7000-8000-000000000100';
    await client.setLike(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
      momentId: momentId,
      liked: true,
    );
    await client.setLike(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
      momentId: momentId,
      liked: false,
    );

    expect(methods, ['PUT', 'DELETE']);
  });

  test('relationship privacy uses unambiguous moment-preferences resource', () async {
    final paths = <String>[];
    final client = MomentsApiClient(
      httpClient: MockClient((request) async {
        paths.add(request.url.path);
        if (request.method == 'GET') {
          return http.Response.bytes(
            utf8.encode(jsonEncode({'data': {'items': []}, 'requestId': 'req-prefs'})),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'data': {
                'target': {
                  'id': '018f0000-0000-7000-8000-000000000002',
                  'handle': 'bob',
                  'displayName': 'Bob',
                },
                'hideTarget': true,
                'hideFromTarget': false,
                'updatedAt': '2026-08-10T12:00:00Z',
              },
              'requestId': 'req-pref',
            }),
          ),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(client.close);

    await client.listPreferences(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
    );
    await client.setPreference(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
      userId: '018f0000-0000-7000-8000-000000000002',
      hideTarget: true,
      hideFromTarget: false,
    );

    expect(paths, [
      '/api/v1/moment-preferences',
      '/api/v1/moment-preferences/018f0000-0000-7000-8000-000000000002',
    ]);
  });

  test('activity summary and mark-read use durable authenticated resource', () async {
    final requests = <http.Request>[];
    final client = MomentsApiClient(
      httpClient: MockClient((request) async {
        requests.add(request);
        final unreadCount = request.method == 'GET' ? 123 : 0;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'data': {
                'unreadCount': unreadCount,
                'items': [
                  {
                    'id': '018f0000-0000-7000-8000-000000000901',
                    'kind': 'COMMENT',
                    'actor': {
                      'id': '018f0000-0000-7000-8000-000000000002',
                      'handle': 'bob',
                      'displayName': 'Bob',
                    },
                    'momentId': '018f0000-0000-7000-8000-000000000100',
                    'commentId': '018f0000-0000-7000-8000-000000000801',
                    'commentText': '刚刚评论了你',
                    'createdAt': '2026-08-12T03:58:00Z',
                    'read': request.method != 'GET',
                  },
                ],
              },
              'requestId': 'req-activity',
            }),
          ),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(client.close);

    final summary = await client.getActivitySummary(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
    );
    final cleared = await client.markActivityRead(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
    );

    expect(summary.unreadCount, 123);
    expect(summary.items, hasLength(1));
    expect(summary.items.single.kind, 'COMMENT');
    expect(summary.items.single.actor.displayName, 'Bob');
    expect(summary.items.single.commentText, '刚刚评论了你');
    expect(summary.items.single.read, isFalse);
    expect(cleared.unreadCount, 0);
    expect(cleared.items.single.read, isTrue);
    expect(requests.map((request) => request.method), ['GET', 'POST']);
    expect(
      requests.map((request) => request.url.path),
      ['/api/v1/moment-activity', '/api/v1/moment-activity/read'],
    );
    expect(requests.first.headers['authorization'], 'Bearer token');
  });

  test('stable server code is preserved on privacy failure', () async {
    final client = MomentsApiClient(
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': {
              'code': 'MOMENT_NOT_FOUND',
              'message': 'Moment resource was not found',
              'requestId': 'req-private',
            },
          }),
          404,
        ),
      ),
    );
    addTearDown(client.close);

    await expectLater(
      client.getMoment(
        origin: Uri.parse('http://127.0.0.1:18473'),
        accessToken: 'token',
        momentId: '018f0000-0000-7000-8000-000000000100',
      ),
      throwsA(
        isA<MomentsApiException>()
            .having((error) => error.statusCode, 'statusCode', 404)
            .having((error) => error.code, 'code', 'MOMENT_NOT_FOUND'),
      ),
    );
  });
}

Map<String, dynamic> _momentJson() => {
  'id': '018f0000-0000-7000-8000-000000000100',
  'author': {
    'id': '018f0000-0000-7000-8000-000000000001',
    'handle': 'alice',
    'displayName': 'Alice',
  },
  'text': 'hello moments',
  'visibility': 'ALL_CONTACTS',
  'mediaIds': ['018f0000-0000-7000-8000-000000000301'],
  'likeUsers': [
    {
      'id': '018f0000-0000-7000-8000-000000000002',
      'handle': 'bob',
      'displayName': 'Bob',
    },
  ],
  'comments': [],
  'likedByMe': false,
  'createdAt': '2026-08-10T12:00:00Z',
};
