import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/push/application/android_background_push.dart';
import 'package:im_client/features/push/application/push_notification_content.dart';
import 'package:im_client/features/push/application/push_registration_service.dart';

void main() {
  group('Android killed/background Push processor', () {
    test('parses data-only payload without UI context and preserves navigation', () async {
      var initialized = false;
      PushNotificationContent? displayed;

      final result = await processAndroidBackgroundPush(
        data: <String, dynamic>{
          'eventType': 'MESSAGE_CREATED',
          'resourceId': 'message-1',
          'conversationId': 'conversation-1',
          'conversationType': 'DIRECT',
          'recipientUserId': 'user-a',
          'senderUserId': 'user-b',
          'title': 'Alice',
          'body': 'hello',
        },
        initializeFirebase: () async => initialized = true,
        displayNotification: (content) async {
          displayed = content;
          return true;
        },
      );

      expect(result, AndroidBackgroundPushResult.displayed);
      expect(initialized, isTrue);
      expect(displayed, isNotNull);
      expect(displayed!.conversationId, 'conversation-1');
      expect(displayed!.navigationData['eventType'], 'MESSAGE_CREATED');
      expect(displayed!.navigationData['resourceId'], 'message-1');
      expect(displayed!.navigationData['recipientUserId'], 'user-a');
    });

    test('malformed data is ignored without display or crash', () async {
      var displayCalls = 0;

      final result = await processAndroidBackgroundPush(
        data: const <String, dynamic>{'unexpected': 'value'},
        initializeFirebase: () async {},
        displayNotification: (_) async {
          displayCalls++;
          return true;
        },
      );

      expect(result, AndroidBackgroundPushResult.ignoredInvalidPayload);
      expect(displayCalls, 0);
    });

    test('Firebase initialization failure is classified before display', () async {
      var displayCalls = 0;

      final result = await processAndroidBackgroundPush(
        data: const <String, dynamic>{'title': 'DD', 'body': 'message'},
        initializeFirebase: () async => throw StateError('firebase unavailable'),
        displayNotification: (_) async {
          displayCalls++;
          return true;
        },
      );

      expect(result, AndroidBackgroundPushResult.firebaseInitializationFailed);
      expect(displayCalls, 0);
    });

    test('notification display failure is classified and never escapes', () async {
      final result = await processAndroidBackgroundPush(
        data: const <String, dynamic>{'title': 'DD', 'body': 'message'},
        initializeFirebase: () async {},
        displayNotification: (_) async => false,
      );

      expect(result, AndroidBackgroundPushResult.notificationDisplayFailed);
    });
  });

  test('Android foreground owns one app-rendered notification path', () {
    expect(
      PushRegistrationService.shouldRenderSystemNotificationInForeground(
        TargetPlatform.android,
      ),
      isTrue,
    );
  });
}
