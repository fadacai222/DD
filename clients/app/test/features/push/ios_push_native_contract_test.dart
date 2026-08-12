import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS Push native service exposes the required lifecycle bridge', () {
    final service = File(
      'ios/Runner/Services/PushNotificationService.swift',
    ).readAsStringSync();

    expect(service, contains('org.openimx.client/ios_push'));
    expect(service, contains('org.openimx.client/ios_push_events'));
    expect(service, contains('authorizationState'));
    expect(service, contains('requestAuthorization'));
    expect(service, contains('openNotificationSettings'));
    expect(service, contains('registerForRemoteNotifications'));
    expect(service, contains('didRegisterForRemoteNotifications'));
    expect(service, contains('didFailToRegisterForRemoteNotifications'));
    expect(service, contains('setBadgeCount'));
    expect(service, contains('didReceiveNotificationResponse'));
    expect(service, contains('foregroundPresentationOptions'));
    expect(service, contains('return []'));
    expect(service, contains('NativeRouteService.shared.publishNotificationRoute'));
  });

  test('native service does not add product actions or log token material', () {
    final service = File(
      'ios/Runner/Services/PushNotificationService.swift',
    ).readAsStringSync();

    expect(service, isNot(contains('UNNotificationAction(')));
    expect(service, isNot(contains('UNNotificationCategory(')));
    expect(service, isNot(contains('print(')));
    expect(service, isNot(contains('NSLog(')));
  });

  test('authenticated iOS device registration keeps the shared IOS platform contract', () {
    final authApi = File(
      'lib/features/auth/data/auth_api_client.dart',
    ).readAsStringSync();

    expect(authApi, contains("TargetPlatform.iOS => 'IOS'"));
    expect(authApi, contains("TargetPlatform.android => 'ANDROID'"));
  });

  test('native Push service keeps the shared registrar extension contract', () {
    final service = File(
      'ios/Runner/Services/PushNotificationService.swift',
    ).readAsStringSync();
    final registrar = File(
      'ios/Runner/Services/NativeServiceRegistrar.swift',
    ).readAsStringSync();

    expect(service, contains('DDNativeService'));
    expect(service, contains('static let pluginKey'));
    expect(registrar, contains('protocol DDNativeService'));
    expect(registrar, contains('register<Service: DDNativeService>'));
  });
}
