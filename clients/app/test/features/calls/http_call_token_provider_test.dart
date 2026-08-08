import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:im_client/features/calls/data/http_call_token_provider.dart';

void main() {
  test('parses a valid short-lived call token response', () async {
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.toString(), 'http://127.0.0.1:18473/api/calls/token');
      expect(request.headers['Content-Type'], 'application/json');
      return http.Response('''{
          "server_url":"ws://127.0.0.1:7880",
          "participant_token":"signed-token",
          "expires_at":"2026-08-07T00:15:00Z"
        }''', 200);
    });
    final provider = HttpCallTokenProvider(client: client);

    final result = await provider.issue(
      apiBaseUri: Uri.parse('http://127.0.0.1:18473'),
      roomName: 'call-demo',
      participantIdentity: 'user-1',
      participantName: '测试用户',
    );

    expect(result.serverUrl, Uri.parse('ws://127.0.0.1:7880'));
    expect(result.participantToken, 'signed-token');
    expect(result.expiresAt.toUtc(), DateTime.utc(2026, 8, 7, 0, 15));
  });

  test('surfaces the backend error message', () async {
    final provider = HttpCallTokenProvider(
      client: MockClient(
        (_) async => http.Response(
          '{"error":{"code":"INVALID","message":"bad identity"}}',
          400,
        ),
      ),
    );

    expect(
      () => provider.issue(
        apiBaseUri: Uri.parse('http://127.0.0.1:18473'),
        roomName: 'call-demo',
        participantIdentity: 'bad',
        participantName: 'User',
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'bad identity',
        ),
      ),
    );
  });

  test('rejects malformed success responses', () async {
    final provider = HttpCallTokenProvider(
      client: MockClient(
        (_) async => http.Response('{"server_url":"http://bad"}', 200),
      ),
    );

    expect(
      () => provider.issue(
        apiBaseUri: Uri.parse('http://127.0.0.1:18473'),
        roomName: 'call-demo',
        participantIdentity: 'user-1',
        participantName: 'User',
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
