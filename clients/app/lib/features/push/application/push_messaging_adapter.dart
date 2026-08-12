import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import '../../../core/notifications/notification_authorization.dart';

final class PushRemoteMessage {
  const PushRemoteMessage({
    required this.data,
    this.notificationTitle = '',
    this.notificationBody = '',
  });

  factory PushRemoteMessage.fromFirebase(RemoteMessage message) => PushRemoteMessage(
    data: Map<String, dynamic>.from(message.data),
    notificationTitle: message.notification?.title?.trim() ?? '',
    notificationBody: message.notification?.body?.trim() ?? '',
  );

  final Map<String, dynamic> data;
  final String notificationTitle;
  final String notificationBody;
}

abstract interface class PushMessagingAdapter {
  Future<void> initialize();

  String get projectId;

  Future<NotificationAuthorizationState> authorizationState();

  Future<NotificationAuthorizationState> requestAuthorization({
    required bool provisional,
  });

  Future<void> setForegroundPresentation({
    required bool alert,
    required bool badge,
    required bool sound,
  });

  Future<String?> getFcmToken();

  Future<String?> getApnsToken();

  Stream<String> get tokenRefresh;

  Stream<PushRemoteMessage> get foregroundMessages;

  Stream<PushRemoteMessage> get openedMessages;

  Future<PushRemoteMessage?> initialMessage();
}

final class FirebasePushMessagingAdapter implements PushMessagingAdapter {
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

  static bool get hasDartFirebaseOptions =>
      _apiKey.trim().isNotEmpty &&
      _appId.trim().isNotEmpty &&
      _projectId.trim().isNotEmpty &&
      _senderId.trim().isNotEmpty;

  @override
  Future<void> initialize() async {
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
    // Production native builds use google-services.json / GoogleService-Info.plist.
    await Firebase.initializeApp();
  }

  @override
  String get projectId {
    if (_projectId.trim().isNotEmpty) return _projectId.trim();
    if (Firebase.apps.isEmpty) return '';
    return Firebase.app().options.projectId.trim();
  }

  @override
  Future<NotificationAuthorizationState> authorizationState() async =>
      _mapAuthorizationStatus(
        (await FirebaseMessaging.instance.getNotificationSettings())
            .authorizationStatus,
      );

  @override
  Future<NotificationAuthorizationState> requestAuthorization({
    required bool provisional,
  }) async => _mapAuthorizationStatus(
    (
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: provisional,
      )
    ).authorizationStatus,
  );

  @override
  Future<void> setForegroundPresentation({
    required bool alert,
    required bool badge,
    required bool sound,
  }) => FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
    alert: alert,
    badge: badge,
    sound: sound,
  );

  @override
  Future<String?> getFcmToken() => FirebaseMessaging.instance.getToken();

  @override
  Future<String?> getApnsToken() => FirebaseMessaging.instance.getAPNSToken();

  @override
  Stream<String> get tokenRefresh => FirebaseMessaging.instance.onTokenRefresh;

  @override
  Stream<PushRemoteMessage> get foregroundMessages =>
      FirebaseMessaging.onMessage.map(PushRemoteMessage.fromFirebase);

  @override
  Stream<PushRemoteMessage> get openedMessages =>
      FirebaseMessaging.onMessageOpenedApp.map(PushRemoteMessage.fromFirebase);

  @override
  Future<PushRemoteMessage?> initialMessage() async {
    final message = await FirebaseMessaging.instance.getInitialMessage();
    return message == null ? null : PushRemoteMessage.fromFirebase(message);
  }

  NotificationAuthorizationState _mapAuthorizationStatus(
    AuthorizationStatus status,
  ) => switch (status) {
    AuthorizationStatus.authorized => NotificationAuthorizationState.granted,
    AuthorizationStatus.provisional =>
      NotificationAuthorizationState.provisional,
    AuthorizationStatus.denied => NotificationAuthorizationState.denied,
    AuthorizationStatus.notDetermined =>
      NotificationAuthorizationState.notDetermined,
  };
}
