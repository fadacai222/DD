import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:im_client/features/push/data/push_api_client.dart';

void main() {
  test('loads and updates push preferences', () async {
    final requests = <http.Request>[];
    final client = PushApiClient(
      client: MockClient((request) async {
        requests.add(request);
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'data': {'pushEnabled': true, 'previewMode': 'SENDER_ONLY'},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({
            'data': {'pushEnabled': false, 'previewMode': 'HIDDEN'},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    const token = 'access-token';
    final origin = Uri.parse('https://dd.example.test');
    final initial = await client.getPreferences(origin: origin, accessToken: token);
    expect(initial.pushEnabled, isTrue);
    expect(initial.previewMode, 'SENDER_ONLY');
    final updated = await client.updatePreferences(
      origin: origin,
      accessToken: token,
      pushEnabled: false,
      previewMode: 'HIDDEN',
    );
    expect(updated.pushEnabled, isFalse);
    expect(updated.previewMode, 'HIDDEN');
    expect(requests, hasLength(2));
    expect(requests.first.url.path, '/api/v1/push/preferences');
    expect(requests.first.headers['Authorization'], 'Bearer $token');
  });

  test('registers endpoint without exposing it in the URL', () async {
    late http.Request captured;
    final client = PushApiClient(
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({'data': {'id': 'endpoint-id'}}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    const endpoint = 'secret-device-registration-token';
    await client.registerEndpoint(
      origin: Uri.parse('https://dd.example.test'),
      accessToken: 'token',
      provider: 'FCM',
      endpoint: endpoint,
      appId: 'dd-project',
      environment: 'PRODUCTION',
    );
    expect(captured.url.path, '/api/v1/push/endpoints');
    expect(captured.url.toString(), isNot(contains(endpoint)));
    final payload = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(payload['endpoint'], endpoint);
  });

  test('surfaces structured push API failures', () async {
    final client = PushApiClient(
      client: MockClient((_) async => http.Response(
            jsonEncode({
              'error': {
                'code': 'PUSH_ENDPOINT_CONFLICT',
                'message': 'already bound',
              },
            }),
            409,
            headers: {'content-type': 'application/json'},
          )),
    );
    expect(
      () => client.registerEndpoint(
        origin: Uri.parse('https://dd.example.test'),
        accessToken: 'token',
        provider: 'FCM',
        endpoint: 'token-1',
        appId: 'dd',
        environment: 'PRODUCTION',
      ),
      throwsA(
        isA<PushApiException>()
            .having((error) => error.statusCode, 'statusCode', 409)
            .having((error) => error.code, 'code', 'PUSH_ENDPOINT_CONFLICT'),
      ),
    );
  });
}
