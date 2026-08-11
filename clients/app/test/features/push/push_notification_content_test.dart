import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/push/application/push_notification_content.dart';

void main() {
  test('data-only FCM payload preserves sender avatar and navigation data', () {
    final content = PushNotificationContent.fromData(<String, dynamic>{
      'eventType': 'MESSAGE_CREATED',
      'resourceId': 'message-1',
      'conversationId': 'conversation-1',
      'senderUserId': 'user-2',
      'title': 'tisen05',
      'body': '你好',
      'avatarUrl':
          'https://chat.example.com/push-assets/avatars/11111111-2222-3333-4444-555555555555?expires=2026-08-13T04%3A00%3A00Z&sig=abc',
    });

    expect(content, isNotNull);
    expect(content!.senderName, 'tisen05');
    expect(content.preview, '你好');
    expect(content.conversationId, 'conversation-1');
    expect(content.senderUserId, 'user-2');
    expect(content.avatarUrl?.scheme, 'https');
    expect(content.navigationData['eventType'], 'MESSAGE_CREATED');
    expect(content.navigationData['resourceId'], 'message-1');
  });

  test('push avatar URL allows private HTTP only for LAN development', () {
    final publicHttp = PushNotificationContent.fromData(<String, dynamic>{
      'title': 'tisen05',
      'body': '你好',
      'avatarUrl': 'http://chat.example.com/avatar.png',
    });
    final privateHttp = PushNotificationContent.fromData(<String, dynamic>{
      'title': 'tisen05',
      'body': '你好',
      'avatarUrl': 'http://192.168.1.20:18473/avatar.png',
    });

    expect(publicHttp, isNotNull);
    expect(publicHttp!.avatarUrl, isNull);
    expect(privateHttp, isNotNull);
    expect(privateHttp!.avatarUrl?.scheme, 'http');
  });

  test('empty data payload is not rendered as a notification', () {
    expect(PushNotificationContent.fromData(const <String, dynamic>{}), isNull);
  });
}
