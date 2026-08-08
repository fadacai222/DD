import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'core/notifications/app_notification_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Android 13+ only permits the runtime notification prompt after the app is
  // launched; requesting it here gives a fresh install permission immediately
  // instead of waiting until after login.
  unawaited(AppNotificationService.shared.initialize());
  runApp(const ImClientApp());
}
