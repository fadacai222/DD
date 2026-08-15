import 'push_notification_content.dart';

enum AndroidBackgroundPushResult {
  displayed,
  ignoredInvalidPayload,
  firebaseInitializationFailed,
  notificationDisplayFailed,
  unexpectedFailure,
}

typedef AndroidBackgroundNotificationDisplay =
    Future<bool> Function(PushNotificationContent content);

/// Runs the killed/background data-only Push path without depending on any UI
/// context. The production background handler injects Firebase initialization
/// and Android local-notification delivery; tests can exercise the parser and
/// failure classification without a Flutter view or Activity.
Future<AndroidBackgroundPushResult> processAndroidBackgroundPush({
  required Map<String, dynamic> data,
  required Future<void> Function() initializeFirebase,
  required AndroidBackgroundNotificationDisplay displayNotification,
}) async {
  try {
    try {
      await initializeFirebase();
    } catch (_) {
      return AndroidBackgroundPushResult.firebaseInitializationFailed;
    }

    final content = PushNotificationContent.fromData(
      Map<String, dynamic>.from(data),
    );
    if (content == null) {
      return AndroidBackgroundPushResult.ignoredInvalidPayload;
    }

    try {
      final displayed = await displayNotification(content);
      return displayed
          ? AndroidBackgroundPushResult.displayed
          : AndroidBackgroundPushResult.notificationDisplayFailed;
    } catch (_) {
      return AndroidBackgroundPushResult.notificationDisplayFailed;
    }
  } catch (_) {
    return AndroidBackgroundPushResult.unexpectedFailure;
  }
}
