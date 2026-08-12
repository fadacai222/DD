import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../../../core/logging/client_log.dart';
import '../../../core/notifications/app_notification_service.dart';
import '../../../core/notifications/notification_authorization.dart';
import '../data/push_api_client.dart';
import 'ios_push_native_bridge.dart';
import 'push_endpoint_lifecycle.dart';
import 'push_messaging_adapter.dart';
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
      badgeCount: content.badgeCount,
    );
  } catch (_) {
    // Background Push failure must never crash or relaunch the client process.
  }
}

final class PushRegistrationService {
  PushRegistrationService({
    PushApiClient? apiClient,
    PushMessagingAdapter? messaging,
    IosPushNativeAdapter? iosNative,
    TargetPlatform? targetPlatform,
  }) : _apiClient = apiClient ?? PushApiClient(),
       _messaging = messaging ?? FirebasePushMessagingAdapter(),
       _iosNative = iosNative ?? IosPushNativeBridge(),
       _targetPlatform = targetPlatform ?? defaultTargetPlatform {
    _endpointLifecycle = PushEndpointLifecycle(gateway: _apiClient);
  }

  static final PushRegistrationService shared = PushRegistrationService();

  final PushApiClient _apiClient;
  final PushMessagingAdapter _messaging;
  final IosPushNativeAdapter _iosNative;
  final TargetPlatform _targetPlatform;
  late final PushEndpointLifecycle _endpointLifecycle;

  void Function(Map<String, dynamic> data)? _onNotificationOpened;
  void Function(Map<String, dynamic> data)? _onNotificationReceived;
  Object? _callbackOwner;
  final List<Map<String, dynamic>> _pendingOpened = <Map<String, dynamic>>[];

  StreamSubscription<String>? _tokenSubscription;
  StreamSubscription<PushRemoteMessage>? _foregroundSubscription;
  StreamSubscription<PushRemoteMessage>? _openedSubscription;
  StreamSubscription<Map<String, dynamic>>? _localOpenedSubscription;
  StreamSubscription<String>? _nativeTokenSubscription;
  StreamSubscription<Map<String, dynamic>>? _nativeOpenedSubscription;
  StreamSubscription<Map<String, dynamic>>? _nativeForegroundSubscription;

  Uri? _origin;
  String? _accessToken;
  String? _userId;
  int _sessionGeneration = 0;
  bool _runtimeStarted = false;
  bool _messagingReady = false;
  bool _initialMessageConsumed = false;
  PushPreferences? _preferences;

  static const String _apnsBundleId = String.fromEnvironment(
    'DD_APNS_BUNDLE_ID',
    defaultValue: 'org.openimx.client',
  );
  static const String _iosProvider = String.fromEnvironment(
    'DD_IOS_PUSH_PROVIDER',
    defaultValue: 'FCM',
  );

  static bool isTargetSupported(TargetPlatform platform) =>
      platform == TargetPlatform.android || platform == TargetPlatform.iOS;

  static bool shouldRenderSystemNotificationInForeground(
    TargetPlatform platform,
  ) => platform != TargetPlatform.iOS;

  static bool get isSupportedPlatform {
    if (kIsWeb) return false;
    return isTargetSupported(defaultTargetPlatform);
  }

  bool get _supported => !kIsWeb && isTargetSupported(_targetPlatform);
  bool get _isIos => !kIsWeb && _targetPlatform == TargetPlatform.iOS;
  bool get _useDirectApns =>
      _isIos && _iosProvider.trim().toUpperCase() == 'APNS';

  PushPreferences? get preferences => _preferences;

  Object bindCallbacks({
    required void Function(Map<String, dynamic> data) onNotificationOpened,
    required void Function(Map<String, dynamic> data) onNotificationReceived,
  }) {
    final owner = Object();
    _callbackOwner = owner;
    _onNotificationOpened = onNotificationOpened;
    _onNotificationReceived = onNotificationReceived;
    if (_pendingOpened.isNotEmpty) {
      final pending = List<Map<String, dynamic>>.from(_pendingOpened);
      _pendingOpened.clear();
      for (final data in pending) {
        _emitOpened(data);
      }
    }
    return owner;
  }

  void unbindCallbacks(Object owner) {
    if (!identical(_callbackOwner, owner)) return;
    _callbackOwner = null;
    _onNotificationOpened = null;
    _onNotificationReceived = null;
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

  Future<void> start({
    required Uri origin,
    required String accessToken,
    required String userId,
    required String deviceId,
  }) async {
    if (!_supported || accessToken.trim().isEmpty) return;
    final session = PushEndpointSession(
      origin: origin,
      accessToken: accessToken,
      userId: userId.trim(),
      deviceId: deviceId.trim(),
    );
    try {
      final generation = await _endpointLifecycle.activateSession(session);
      _origin = origin;
      _accessToken = accessToken;
      _userId = userId.trim();
      _sessionGeneration = generation;
      await _ensureRuntime();
      await _reconcile(allowPermissionPrompt: true);
      await _consumeInitialMessage();
    } catch (error, stackTrace) {
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
    required String userId,
    required String deviceId,
  }) => start(
    origin: origin,
    accessToken: accessToken,
    userId: userId,
    deviceId: deviceId,
  );

  Future<void> onAppResumed() async {
    if (!_supported || _origin == null || _accessToken == null) return;
    try {
      await _reconcile(allowPermissionPrompt: false);
    } catch (error, stackTrace) {
      await ClientLog.error(
        'Push reconciliation after app resume failed.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<NotificationAuthorizationState> authorizationState() async {
    if (!_supported) return NotificationAuthorizationState.unsupported;
    if (_isIos) {
      final native = await _iosNative.authorizationState();
      if (native != null) return native;
    }
    await _ensureMessaging();
    return _messaging.authorizationState();
  }

  Future<NotificationAuthorizationState> requestNotificationPermission({
    bool provisional = false,
  }) async {
    var current = await authorizationState();
    if (!current.canRequest) return current;

    if (_isIos) {
      final native = await _iosNative.requestAuthorization(
        provisional: provisional,
      );
      if (native != null) {
        current = native;
        if (current.canDeliver) {
          await _iosNative.registerRemoteNotifications();
        }
        return current;
      }
    }
    await _ensureMessaging();
    return _messaging.requestAuthorization(provisional: provisional);
  }

  Future<bool> openNotificationSettings() async {
    if (!_isIos) return false;
    return _iosNative.openNotificationSettings();
  }

  Future<void> handlePreferencesChanged(PushPreferences preferences) async {
    _preferences = preferences;
    if (_origin == null || _accessToken == null) return;
    if (!preferences.pushEnabled) {
      try {
        await _endpointLifecycle.disableEndpoint();
      } catch (error, stackTrace) {
        await ClientLog.error(
          'Push endpoint disable after preference change failed.',
          error: error,
          stackTrace: stackTrace,
        );
      }
      return;
    }
    await _reconcile(allowPermissionPrompt: true);
  }

  Future<void> setBadgeCount(int count) async {
    if (!_isIos) return;
    await _iosNative.setBadgeCount(count < 0 ? 0 : count);
  }

  /// Releases the current account's endpoint before account switch/logout.
  /// If this fails, the lifecycle intentionally retains ownership state so a
  /// later activation can retry instead of silently binding the token to B.
  Future<void> releaseCurrentEndpoint() async {
    await _endpointLifecycle.deactivateSession();
    _origin = null;
    _accessToken = null;
    _userId = null;
    _sessionGeneration = _endpointLifecycle.generation;
    _preferences = null;
  }

  Future<void> _ensureRuntime() async {
    if (_runtimeStarted) return;
    await AppNotificationService.shared.initialize(requestPermission: false);
    _localOpenedSubscription ??= AppNotificationService.shared.notificationOpens
        .listen(_emitOpened);
    final pendingLocalOpen = AppNotificationService.shared.takePendingLaunchData();
    if (pendingLocalOpen != null) {
      _emitOpened(pendingLocalOpen);
    }

    if (_isIos && _useDirectApns) {
      _nativeTokenSubscription ??= _iosNative.apnsTokenRefresh.listen(
        (token) => unawaited(_registerDirectApnsToken(token)),
        onError: (_) {},
      );
      _nativeOpenedSubscription ??= _iosNative.notificationTaps.listen(
        _emitOpened,
        onError: (_) {},
      );
      _nativeForegroundSubscription ??= _iosNative.foregroundNotifications
          .listen(_emitReceived, onError: (_) {});
    } else {
      await _ensureMessaging();
      _bindMessagingStreams();
    }
    _runtimeStarted = true;
  }

  Future<void> _ensureMessaging() async {
    if (_messagingReady) return;
    await _messaging.initialize();
    _messagingReady = true;
    if (_isIos) {
      // Firebase persists these options. Explicitly force them off so a remote
      // alert never appears as both an iOS banner and a DD in-app notification.
      await _messaging.setForegroundPresentation(
        alert: false,
        badge: false,
        sound: false,
      );
    }
    _bindMessagingStreams();
  }

  void _bindMessagingStreams() {
    if (!_messagingReady) return;
    _tokenSubscription ??= _messaging.tokenRefresh.listen((token) {
      if (_useDirectApns) {
        unawaited(_registerCurrentTokens(_sessionGeneration));
      } else {
        unawaited(_registerFcmToken(token, _sessionGeneration));
      }
    });
    _foregroundSubscription ??= _messaging.foregroundMessages.listen(
      _handleForegroundMessage,
    );
    _openedSubscription ??= _messaging.openedMessages.listen(
      (message) => _emitOpened(_mergedMessageData(message)),
    );
  }

  Future<void> _consumeInitialMessage() async {
    if (_initialMessageConsumed || !_messagingReady) return;
    _initialMessageConsumed = true;
    final initial = await _messaging.initialMessage();
    if (initial != null) {
      _emitOpened(_mergedMessageData(initial));
    }
  }

  Future<void> _reconcile({required bool allowPermissionPrompt}) async {
    final origin = _origin;
    final accessToken = _accessToken;
    if (origin == null || accessToken == null || accessToken.trim().isEmpty) {
      return;
    }

    final preferences = await _apiClient.getPreferences(
      origin: origin,
      accessToken: accessToken,
    );
    _preferences = preferences;
    if (!preferences.pushEnabled) {
      await _endpointLifecycle.disableEndpoint();
      return;
    }

    var permission = await authorizationState();
    if (permission.canRequest && allowPermissionPrompt) {
      // DD currently requests normal alert permission. Provisional delivery is
      // supported by the API but is not silently selected as product policy.
      permission = await requestNotificationPermission(provisional: false);
    }
    if (!permission.canDeliver) {
      await _endpointLifecycle.disableEndpoint();
      return;
    }
    if (_isIos && _useDirectApns) {
      await _iosNative.registerRemoteNotifications();
    }
    await _registerCurrentTokens(_sessionGeneration);
  }

  Future<void> _registerCurrentTokens(int generation) async {
    if (generation != _sessionGeneration) return;
    if (_useDirectApns) {
      if (_apnsBundleId.trim().isEmpty) {
        await ClientLog.error(
          'DD_IOS_PUSH_PROVIDER=APNS requires DD_APNS_BUNDLE_ID; push registration skipped.',
        );
        return;
      }
      var apnsToken = await _iosNative.getApnsToken();
      if (apnsToken == null || apnsToken.trim().isEmpty) {
        try {
          await _ensureMessaging();
          apnsToken = await _messaging.getApnsToken();
        } catch (_) {
          // Native direct-APNs remains valid without Firebase client config.
        }
      }
      if (apnsToken != null && apnsToken.trim().isNotEmpty) {
        await _registerDirectApnsToken(apnsToken, generation: generation);
      }
      return;
    }

    await _ensureMessaging();
    if (_isIos) {
      // APNs token is Firebase's Apple transport dependency. It is intentionally
      // not registered as a second DD endpoint when FCM is the selected provider.
      await _messaging.getApnsToken();
    }
    final fcmToken = await _messaging.getFcmToken();
    if (fcmToken != null && fcmToken.trim().isNotEmpty) {
      await _registerFcmToken(fcmToken, generation);
    }
  }

  Future<void> _registerFcmToken(String token, int generation) async {
    if (generation != _sessionGeneration || token.trim().isEmpty) return;
    final appId = _messaging.projectId.trim();
    if (appId.isEmpty) {
      await ClientLog.error(
        'Firebase projectId is unavailable; FCM token registration skipped.',
      );
      return;
    }
    await _endpointLifecycle.registerEndpoint(
      generation: generation,
      endpoint: PushEndpointRegistration(
        provider: 'FCM',
        endpoint: token,
        appId: appId,
        environment: kReleaseMode ? 'PRODUCTION' : 'SANDBOX',
      ),
    );
  }

  Future<void> _registerDirectApnsToken(
    String token, {
    int? generation,
  }) async {
    final expectedGeneration = generation ?? _sessionGeneration;
    if (expectedGeneration != _sessionGeneration || token.trim().isEmpty) return;
    if (_apnsBundleId.trim().isEmpty) return;
    await _endpointLifecycle.registerEndpoint(
      generation: expectedGeneration,
      endpoint: PushEndpointRegistration(
        provider: 'APNS',
        endpoint: token,
        appId: _apnsBundleId.trim(),
        environment: kReleaseMode ? 'PRODUCTION' : 'SANDBOX',
      ),
    );
  }

  void _handleForegroundMessage(PushRemoteMessage message) {
    final data = _mergedMessageData(message);
    _emitReceived(data);
    if (!shouldRenderSystemNotificationInForeground(_targetPlatform)) {
      // iOS remote presentation is suppressed. Existing realtime/sync UI is the
      // sole foreground user-visible path, so there is no double notification.
      return;
    }
    unawaited(_showAndroidForegroundNotification(data));
  }

  Future<void> _showAndroidForegroundNotification(
    Map<String, dynamic> data,
  ) async {
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
      badgeCount: content.badgeCount,
    );
  }

  Map<String, dynamic> _mergedMessageData(PushRemoteMessage message) {
    final data = Map<String, dynamic>.from(message.data);
    if ((data['title']?.toString().trim() ?? '').isEmpty &&
        message.notificationTitle.isNotEmpty) {
      data['title'] = message.notificationTitle;
    }
    if ((data['body']?.toString().trim() ?? '').isEmpty &&
        message.notificationBody.isNotEmpty) {
      data['body'] = message.notificationBody;
    }
    return data;
  }

  void _emitReceived(Map<String, dynamic> data) {
    if (!_belongsToActiveAccount(data)) return;
    _onNotificationReceived?.call(Map<String, dynamic>.from(data));
  }

  void _emitOpened(Map<String, dynamic> data) {
    if (!_belongsToActiveAccount(data)) return;
    final normalized = Map<String, dynamic>.from(data);
    final callback = _onNotificationOpened;
    if (callback == null) {
      _pendingOpened.add(normalized);
      if (_pendingOpened.length > 8) {
        _pendingOpened.removeRange(0, _pendingOpened.length - 8);
      }
      return;
    }
    callback(normalized);
  }

  bool _belongsToActiveAccount(Map<String, dynamic> data) {
    final recipient = data['recipientUserId']?.toString().trim() ?? '';
    final active = _userId?.trim() ?? '';
    return recipient.isEmpty || active.isEmpty || recipient == active;
  }

  Future<void> dispose() async {
    await _tokenSubscription?.cancel();
    await _foregroundSubscription?.cancel();
    await _openedSubscription?.cancel();
    await _localOpenedSubscription?.cancel();
    await _nativeTokenSubscription?.cancel();
    await _nativeOpenedSubscription?.cancel();
    await _nativeForegroundSubscription?.cancel();
    _tokenSubscription = null;
    _foregroundSubscription = null;
    _openedSubscription = null;
    _localOpenedSubscription = null;
    _nativeTokenSubscription = null;
    _nativeOpenedSubscription = null;
    _nativeForegroundSubscription = null;
    _runtimeStarted = false;
    _messagingReady = false;
    _apiClient.close();
  }
}
