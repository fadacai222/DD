import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../../../core/logging/client_log.dart';
import '../../../core/notifications/app_notification_service.dart';
import '../data/push_api_client.dart';
import 'push_notification_content.dart';

@pragma('vm:entry-point')
Future<void> ddFirebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
    final content = PushNotificationContent.fromData(
      Map<String, dynamic>.from(message.data),
    );
    if (content == null) return;
    await AppNotificationService.shared.initialize(requestPermission: false);
    await AppNotificationService.shared.showMessage(
      senderName: content.senderName.isEmpty ? 'DD' : content.senderName,
      preview: content.preview.isEmpty ? '你有新的动态' : content.preview,
      conversationId: content.conversationId,
      senderUserId: content.senderUserId.isEmpty ? null : content.senderUserId,
      avatarUrl: content.avatarUrl,
      notificationData: content.navigationData,
    );
  } catch (_) {
    // A background push failure must not crash or relaunch the client process.
  }
}

final class PushRegistrationService {
  PushRegistrationService({
    PushApiClient? apiClient,
    this.onNotificationOpened,
    this.onNotificationReceived,
  }) : _apiClient = apiClient ?? PushApiClient();

  final PushApiClient _apiClient;
  final void Function(Map<String, dynamic> data)? onNotificationOpened;
  final void Function(Map<String, dynamic> data)? onNotificationReceived;
  StreamSubscription<String>? _tokenSubscription;
  StreamSubscription<RemoteMessage>? _foregroundSubscription;
  StreamSubscription<RemoteMessage>? _openedSubscription;
  StreamSubscription<Map<String, dynamic>>? _localOpenedSubscription;
  Uri? _origin;
  String? _accessToken;
  bool _started = false;

  static const String _apiKey = String.fromEnvironment('DD_FIREBASE_API_KEY');
  static const String _appId = String.fromEnvironment('DD_FIREBASE_APP_ID');
  static const String _projectId = String.fromEnvironment(
    'DD_FIREBASE_PROJECT_ID',
  );
  static const String _senderId = String.fromEnvironment(
    'DD_FIREBASE_MESSAGING_SENDER_ID',
  );
  static const String _storageBucket = String.fromEnvironment(
    'DD_FIREBASE_STORAGE_BUCKET',
  );
  static const String _apnsBundleId = String.fromEnvironment(
    'DD_APNS_BUNDLE_ID',
  );
  static const String _iosProvider = String.fromEnvironment(
    'DD_IOS_PUSH_PROVIDER',
    defaultValue: 'FCM',
  );

  static bool get hasDartFirebaseOptions =>
      _apiKey.trim().isNotEmpty &&
      _appId.trim().isNotEmpty &&
      _projectId.trim().isNotEmpty &&
      _senderId.trim().isNotEmpty;

  static bool get isSupportedPlatform {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  static Future<void> prepareBackgroundMessaging() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    FirebaseMessaging.onBackgroundMessage(ddFirebaseMessagingBackgroundHandler);
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }
    } catch (error, stackTrace) {
      await ClientLog.error(
        'Firebase startup initialization failed; background push is unavailable.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> start({required Uri origin, required String accessToken}) async {
    _origin = origin;
    _accessToken = accessToken;
    if (_started || !isSupportedPlatform) return;
    _started = true;
    try {
      await AppNotificationService.shared.initialize(requestPermission: false);
      _localOpenedSubscription ??= AppNotificationService.shared.notificationOpens
          .listen((data) => onNotificationOpened?.call(data));
      final pendingLocalOpen = AppNotificationService.shared
          .takePendingLaunchData();
      if (pendingLocalOpen != null) {
        onNotificationOpened?.call(pendingLocalOpen);
      }
      await _ensureFirebase();
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, badge: true, sound: true);
      await _registerCurrentTokens(messaging);
      _tokenSubscription = messaging.onTokenRefresh.listen((token) {
        unawaited(_registerFCMToken(token));
      });
      _foregroundSubscription = FirebaseMessaging.onMessage.listen((message) {
        if (message.data.isNotEmpty) {
          onNotificationReceived?.call(Map<String, dynamic>.from(message.data));
        }
        unawaited(_showForegroundNotification(message));
      });
      _openedSubscription = FirebaseMessaging.onMessageOpenedApp.listen(
        _handleNotificationOpened,
      );
      final initialMessage = await messaging.getInitialMessage();
      if (initialMessage != null) {
        _handleNotificationOpened(initialMessage);
      }
    } catch (error, stackTrace) {
      _started = false;
      await ClientLog.error(
        'Push registration failed; messaging remains available without background push.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> updateSession({
    required Uri origin,
    required String accessToken,
  }) async {
    _origin = origin;
    _accessToken = accessToken;
    if (!_started) {
      await start(origin: origin, accessToken: accessToken);
      return;
    }
    if (!isSupportedPlatform) return;
    try {
      await _registerCurrentTokens(FirebaseMessaging.instance);
    } catch (error, stackTrace) {
      await ClientLog.error(
        'Push token refresh after session update failed.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _ensureFirebase() async {
    if (Firebase.apps.isNotEmpty) return;
    if (hasDartFirebaseOptions) {
      await Firebase.initializeApp(
        options: FirebaseOptions(
          apiKey: _apiKey,
          appId: _appId,
          messagingSenderId: _senderId,
          projectId: _projectId,
          storageBucket: _storageBucket.trim().isEmpty
              ? null
              : _storageBucket.trim(),
        ),
      );
      return;
    }
    // Android/iOS production builds should prefer their native Firebase config
    // files (google-services.json / GoogleService-Info.plist). This keeps public
    // client config out of build scripts and lets Firebase initialize exactly
    // like the platform SDK expects.
    await Firebase.initializeApp();
  }

  Future<void> _registerCurrentTokens(FirebaseMessaging messaging) async {
    final useDirectApns =
        defaultTargetPlatform == TargetPlatform.iOS &&
        _iosProvider.trim().toUpperCase() == 'APNS';
    if (useDirectApns) {
      if (_apnsBundleId.trim().isEmpty) {
        await ClientLog.error(
          'DD_IOS_PUSH_PROVIDER=APNS requires DD_APNS_BUNDLE_ID; push registration skipped.',
        );
        return;
      }
      final apnsToken = await messaging.getAPNSToken();
      if (apnsToken != null && apnsToken.trim().isNotEmpty) {
        await _registerEndpoint(
          provider: 'APNS',
          endpoint: apnsToken,
          appId: _apnsBundleId.trim(),
          environment: kReleaseMode ? 'PRODUCTION' : 'SANDBOX',
        );
      }
      return;
    }

    final fcmToken = await messaging.getToken();
    if (fcmToken != null && fcmToken.trim().isNotEmpty) {
      await _registerFCMToken(fcmToken);
    }
  }

  Future<void> _registerFCMToken(String token) async {
    var appId = _projectId.trim();
    if (appId.isEmpty && Firebase.apps.isNotEmpty) {
      appId = Firebase.app().options.projectId.trim();
    }
    if (appId.isEmpty) {
      await ClientLog.error(
        'Firebase projectId is unavailable; FCM token registration skipped.',
      );
      return;
    }
    await _registerEndpoint(
      provider: 'FCM',
      endpoint: token,
      appId: appId,
      environment: kReleaseMode ? 'PRODUCTION' : 'SANDBOX',
    );
  }

  Future<void> _registerEndpoint({
    required String provider,
    required String endpoint,
    required String appId,
    required String environment,
  }) async {
    final origin = _origin;
    final token = _accessToken;
    if (origin == null || token == null || token.trim().isEmpty) return;
    await _apiClient.registerEndpoint(
      origin: origin,
      accessToken: token,
      provider: provider,
      endpoint: endpoint,
      appId: appId,
      environment: environment,
    );
  }

  void _handleNotificationOpened(RemoteMessage message) {
    if (message.data.isEmpty) return;
    onNotificationOpened?.call(Map<String, dynamic>.from(message.data));
  }

  Future<void> _showForegroundNotification(RemoteMessage message) async {
    final data = Map<String, dynamic>.from(message.data);
    final notification = message.notification;
    final notificationTitle = notification?.title?.trim() ?? '';
    final notificationBody = notification?.body?.trim() ?? '';
    if ((data['title']?.toString().trim() ?? '').isEmpty &&
        notificationTitle.isNotEmpty) {
      data['title'] = notificationTitle;
    }
    if ((data['body']?.toString().trim() ?? '').isEmpty &&
        notificationBody.isNotEmpty) {
      data['body'] = notificationBody;
    }
    final content = PushNotificationContent.fromData(data);
    if (content == null) return;
    await AppNotificationService.shared.showMessage(
      senderName: content.senderName.isEmpty ? 'DD' : content.senderName,
      preview: content.preview.isEmpty ? '你有新的动态' : content.preview,
      conversationId: content.conversationId,
      origin: _origin,
      accessToken: _accessToken,
      senderUserId: content.senderUserId.isEmpty ? null : content.senderUserId,
      avatarUrl: content.avatarUrl,
      notificationData: content.navigationData,
    );
  }

  Future<void> dispose() async {
    await _tokenSubscription?.cancel();
    await _foregroundSubscription?.cancel();
    await _openedSubscription?.cancel();
    await _localOpenedSubscription?.cancel();
    _tokenSubscription = null;
    _foregroundSubscription = null;
    _openedSubscription = null;
    _localOpenedSubscription = null;
    _apiClient.close();
  }
}
