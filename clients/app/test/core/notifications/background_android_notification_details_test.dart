import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/notifications/background_android_notification_details.dart';

void main() {
  test('background call notification uses Android call semantics', () {
    final details = buildAndroidBackgroundNotificationDetails(
      channelId: 'dd_calls_v1',
      channelName: 'DD 来电',
      channelDescription: '通话提醒',
      smallIcon: 'ic_stat_dd',
      senderName: 'Bob',
      body: '正在邀请你语音通话',
      avatarBytes: null,
      isCall: true,
    );

    expect(details.channelId, 'dd_calls_v1');
    expect(details.category, AndroidNotificationCategory.call);
    expect(details.fullScreenIntent, isTrue);
    expect(details.playSound, isTrue);
    expect(details.importance, Importance.max);
    expect(details.priority, Priority.max);
  });

  test('background message notification stays a quiet message', () {
    final details = buildAndroidBackgroundNotificationDetails(
      channelId: 'dd_messages_v2',
      channelName: 'DD 新消息',
      channelDescription: '消息提醒',
      smallIcon: 'ic_stat_dd',
      senderName: 'Bob',
      body: 'hello',
      avatarBytes: null,
    );

    expect(details.category, AndroidNotificationCategory.message);
    expect(details.fullScreenIntent, isFalse);
    expect(details.playSound, isFalse);
  });
}
