import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/messaging/application/message_notification_preview.dart';

void main() {
  test('notification preview never exposes protocol media type tags', () {
    expect(messageNotificationPreview(messageType: 'IMAGE'), '图片');
    expect(messageNotificationPreview(messageType: 'GIF'), 'GIF');
    expect(messageNotificationPreview(messageType: 'STICKER'), '贴纸');
    expect(messageNotificationPreview(messageType: 'STICKER_PACK'), '表情包');
    expect(messageNotificationPreview(messageType: 'VIDEO'), '视频');
    expect(messageNotificationPreview(messageType: 'VOICE'), '语音消息');
    expect(messageNotificationPreview(messageType: 'FILE'), '文件');
    expect(messageNotificationPreview(messageType: 'SOMETHING_NEW'), '新消息');
  });

  test('text and system notifications preserve readable message text', () {
    expect(
      messageNotificationPreview(messageType: 'TEXT', text: '  你好  '),
      '你好',
    );
    expect(
      messageNotificationPreview(messageType: 'SYSTEM', text: '群名称已修改'),
      '群名称已修改',
    );
    expect(messageNotificationPreview(messageType: 'TEXT'), '新消息');
  });
}
