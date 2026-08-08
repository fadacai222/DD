import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:im_client/core/network/api_client.dart';

void main() {
  test('getInstance decodes v1 envelope and request id', () async {
    final client = ApiClient(
      origin: Uri.parse('https://chat.test'),
      httpClient: MockClient((request) async {
        expect(request.url.toString(), 'https://chat.test/api/v1/instance');
        expect(request.headers['Accept'], 'application/json');
        return http.Response(
          '''{"data":{"name":"DD","apiVersion":"v1","apiBaseUrl":"https://chat.test/api/v1","realtimeUrl":"wss://chat.test/api/v1/realtime","liveKitUrl":"wss://media.test","features":{"calls":true,"registrationMode":"open"}},"requestId":"req_fixture"}''',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(client.close);

    final response = await client.getInstance();
    expect(response.requestId, 'req_fixture');
    expect(response.data.name, 'DD');
    expect(response.data.apiBaseUrl.toString(), 'https://chat.test/api/v1');
    expect(response.data.features.calls, isTrue);
    expect(response.data.features.registrationMode, 'open');
  });

  test('API errors preserve requestId without exposing response body', () async {
    final client = ApiClient(
      origin: Uri.parse('https://chat.test'),
      httpClient: MockClient((_) async {
        return http.Response(
          '''{"error":{"code":"NOT_READY","message":"Temporarily unavailable","requestId":"req_error"},"secret":"must-not-leak"}''',
          503,
          headers: {'x-request-id': 'req_header'},
        );
      }),
    );
    addTearDown(client.close);

    try {
      await client.getInstance();
      fail('expected ApiException');
    } on ApiException catch (error) {
      expect(error.statusCode, 503);
      expect(error.code, 'NOT_READY');
      expect(error.requestId, 'req_error');
      expect(error.toString(), isNot(contains('must-not-leak')));
    }
  });

  test('rejects invalid API origin before making requests', () {
    expect(
      () => ApiClient(origin: Uri.parse('file:///tmp/api')),
      throwsArgumentError,
    );
  });
}
