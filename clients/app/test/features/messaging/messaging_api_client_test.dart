import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:im_client/features/messaging/data/messaging_api_client.dart';

void main() {
  test(
    'empty successful messaging response reports a meaningful format error',
    () async {
      final api = MessagingApiClient(
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/v1/conversations');
          return http.Response('', 200);
        }),
      );
      addTearDown(api.close);

      expect(
        () => api.listConversations(
          origin: Uri.parse('http://127.0.0.1:18473'),
          accessToken: 'test-token',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            '消息服务返回了空响应。',
          ),
        ),
      );
    },
  );
}
