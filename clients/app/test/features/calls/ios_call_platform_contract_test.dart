import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS CallKit bridge stays isolated from AppDelegate and PushKit', () {
    final service = File(
      'ios/Runner/Services/CallPlatformService.swift',
    ).readAsStringSync();
    final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final project = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();

    expect(service, contains('import CallKit'));
    expect(service, contains('import AVFoundation'));
    expect(service, contains('CXProviderDelegate'));
    expect(service, contains('requestMediaPermissions'));
    expect(service, contains('AVAudioSession.routeChangeNotification'));
    expect(service, contains('AVAudioSession.interruptionNotification'));
    expect(service, contains('provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession)'));
    expect(service, contains('provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession)'));
    expect(service, isNot(contains('import PushKit')));
    expect(service, isNot(contains('PKPushRegistry')));

    expect(appDelegate, isNot(contains('CallPlatformService')));
    expect(
      project,
      isNot(contains('CallPlatformService.swift')),
      reason: 'AI1 owns project.pbxproj integration for parallel U30 work',
    );
  });
}
