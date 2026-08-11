import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:im_client/features/messaging/data/link_preview_api_client.dart';
import 'package:im_client/features/messaging/data/messaging_api_client.dart';

void main() {
  test('link preview request is authenticated and URL encoded', () async {
    final client = LinkPreviewApiClient(
      httpClient: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/v1/link-preview');
        expect(
          request.url.queryParameters['url'],
          'https://example.com/a?x=1&y=2',
        );
        expect(request.headers['authorization'], 'Bearer access-token');
        return http.Response(
          jsonEncode(<String, Object>{
            'data': <String, Object>{
              'url': 'https://example.com/a?x=1&y=2',
              'siteName': 'Example',
              'title': 'Preview title',
              'description': 'Preview description',
            },
            'requestId': 'req-1',
          }),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }),
    );
    addTearDown(client.close);

    final preview = await client.getPreview(
      origin: Uri.parse('https://dd.example/'),
      accessToken: 'access-token',
      url: Uri.parse('https://example.com/a?x=1&y=2'),
    );

    expect(preview.siteName, 'Example');
    expect(preview.title, 'Preview title');
    expect(preview.description, 'Preview description');
  });

  test('401 remains a MessagingApiException for coordinator refresh', () async {
    final client = LinkPreviewApiClient(
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode(<String, Object>{
            'error': <String, Object>{
              'code': 'UNAUTHORIZED',
              'message': 'expired',
            },
            'requestId': 'req-401',
          }),
          401,
        ),
      ),
    );
    addTearDown(client.close);

    await expectLater(
      client.getPreview(
        origin: Uri.parse('https://dd.example/'),
        accessToken: 'expired-token',
        url: Uri.parse('https://example.com/'),
      ),
      throwsA(
        isA<MessagingApiException>()
            .having((error) => error.statusCode, 'statusCode', 401)
            .having((error) => error.code, 'code', 'UNAUTHORIZED'),
      ),
    );
  });
}
