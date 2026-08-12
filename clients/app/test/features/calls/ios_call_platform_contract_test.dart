import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS CallKit bridge keeps stable native service and no PushKit implementation', () {
    final service = File(
      'ios/Runner/Services/CallPlatformService.swift',
    ).readAsStringSync();

    expect(service, contains('import CallKit'));
    expect(service, contains('import AVFoundation'));
    expect(service, contains('DDNativeService'));
    expect(service, contains('static let pluginKey = "DDCallPlatformService"'));
    expect(service, contains('org.openimx.client/call_platform'));
    expect(service, contains('org.openimx.client/call_platform_events'));
    expect(service, contains('CXProviderDelegate'));
    expect(service, contains('requestMediaPermissions'));
    expect(service, contains('AVAudioSession.routeChangeNotification'));
    expect(service, contains('AVAudioSession.interruptionNotification'));
    expect(service, contains('provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession)'));
    expect(service, contains('provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession)'));
    expect(service, isNot(contains('import PushKit')));
    expect(service, isNot(contains('PKPushRegistry')));
  });

  test('CallKit system actions use two-phase acknowledgement and timeout cleanup', () {
    final service = File(
      'ios/Runner/Services/CallPlatformService.swift',
    ).readAsStringSync();

    expect(service, contains('completeSystemAction'));
    expect(service, contains('pendingActionsByID'));
    expect(service, contains('actionId'));
    expect(service, contains('provider(_ provider: CXProvider, timedOutPerforming action: CXAction)'));
    expect(service, contains('completedActionIDs'));
    expect(service, contains('completedActionIDs.contains(actionID)'));
    expect(service, contains('guard let pending = pendingActionsByID.removeValue(forKey: actionID) else'));
    expect(service, contains('record.incoming ? "decline" : "cancel"'));
    expect(service, contains('if success {'));
    expect(service, contains('pending.action.fulfill()'));
    expect(service, contains('pending.action.fail()'));
    expect(service, contains('if pending.removeRecordOnSuccess'));
    expect(service, contains('queuedSystemActionEventsByID[actionID] = payload'));
    expect(service, contains('for (actionID, payload) in queued where pendingActionsByID[actionID] != nil'));

    final answerStart = service.indexOf(
      'func provider(_ provider: CXProvider, perform action: CXAnswerCallAction)',
    );
    final endStart = service.indexOf(
      'func provider(_ provider: CXProvider, perform action: CXEndCallAction)',
    );
    final audioStart = service.indexOf(
      'func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession)',
    );
    expect(answerStart, greaterThanOrEqualTo(0));
    expect(endStart, greaterThan(answerStart));
    expect(audioStart, greaterThan(endStart));
    expect(
      service.substring(answerStart, endStart),
      isNot(contains('action.fulfill()')),
    );
    expect(
      service.substring(endStart, audioStart),
      isNot(contains('action.fulfill()')),
    );
    expect(
      service.substring(endStart, audioStart),
      isNot(contains('removeRecord(callID: callID)')),
      reason: 'CXEndCallAction must retain the CallRecord until server ack succeeds',
    );

    final timeoutStart = service.indexOf(
      'func provider(_ provider: CXProvider, timedOutPerforming action: CXAction)',
    );
    final didActivateStart = service.indexOf(
      'func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession)',
    );
    expect(timeoutStart, greaterThan(endStart));
    expect(didActivateStart, greaterThan(timeoutStart));
    final timeoutBody = service.substring(timeoutStart, didActivateStart);
    expect(timeoutBody, contains('pendingActionsByID.removeValue(forKey: action.uuid)'));
    expect(timeoutBody, contains('queuedSystemActionEventsByID.removeValue(forKey: action.uuid)'));
    expect(timeoutBody, isNot(contains('removeRecord')));
  });
}
