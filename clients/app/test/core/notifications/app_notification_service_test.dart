import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/notifications/app_notification_service.dart';

void main() {
  test('Android notification small icon stays bound to a real DD resource', () {
    expect(AppNotificationService.androidSmallIcon, 'ic_stat_dd');
    expect(AppNotificationService.androidChannelId, 'dd_messages_v2');
    expect(AppNotificationService.androidChannelId, isNot('dd_messages'));
    final resource = File('android/app/src/main/res/drawable/ic_stat_dd.xml');
    expect(resource.existsSync(), isTrue);
    final xml = resource.readAsStringSync();
    expect(xml, contains('android:fillColor="#FFFFFFFF"'));
    expect(xml, contains('android:fillType="evenOdd"'));
    expect(xml, contains('M1.5,4'));
    expect(xml, contains('M12.5,4'));
    expect(xml, contains('<vector'));
  });

  test('Android notification diagnostics distinguish permission and channel blocks', () {
    expect(
      AppNotificationService.classifyAndroidDeliveryStatus(
        appNotificationsEnabled: true,
        channelPresent: true,
        channelImportance: Importance.max,
      ),
      AndroidNotificationDeliveryStatus.ready,
    );
    expect(
      AppNotificationService.classifyAndroidDeliveryStatus(
        appNotificationsEnabled: false,
        channelPresent: true,
        channelImportance: Importance.max,
      ),
      AndroidNotificationDeliveryStatus.appNotificationsDisabled,
    );
    expect(
      AppNotificationService.classifyAndroidDeliveryStatus(
        appNotificationsEnabled: true,
        channelPresent: true,
        channelImportance: Importance.none,
      ),
      AndroidNotificationDeliveryStatus.channelDisabled,
    );
    expect(
      AppNotificationService.classifyAndroidDeliveryStatus(
        appNotificationsEnabled: true,
        channelPresent: false,
        channelImportance: null,
      ),
      AndroidNotificationDeliveryStatus.channelMissing,
    );
  });
}
