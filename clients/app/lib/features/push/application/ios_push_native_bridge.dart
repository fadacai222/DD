import 'dart:async';

import 'package:flutter/services.dart';

import '../../../core/notifications/notification_authorization.dart';

abstract interface class IosPushNativeAdapter {
  Future<NotificationAuthorizationState?> authorizationState();

  Future<NotificationAuthorizationState?> requestAuthorization({
    required bool provisional,
  });

  Future<bool> openNotificationSettings();

  Future<String?> getApnsToken();

  Future<void> registerRemoteNotifications();

  Future<void> setBadgeCount(int count);

  Stream<String> get apnsTokenRefresh;

  Stream<Map<String, dynamic>> get notificationTaps;

  Stream<Map<String, dynamic>> get foregroundNotifications;
}

final class IosPushNativeBridge implements IosPushNativeAdapter {
  IosPushNativeBridge({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  }) : _methodChannel =
           methodChannel ??
           const MethodChannel('org.openimx.client/ios_push'),
       _eventChannel =
           eventChannel ?? const EventChannel('org.openimx.client/ios_push_events');

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  Stream<Map<String, dynamic>>? _events;

  Stream<Map<String, dynamic>> get _nativeEvents => _events ??=
      _eventChannel.receiveBroadcastStream().map<Map<String, dynamic>>((event) {
        if (event is! Map) return const <String, dynamic>{};
        return event.map<String, dynamic>(
          (key, value) => MapEntry(key.toString(), value),
        );
      }).asBroadcastStream();

  @override
  Future<NotificationAuthorizationState?> authorizationState() async {
    try {
      final raw = await _methodChannel.invokeMethod<String>('authorizationState');
      return _decodeAuthorization(raw);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<NotificationAuthorizationState?> requestAuthorization({
    required bool provisional,
  }) async {
    try {
      final raw = await _methodChannel.invokeMethod<String>(
        'requestAuthorization',
        <String, Object>{'provisional': provisional},
      );
      return _decodeAuthorization(raw);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<bool> openNotificationSettings() async {
    try {
      return await _methodChannel.invokeMethod<bool>('openNotificationSettings') ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<String?> getApnsToken() async {
    try {
      return (await _methodChannel.invokeMethod<String>('apnsToken'))?.trim();
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> registerRemoteNotifications() async {
    try {
      await _methodChannel.invokeMethod<void>('registerRemoteNotifications');
    } on MissingPluginException {
      // Firebase Messaging remains the fallback for FCM-based iOS builds.
    } on PlatformException {
      // A later app-resume reconciliation retries APNs registration.
    }
  }

  @override
  Future<void> setBadgeCount(int count) async {
    try {
      await _methodChannel.invokeMethod<void>(
        'setBadgeCount',
        <String, Object>{'count': count < 0 ? 0 : count},
      );
    } on MissingPluginException {
      // The Platform Foundation commit intentionally does not wire this service.
      // AI1 integration adds the registrar/xcodeproj hook without crashing old builds.
    } on PlatformException {
      // Badge drift is repaired again on the next unread/lifecycle reconciliation.
    }
  }

  @override
  Stream<String> get apnsTokenRefresh => _nativeEvents
      .where((event) => event['type'] == 'apnsToken')
      .map((event) => event['token']?.toString().trim() ?? '')
      .where((token) => token.isNotEmpty);

  @override
  Stream<Map<String, dynamic>> get notificationTaps =>
      _payloadEvents('notificationTap');

  @override
  Stream<Map<String, dynamic>> get foregroundNotifications =>
      _payloadEvents('notificationForeground');

  Stream<Map<String, dynamic>> _payloadEvents(String type) => _nativeEvents
      .where((event) => event['type'] == type)
      .map((event) {
        final payload = event['payload'];
        if (payload is! Map) return const <String, dynamic>{};
        return payload.map<String, dynamic>(
          (key, value) => MapEntry(key.toString(), value),
        );
      });

  NotificationAuthorizationState? _decodeAuthorization(String? raw) =>
      switch (raw?.trim().toUpperCase()) {
        'NOT_DETERMINED' => NotificationAuthorizationState.notDetermined,
        'GRANTED' => NotificationAuthorizationState.granted,
        'PROVISIONAL' => NotificationAuthorizationState.provisional,
        'DENIED' => NotificationAuthorizationState.denied,
        'UNSUPPORTED' => NotificationAuthorizationState.unsupported,
        _ => null,
      };
}
