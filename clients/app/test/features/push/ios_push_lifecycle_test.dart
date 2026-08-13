import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/notifications/notification_authorization.dart';
import 'package:im_client/features/push/application/push_badge_state.dart';
import 'package:im_client/features/push/application/push_endpoint_lifecycle.dart';
import 'package:im_client/features/push/application/push_navigation_intent.dart';
import 'package:im_client/features/push/application/push_registration_service.dart';

void main() {
  group('iOS push platform contract', () {
    test('iOS is a supported push target', () {
      expect(
        PushRegistrationService.isTargetSupported(TargetPlatform.iOS),
        isTrue,
      );
      expect(
        PushRegistrationService.isTargetSupported(TargetPlatform.windows),
        isFalse,
      );
      expect(
        PushRegistrationService.shouldRenderSystemNotificationInForeground(
          TargetPlatform.iOS,
        ),
        isFalse,
      );
      expect(
        PushRegistrationService.shouldRenderSystemNotificationInForeground(
          TargetPlatform.android,
        ),
        isTrue,
      );
    });

    test('denied permission is not requested again and requires settings', () {
      expect(NotificationAuthorizationState.denied.canRequest, isFalse);
      expect(NotificationAuthorizationState.denied.requiresSettings, isTrue);
      expect(NotificationAuthorizationState.notDetermined.canRequest, isTrue);
      expect(NotificationAuthorizationState.provisional.canDeliver, isTrue);
      expect(NotificationAuthorizationState.granted.canDeliver, isTrue);
    });
  });

  group('badge fact model', () {
    test('keeps numeric system count and product 99+ label', () {
      expect(const PushBadgeState(0).displayLabel, isNull);
      expect(const PushBadgeState(1).displayLabel, '1');
      expect(const PushBadgeState(99).displayLabel, '99');
      expect(const PushBadgeState(100).displayLabel, '99+');
      expect(const PushBadgeState(100).systemCount, 100);
      expect(const PushBadgeState(-9).systemCount, 0);
    });
  });

  group('tap routing', () {
    const currentUserId = 'user-a';

    test('routes direct/group chat payloads to their conversation', () {
      final direct = PushNavigationIntent.fromData(
        const <String, dynamic>{
          'eventType': 'MESSAGE_CREATED',
          'conversationId': 'direct-1',
          'conversationType': 'DIRECT',
          'recipientUserId': currentUserId,
        },
        currentUserId: currentUserId,
      );
      final group = PushNavigationIntent.fromData(
        const <String, dynamic>{
          'eventType': 'MESSAGE_CREATED',
          'conversationId': 'group-1',
          'conversationType': 'GROUP',
          'recipientUserId': currentUserId,
        },
        currentUserId: currentUserId,
      );

      expect(direct.target, PushNavigationTarget.conversation);
      expect(direct.conversationId, 'direct-1');
      expect(group.target, PushNavigationTarget.conversation);
      expect(group.conversationId, 'group-1');
    });

    test('routes incoming call payloads to the call recovery path', () {
      final call = PushNavigationIntent.fromData(
        const <String, dynamic>{
          'eventType': 'CALL_RINGING',
          'conversationId': 'direct-1',
          'resourceId': 'call-1',
          'recipientUserId': currentUserId,
        },
        currentUserId: currentUserId,
      );

      expect(call.target, PushNavigationTarget.call);
      expect(call.resourceId, 'call-1');
      expect(call.conversationId, 'direct-1');
    });

    test('routes moment interaction and generic fallback safely', () {
      final moment = PushNavigationIntent.fromData(
        const <String, dynamic>{
          'eventType': 'MOMENT_COMMENT_CREATED',
          'resourceId': 'moment-1',
          'recipientUserId': currentUserId,
        },
        currentUserId: currentUserId,
      );
      final malformed = PushNavigationIntent.fromData(
        const <String, dynamic>{'unexpected': <String>[]},
        currentUserId: currentUserId,
      );

      expect(moment.target, PushNavigationTarget.moments);
      expect(moment.resourceId, 'moment-1');
      expect(malformed.target, PushNavigationTarget.generic);
    });

    test('does not route a killed-state notification for another account', () {
      final intent = PushNavigationIntent.fromData(
        const <String, dynamic>{
          'eventType': 'MESSAGE_CREATED',
          'conversationId': 'secret-a',
          'recipientUserId': 'user-a',
        },
        currentUserId: 'user-b',
      );

      expect(intent.target, PushNavigationTarget.ignored);
    });

    test('expired/missing session cannot consume a notification deep link', () {
      final intent = PushNavigationIntent.fromData(
        const <String, dynamic>{
          'eventType': 'MESSAGE_CREATED',
          'conversationId': 'conversation-1',
          'recipientUserId': 'user-a',
        },
        currentUserId: '',
      );

      expect(intent.target, PushNavigationTarget.ignored);
    });
  });

  group('endpoint ownership lifecycle', () {
    late _FakePushEndpointGateway gateway;
    late PushEndpointLifecycle lifecycle;
    final origin = Uri.parse('https://dd.example.test');

    setUp(() {
      gateway = _FakePushEndpointGateway();
      lifecycle = PushEndpointLifecycle(gateway: gateway);
    });

    test('registers FCM token and token refresh for the active account', () async {
      final generation = await lifecycle.activateSession(
        PushEndpointSession(
          origin: origin,
          accessToken: 'access-a',
          userId: 'user-a',
          deviceId: 'device-a',
        ),
      );
      await lifecycle.registerEndpoint(
        generation: generation,
        endpoint: const PushEndpointRegistration(
          provider: 'FCM',
          endpoint: 'fcm-token-1',
          appId: 'firebase-project',
          environment: 'SANDBOX',
        ),
      );
      await lifecycle.registerEndpoint(
        generation: generation,
        endpoint: const PushEndpointRegistration(
          provider: 'FCM',
          endpoint: 'fcm-token-2',
          appId: 'firebase-project',
          environment: 'SANDBOX',
        ),
      );

      expect(gateway.registered.map((item) => item.endpoint), <String>[
        'fcm-token-1',
        'fcm-token-2',
      ]);
      expect(gateway.registerUsers, everyElement('access-a'));
    });

    test('account switch unbinds A before B can register the same APNs token', () async {
      final generationA = await lifecycle.activateSession(
        PushEndpointSession(
          origin: origin,
          accessToken: 'access-a',
          userId: 'user-a',
          deviceId: 'device-a',
        ),
      );
      await lifecycle.registerEndpoint(
        generation: generationA,
        endpoint: const PushEndpointRegistration(
          provider: 'APNS',
          endpoint: 'shared-apns-token',
          appId: 'org.openimx.client',
          environment: 'SANDBOX',
        ),
      );

      final generationB = await lifecycle.activateSession(
        PushEndpointSession(
          origin: origin,
          accessToken: 'access-b',
          userId: 'user-b',
          deviceId: 'device-b',
        ),
      );
      await lifecycle.registerEndpoint(
        generation: generationB,
        endpoint: const PushEndpointRegistration(
          provider: 'APNS',
          endpoint: 'shared-apns-token',
          appId: 'org.openimx.client',
          environment: 'SANDBOX',
        ),
      );

      expect(gateway.operations, <String>[
        'register:access-a:APNS:shared-apns-token',
        'delete:access-a:APNS',
        'register:access-b:APNS:shared-apns-token',
      ]);
    });

    test('preference disable unbinds endpoint without losing active account lease', () async {
      final generation = await lifecycle.activateSession(
        PushEndpointSession(
          origin: origin,
          accessToken: 'access-a',
          userId: 'user-a',
          deviceId: 'device-a',
        ),
      );
      await lifecycle.registerEndpoint(
        generation: generation,
        endpoint: const PushEndpointRegistration(
          provider: 'FCM',
          endpoint: 'token-a',
          appId: 'firebase-project',
          environment: 'PRODUCTION',
        ),
      );
      await lifecycle.disableEndpoint();
      await lifecycle.registerEndpoint(
        generation: generation,
        endpoint: const PushEndpointRegistration(
          provider: 'FCM',
          endpoint: 'token-a-refreshed',
          appId: 'firebase-project',
          environment: 'PRODUCTION',
        ),
      );

      expect(gateway.operations, <String>[
        'register:access-a:FCM:token-a',
        'delete:access-a:FCM',
        'register:access-a:FCM:token-a-refreshed',
      ]);
    });

    test('logout unregisters active endpoint and stale async registration is ignored', () async {
      final generation = await lifecycle.activateSession(
        PushEndpointSession(
          origin: origin,
          accessToken: 'access-a',
          userId: 'user-a',
          deviceId: 'device-a',
        ),
      );
      await lifecycle.registerEndpoint(
        generation: generation,
        endpoint: const PushEndpointRegistration(
          provider: 'FCM',
          endpoint: 'token-a',
          appId: 'firebase-project',
          environment: 'PRODUCTION',
        ),
      );
      await lifecycle.deactivateSession();
      await lifecycle.registerEndpoint(
        generation: generation,
        endpoint: const PushEndpointRegistration(
          provider: 'FCM',
          endpoint: 'late-token-a',
          appId: 'firebase-project',
          environment: 'PRODUCTION',
        ),
      );

      expect(gateway.operations, <String>[
        'register:access-a:FCM:token-a',
        'delete:access-a:FCM',
      ]);
    });

    test('stale A lease blocks B until authoritative cleanup then B can register', () async {
      final generationA = await lifecycle.activateSession(
        PushEndpointSession(
          origin: origin,
          accessToken: 'access-a',
          userId: 'user-a',
          deviceId: 'device-a',
        ),
      );
      await lifecycle.registerEndpoint(
        generation: generationA,
        endpoint: const PushEndpointRegistration(
          provider: 'FCM',
          endpoint: 'shared-token',
          appId: 'firebase-project',
          environment: 'PRODUCTION',
        ),
      );
      gateway.deleteError = StateError('A endpoint cleanup failed');

      await expectLater(
        lifecycle.activateSession(
          PushEndpointSession(
            origin: origin,
            accessToken: 'access-b',
            userId: 'user-b',
            deviceId: 'device-b',
          ),
        ),
        throwsStateError,
      );
      expect(lifecycle.session?.userId, 'user-a');
      expect(lifecycle.generation, generationA);

      await lifecycle.abandonSessionAfterAuthoritativeRevocation();
      gateway.deleteError = null;
      final generationB = await lifecycle.activateSession(
        PushEndpointSession(
          origin: origin,
          accessToken: 'access-b',
          userId: 'user-b',
          deviceId: 'device-b',
        ),
      );
      await lifecycle.registerEndpoint(
        generation: generationB,
        endpoint: const PushEndpointRegistration(
          provider: 'FCM',
          endpoint: 'shared-token',
          appId: 'firebase-project',
          environment: 'PRODUCTION',
        ),
      );

      expect(lifecycle.session?.userId, 'user-b');
      expect(gateway.operations.last, 'register:access-b:FCM:shared-token');
    });

    test('authoritative abandon clears a failed stale lease without network retry', () async {
      final generationA = await lifecycle.activateSession(
        PushEndpointSession(
          origin: origin,
          accessToken: 'access-a',
          userId: 'user-a',
          deviceId: 'device-a',
        ),
      );
      await lifecycle.registerEndpoint(
        generation: generationA,
        endpoint: const PushEndpointRegistration(
          provider: 'FCM',
          endpoint: 'token-a',
          appId: 'firebase-project',
          environment: 'PRODUCTION',
        ),
      );
      gateway.deleteError = StateError('old access token is revoked');

      await expectLater(lifecycle.deactivateSession(), throwsStateError);
      expect(lifecycle.session?.userId, 'user-a');
      expect(lifecycle.generation, generationA);

      final operationsBeforeAbandon = List<String>.from(gateway.operations);
      await lifecycle.abandonSessionAfterAuthoritativeRevocation();
      expect(gateway.operations, operationsBeforeAbandon);
      expect(lifecycle.session, isNull);
      expect(lifecycle.generation, generationA + 1);

      await lifecycle.registerEndpoint(
        generation: generationA,
        endpoint: const PushEndpointRegistration(
          provider: 'FCM',
          endpoint: 'late-token-a',
          appId: 'firebase-project',
          environment: 'PRODUCTION',
        ),
      );
      gateway.deleteError = null;
      final generationB = await lifecycle.activateSession(
        PushEndpointSession(
          origin: origin,
          accessToken: 'access-b',
          userId: 'user-b',
          deviceId: 'device-b',
        ),
      );
      await lifecycle.registerEndpoint(
        generation: generationB,
        endpoint: const PushEndpointRegistration(
          provider: 'FCM',
          endpoint: 'token-b',
          appId: 'firebase-project',
          environment: 'PRODUCTION',
        ),
      );

      expect(gateway.operations.last, 'register:access-b:FCM:token-b');
      expect(
        gateway.operations,
        isNot(contains('register:access-a:FCM:late-token-a')),
      );
    });
  });
}

final class _FakePushEndpointGateway implements PushEndpointGateway {
  final List<String> operations = <String>[];
  final List<PushEndpointRegistration> registered = <PushEndpointRegistration>[];
  final List<String> registerUsers = <String>[];
  Object? deleteError;

  @override
  Future<void> deleteEndpoint({
    required Uri origin,
    required String accessToken,
    required String provider,
  }) async {
    operations.add('delete:$accessToken:$provider');
    final error = deleteError;
    if (error != null) throw error;
  }

  @override
  Future<void> registerEndpoint({
    required Uri origin,
    required String accessToken,
    required String provider,
    required String endpoint,
    required String appId,
    required String environment,
  }) async {
    operations.add('register:$accessToken:$provider:$endpoint');
    registerUsers.add(accessToken);
    registered.add(
      PushEndpointRegistration(
        provider: provider,
        endpoint: endpoint,
        appId: appId,
        environment: environment,
      ),
    );
  }
}
