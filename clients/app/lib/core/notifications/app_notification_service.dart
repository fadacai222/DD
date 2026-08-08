import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

final class AppNotificationService {
  AppNotificationService({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const _channelId = 'dd_messages';
  static const _channelName = 'DD 新消息';
  static const _channelDescription = '好友消息与会话提醒';

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;
  int _nextId = 1000;

  bool get initialized => _initialized;

  Future<void> initialize() async {
    if (_initialized || kIsWeb) return;
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.windows) {
      return;
    }

    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_dd'),
        windows: WindowsInitializationSettings(
          appName: 'DD',
          appUserModelId: 'OpenIMX.DD.Client',
          guid: 'd4b226ae-97ab-4bb7-9b64-a816e8bb78ac',
        ),
      );
      final initialized = await _plugin.initialize(settings: settings);
      _initialized = initialized ?? false;
      if (!_initialized) return;

      if (defaultTargetPlatform == TargetPlatform.android) {
        await _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.requestNotificationsPermission();
      }
    } catch (_) {
      // Tests, unsupported embedders and stale locally cached runners may not
      // expose a notification platform implementation. Messaging must survive.
      _initialized = false;
    }
  }

  Future<void> showMessage({
    required String senderName,
    required String preview,
    required String conversationId,
  }) async {
    if (!_initialized) return;
    final body = preview.trim().isEmpty ? '你收到了一条新消息' : preview.trim();
    final id = _nextId++ & 0x7FFFFFFF;
    try {
      await _plugin.show(
        id: id,
        title: senderName,
        body: body,
        payload: conversationId,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDescription,
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.message,
            visibility: NotificationVisibility.private,
          ),
          windows: WindowsNotificationDetails(),
        ),
      );
    } catch (_) {
      // Notification failures must never break realtime message sync.
    }
  }
}
