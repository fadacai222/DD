import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS project keeps DD platform foundation contracts', () {
    final info = File('ios/Runner/Info.plist').readAsStringSync();
    final entitlements = File('ios/Runner/Runner.entitlements').readAsStringSync();
    final project = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    final pushRegistration = File(
      'lib/features/push/application/push_registration_service.dart',
    ).readAsStringSync();

    for (final key in const [
      'NSCameraUsageDescription',
      'NSMicrophoneUsageDescription',
      'NSPhotoLibraryUsageDescription',
      'NSPhotoLibraryAddUsageDescription',
      'NSLocalNetworkUsageDescription',
    ]) {
      expect(info, contains('<key>$key</key>'));
    }
    expect(info, contains('<string>audio</string>'));
    expect(info, contains('<string>remote-notification</string>'));
    expect(info, contains('<string>dd</string>'));
    expect(info, isNot(contains('NSBluetoothAlwaysUsageDescription')));
    expect(pushRegistration, contains('requestPermission(alert: true, badge: true, sound: true)'));

    expect(entitlements, contains('<key>aps-environment</key>'));
    expect(entitlements, contains(r'$(DD_APS_ENVIRONMENT)'));
    expect(entitlements, isNot(contains('com.apple.developer.team-identifier')));
    expect(entitlements, isNot(contains('application-identifier')));

    expect(project, contains('PRODUCT_BUNDLE_IDENTIFIER = org.openimx.client;'));
    final deploymentTargets = RegExp(
      r'IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+);',
    ).allMatches(project).map((match) => match.group(1)).toList();
    expect(
      deploymentTargets,
      equals(const ['15.0', '15.0', '15.0']),
      reason: 'Runner project Debug/Profile/Release deployment targets must stay aligned',
    );
    expect(project, contains('TARGETED_DEVICE_FAMILY = "1,2";'));
    expect(project, contains('CODE_SIGN_STYLE = Automatic;'));
    expect(project, contains('CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;'));
    expect(project, contains('DD_APS_ENVIRONMENT = development;'));
    expect(project, contains('DD_APS_ENVIRONMENT = production;'));
  });

  test('iOS secure storage stays on native flutter_secure_storage path', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final gateway = File('lib/core/security/dd_secure_storage.dart').readAsStringSync();
    final vault = File('lib/features/auth/data/auth_session_vault.dart').readAsStringSync();

    expect(pubspec, contains('flutter_secure_storage:'));
    expect(gateway, contains('FlutterSecureStorage'));
    expect(vault, contains('if (kIsWeb'));
    expect(vault, isNot(contains('TargetPlatform.iOS')));
    expect(vault, contains("'dd.auth.accounts.v1'"));
    expect(vault, contains('removeAccount'));
  });

  test('native services register outside AppDelegate', () {
    final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final registrar = File(
      'ios/Runner/Services/NativeServiceRegistrar.swift',
    ).readAsStringSync();
    final routeService = File(
      'ios/Runner/Services/NativeRouteService.swift',
    ).readAsStringSync();

    expect(appDelegate, contains('NativeServiceRegistrar.register'));
    expect(appDelegate, isNot(contains('FlutterEventChannel(')));
    expect(registrar, contains('protocol DDNativeService'));
    expect(registrar, contains('NativeRouteService.self'));
    expect(routeService, contains('org.openimx.client/native_routes'));
    expect(routeService, contains('publishNotificationRoute'));
  });
}
