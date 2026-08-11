import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'core/logging/client_log.dart';
import 'core/notifications/app_notification_service.dart';
import 'features/push/application/push_registration_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    unawaited(
      ClientLog.error(
        'Flutter framework error: ${details.exceptionAsString()}',
        error: details.exception,
        stackTrace: details.stack,
      ),
    );
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    unawaited(
      ClientLog.error(
        'Unhandled platform error',
        error: error,
        stackTrace: stack,
      ),
    );
    return false;
  };
  unawaited(ClientLog.info('DD client started'));
  await PushRegistrationService.prepareBackgroundMessaging();
  // Android 13+ only permits the runtime notification prompt after the app is
  // launched; requesting it here gives a fresh install permission immediately
  // instead of waiting until after login.
  unawaited(AppNotificationService.shared.initialize());
  runApp(const ImClientApp());
}
