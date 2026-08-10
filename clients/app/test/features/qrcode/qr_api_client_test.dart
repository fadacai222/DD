import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:im_client/features/auth/data/auth_api_client.dart';
import 'package:im_client/features/qrcode/data/qr_api_client.dart';

void main() {
  test('my QR uses bearer auth', () async {
    late http.Request captured;
    final client = QrApiClient(
      httpClient: MockClient((request) async {
        captured = request;
        return _response({
          'data': {
            'type': 'USER',
            'value': 'dd://qr/v1/user?instance=https%3A%2F%2Fchat.example.invalid&userId=018f0000-0000-7000-8000-000000000001',
          },
          'requestId': 'req-my-qr',
        });
      }),
    );
    addTearDown(client.close);

    final result = await client.myQr(
      origin: Uri.parse('https://chat.example.invalid'),
      accessToken: 'token',
    );

    expect(captured.method, 'GET');
    expect(captured.url.path, '/api/v1/qr/me');
    expect(captured.headers['authorization'], 'Bearer token');
    expect(result.type, 'USER');
  });

  test('group redeem keeps secret nonce in POST body', () async {
    late http.Request captured;
    final client = QrApiClient(
      httpClient: MockClient((request) async {
        captured = request;
        return _response({
          'data': {
            'group': {
              'id': '018f0000-0000-7000-8000-000000000010',
              'name': 'QR Group',
              'announcement': '',
              'joinMode': 'INVITE_ONLY',
              'status': 'ACTIVE',
              'myRole': 'MEMBER',
              'myNickname': '',
              'memberCount': 3,
              'ownerUserId': '018f0000-0000-7000-8000-000000000001',
              'createdByUserId': '018f0000-0000-7000-8000-000000000001',
              'createdAt': '2026-08-10T12:00:00Z',
              'updatedAt': '2026-08-10T12:00:00Z',
            },
          },
          'requestId': 'req-group-qr',
        });
      }),
    );
    addTearDown(client.close);
    const nonce = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

    final group = await client.redeemGroupInvite(
      origin: Uri.parse('https://chat.example.invalid'),
      accessToken: 'token',
      nonce: nonce,
    );

    expect(captured.url.path, '/api/v1/group-qr/redeem');
    expect(captured.url.query, isEmpty);
    expect(jsonDecode(captured.body), {'nonce': nonce});
    expect(group.name, 'QR Group');
  });

  test('login lifecycle never puts nonce in URL and consume parses session', () async {
    final requests = <http.Request>[];
    const nonce = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
    final client = QrApiClient(
      httpClient: MockClient((request) async {
        requests.add(request);
        switch (request.url.path) {
          case '/api/v1/qr-login':
            return _response({
              'data': {
                'status': 'PENDING',
                'nonce': nonce,
                'payload': 'dd://qr/v1/login?instance=https%3A%2F%2Fchat.example.invalid&nonce=$nonce',
                'device': {
                  'name': 'DD Windows',
                  'platform': 'WINDOWS',
                  'appVersion': '',
                },
                'expiresAt': '2026-08-10T12:02:00Z',
              },
              'requestId': 'req-create',
            }, status: 201);
          case '/api/v1/qr-login/status':
            return _response({
              'data': {
                'status': 'CONFIRMED',
                'device': {
                  'name': 'DD Windows',
                  'platform': 'WINDOWS',
                  'appVersion': '',
                },
                'expiresAt': '2026-08-10T12:02:00Z',
                'scannedAt': '2026-08-10T12:00:10Z',
                'confirmedAt': '2026-08-10T12:00:12Z',
              },
              'requestId': 'req-status',
            });
          case '/api/v1/qr-login/consume':
            return _response({
              'data': {
                'session': {
                  'user': {
                    'id': '018f0000-0000-7000-8000-000000000001',
                    'email': 'alice@example.invalid',
                    'handle': 'alice',
                    'displayName': 'Alice',
                  },
                  'device': {
                    'id': '018f0000-0000-7000-8000-000000000020',
                    'name': 'DD Windows',
                    'platform': 'WINDOWS',
                    'appVersion': '',
                  },
                  'tokens': {
                    'accessToken': 'access',
                    'accessExpiresAt': '2026-08-10T12:15:00Z',
                    'refreshToken': 'refresh',
                    'refreshExpiresAt': '2026-09-09T12:00:00Z',
                  },
                },
              },
              'requestId': 'req-consume',
            });
          default:
            throw StateError('unexpected path ${request.url.path}');
        }
      }),
    );
    addTearDown(client.close);

    final created = await client.createLogin(
      origin: Uri.parse('https://chat.example.invalid'),
      device: const AuthDeviceInput(
        name: 'DD Windows',
        platform: 'WINDOWS',
        appVersion: '',
      ),
    );
    final status = await client.loginStatus(
      origin: Uri.parse('https://chat.example.invalid'),
      nonce: nonce,
    );
    final session = await client.consumeLogin(
      origin: Uri.parse('https://chat.example.invalid'),
      nonce: nonce,
    );

    expect(created.nonce, nonce);
    expect(status.status, 'CONFIRMED');
    expect(status.device.name, 'DD Windows');
    expect(session.user.displayName, 'Alice');
    expect(session.tokens.refreshToken, 'refresh');
    for (final request in requests) {
      expect(request.url.toString(), isNot(contains(nonce)));
    }
  });

  test('stable QR machine error is preserved', () async {
    final client = QrApiClient(
      httpClient: MockClient(
        (_) async => _response({
          'error': {
            'code': 'QR_EXPIRED',
            'message': 'QR credential has expired',
            'requestId': 'req-expired',
          },
        }, status: 410),
      ),
    );
    addTearDown(client.close);

    await expectLater(
      client.loginStatus(
        origin: Uri.parse('https://chat.example.invalid'),
        nonce: 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC',
      ),
      throwsA(
        isA<QrApiException>()
            .having((error) => error.statusCode, 'statusCode', 410)
            .having((error) => error.code, 'code', 'QR_EXPIRED'),
      ),
    );
  });
}

http.Response _response(Map<String, dynamic> body, {int status = 200}) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
