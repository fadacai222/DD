import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:im_client/features/messaging/data/messaging_api_client.dart';

void main() {
  test('Live Photo IMAGE request carries paired motion metadata', () async {
    late Map<String, dynamic> sentBody;
    final api = MessagingApiClient(
      httpClient: MockClient((request) async {
        sentBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'data': {
              'id': 'message-live-1',
              'conversationId': 'conversation-1',
              'sequence': 1,
              'senderUserId': 'user-a',
              'senderDeviceId': 'device-a',
              'clientMessageId': 'client-live-0001',
              'type': 'IMAGE',
              'content': {
                'mediaId': 'media-still-1',
                'livePhoto': true,
                'livePhotoMotionMediaId': 'media-motion-1',
                'width': 3024,
                'height': 4032,
              },
              'createdAt': '2026-08-14T00:00:00Z',
              'editVersion': 0,
            },
            'requestId': 'req-live-1',
          }),
          201,
        );
      }),
    );
    addTearDown(api.close);

    final message = await api.sendImage(
      origin: Uri.parse('https://api.example.test'),
      accessToken: 'token',
      conversationId: 'conversation-1',
      clientMessageId: 'client-live-0001',
      mediaId: 'media-still-1',
      width: 3024,
      height: 4032,
      livePhoto: true,
      livePhotoMotionMediaId: 'media-motion-1',
    );

    final content = sentBody['content'] as Map<String, dynamic>;
    expect(sentBody['type'], 'IMAGE');
    expect(content['mediaId'], 'media-still-1');
    expect(content['livePhoto'], isTrue);
    expect(content['livePhotoMotionMediaId'], 'media-motion-1');
    expect(message.content?.isLivePhoto, isTrue);
  });

  test('legacy IMAGE request omits Live Photo fields', () async {
    late Map<String, dynamic> sentBody;
    final api = MessagingApiClient(
      httpClient: MockClient((request) async {
        sentBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'data': {
              'id': 'message-image-1',
              'conversationId': 'conversation-1',
              'sequence': 1,
              'senderUserId': 'user-a',
              'senderDeviceId': 'device-a',
              'clientMessageId': 'client-image-0001',
              'type': 'IMAGE',
              'content': {
                'mediaId': 'media-image-1',
                'width': 1080,
                'height': 1440,
              },
              'createdAt': '2026-08-14T00:00:00Z',
              'editVersion': 0,
            },
            'requestId': 'req-image-1',
          }),
          201,
        );
      }),
    );
    addTearDown(api.close);

    await api.sendImage(
      origin: Uri.parse('https://api.example.test'),
      accessToken: 'token',
      conversationId: 'conversation-1',
      clientMessageId: 'client-image-0001',
      mediaId: 'media-image-1',
      width: 1080,
      height: 1440,
    );

    final content = sentBody['content'] as Map<String, dynamic>;
    expect(content.containsKey('livePhoto'), isFalse);
    expect(content.containsKey('livePhotoMotionMediaId'), isFalse);
  });

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
