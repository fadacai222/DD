import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:im_client/features/auth/data/auth_api_client.dart';

void main() {
  test(
    'registration request uses v1 auth contract and parses session',
    () async {
      late http.Request captured;
      final client = AuthApiClient(
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({'data': _sessionJson(), 'requestId': 'req_auth'}),
            201,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.close);

      final session = await client.register(
        origin: Uri.parse('http://127.0.0.1:18473'),
        email: 'alice@example.com',
        code: '123456',
        password: 'correct horse battery staple',
        handle: 'alice',
        displayName: 'Alice',
        device: const AuthDeviceInput(
          name: 'DD Windows',
          platform: 'WINDOWS',
          appVersion: '0.5.0',
        ),
      );

      expect(captured.url.path, '/api/v1/auth/register');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['displayName'], 'Alice');
      expect((body['device'] as Map<String, dynamic>)['platform'], 'WINDOWS');
      expect(session.user.handle, 'alice');
      expect(session.tokens.refreshToken, 'refresh-token');
    },
  );

  test(
    'login surfaces API error code without leaking raw body assumptions',
    () async {
      final client = AuthApiClient(
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': {
                'code': 'INVALID_CREDENTIALS',
                'message': 'Email or password is incorrect',
                'requestId': 'req_test',
              },
            }),
            401,
          ),
        ),
      );
      addTearDown(client.close);

      await expectLater(
        client.login(
          origin: Uri.parse('http://127.0.0.1:18473'),
          email: 'missing@example.com',
          password: 'bad-password',
          device: const AuthDeviceInput(name: 'DD Web', platform: 'WEB'),
        ),
        throwsA(
          isA<AuthApiException>().having(
            (error) => error.code,
            'code',
            'INVALID_CREDENTIALS',
          ),
        ),
      );
    },
  );

  test('refresh preserves authoritative DEVICE_SESSION_REVOKED error code', () async {
    final client = AuthApiClient(
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': {
              'code': 'DEVICE_SESSION_REVOKED',
              'message': 'Device session has been revoked',
              'requestId': 'req_revoked_device',
            },
          }),
          401,
        ),
      ),
    );
    addTearDown(client.close);

    await expectLater(
      client.refresh(
        origin: Uri.parse('http://127.0.0.1:18473'),
        refreshToken: 'revoked-device-refresh',
      ),
      throwsA(
        isA<AuthApiException>()
            .having((error) => error.statusCode, 'statusCode', 401)
            .having(
              (error) => error.code,
              'code',
              'DEVICE_SESSION_REVOKED',
            ),
      ),
    );
  });

  test('refresh keeps ordinary SESSION_EXPIRED distinct from device revocation', () async {
    final client = AuthApiClient(
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': {
              'code': 'SESSION_EXPIRED',
              'message': 'Session is no longer valid',
              'requestId': 'req_expired_refresh',
            },
          }),
          401,
        ),
      ),
    );
    addTearDown(client.close);

    await expectLater(
      client.refresh(
        origin: Uri.parse('http://127.0.0.1:18473'),
        refreshToken: 'expired-refresh',
      ),
      throwsA(
        isA<AuthApiException>()
            .having((error) => error.statusCode, 'statusCode', 401)
            .having((error) => error.code, 'code', 'SESSION_EXPIRED'),
      ),
    );
  });

  test('avatar upload sends authenticated binary payload', () async {
    late http.Request captured;
    final client = AuthApiClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'data': {'updatedAt': '2026-08-08T09:00:00Z'},
            'requestId': 'req_avatar',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(client.close);

    final updatedAt = await client.uploadProfileAvatar(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'access-token',
      bytes: Uint8List.fromList([0xff, 0xd8, 0xff, 0x00]),
      contentType: 'image/jpeg',
    );

    expect(captured.method, 'PUT');
    expect(captured.url.path, '/api/v1/me/avatar');
    expect(captured.headers['authorization'], 'Bearer access-token');
    expect(captured.headers['content-type'], 'image/jpeg');
    expect(captured.bodyBytes, [0xff, 0xd8, 0xff, 0x00]);
    expect(updatedAt, DateTime.utc(2026, 8, 8, 9));
  });

  test('revoked device cleanup uses authenticated delete and parses count', () async {
    late http.Request captured;
    final client = AuthApiClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'data': {'clearedCount': 3},
            'requestId': 'req_device_cleanup',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(client.close);

    final count = await client.clearRevokedDevices(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'access-token',
    );

    expect(captured.method, 'DELETE');
    expect(captured.url.path, '/api/v1/devices/revoked');
    expect(captured.headers['authorization'], 'Bearer access-token');
    expect(count, 3);
  });

  test('origin rejects paths credentials queries and fragments', () {
    for (final value in [
      'http://user:pass@example.com',
      'https://example.com/api',
      'https://example.com?x=1',
      'https://example.com/#fragment',
    ]) {
      expect(
        () => normalizeAuthOrigin(Uri.parse(value)),
        throwsArgumentError,
        reason: value,
      );
    }
  });
}

Map<String, dynamic> _sessionJson() => {
  'user': {
    'id': '018f0000-0000-7000-8000-000000000001',
    'email': 'alice@example.com',
    'handle': 'alice',
    'displayName': 'Alice',
  },
  'device': {
    'id': '018f0000-0000-7000-8000-000000000002',
    'name': 'DD Windows',
    'platform': 'WINDOWS',
    'appVersion': '0.5.0',
  },
  'tokens': {
    'accessToken': 'access-token',
    'accessExpiresAt': '2026-08-08T02:00:00Z',
    'refreshToken': 'refresh-token',
    'refreshExpiresAt': '2026-09-07T02:00:00Z',
  },
};
