import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/auth/data/auth_api_client.dart';
import 'package:im_client/features/auth/domain/account_management.dart';
import 'package:im_client/features/auth/domain/auth_session.dart';
import 'package:im_client/features/auth/presentation/auth_page.dart';

void main() {
  testWidgets(
    'register form renders without overflow on narrow Android-like screen',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(home: AuthPage(gateway: _FakeAuthGateway())),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('auth-email')), findsOneWidget);
      expect(find.byKey(const Key('auth-send-code')), findsOneWidget);
      expect(find.byKey(const Key('auth-register')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('successful registration switches to the product shell', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(881, 657);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway = _FakeAuthGateway();
    await tester.pumpWidget(MaterialApp(home: AuthPage(gateway: gateway)));

    await tester.enterText(
      find.byKey(const Key('auth-email')),
      'alice@example.com',
    );
    await tester.enterText(find.byKey(const Key('auth-code')), '123456');
    await tester.enterText(
      find.byKey(const Key('auth-password')),
      'correct horse battery staple',
    );
    await tester.enterText(find.byKey(const Key('auth-handle')), 'alice');
    await tester.enterText(find.byKey(const Key('auth-display-name')), 'Alice');
    final registerButton = find.byKey(const Key('auth-register'));
    await tester.ensureVisible(registerButton);
    await tester.pumpAndSettle();
    await tester.tap(registerButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(const Key('shell-rail-messages')), findsOneWidget);
    expect(find.byKey(const Key('messaging-search')), findsOneWidget);
    expect(find.byKey(const Key('shell-rail-contacts')), findsOneWidget);
    expect(find.byKey(const Key('shell-rail-discovery')), findsOneWidget);
    expect(find.byKey(const Key('shell-rail-me')), findsOneWidget);
    expect(gateway.registerCount, 1);
    expect(tester.takeException(), isNull);

    // The product shell intentionally keeps realtime messaging/call signaling alive.
    // Explicitly unmount it so this test also proves shutdown cancels connect timers.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

final class _FakeAuthGateway implements AuthGateway {
  int registerCount = 0;

  @override
  Future<void> sendRegistrationCode({
    required Uri origin,
    required String email,
  }) async {}

  @override
  Future<AuthSession> register({
    required Uri origin,
    required String email,
    required String code,
    required String password,
    required String handle,
    required String displayName,
    required AuthDeviceInput device,
  }) async {
    registerCount++;
    return _session();
  }

  @override
  Future<AuthSession> login({
    required Uri origin,
    required String email,
    required String password,
    required AuthDeviceInput device,
  }) async => _session();

  @override
  Future<AuthSession> refresh({
    required Uri origin,
    required String refreshToken,
  }) async => _session();

  @override
  Future<void> sendPasswordResetCode({
    required Uri origin,
    required String email,
  }) async {}

  @override
  Future<void> resetPassword({
    required Uri origin,
    required String email,
    required String code,
    required String newPassword,
  }) async {}

  @override
  Future<AccountMe> getMe({
    required Uri origin,
    required String accessToken,
  }) async => const AccountMe(
    profile: AccountProfile(
      id: 'u1',
      email: 'alice@example.com',
      handle: 'alice',
      displayName: 'Alice',
      bio: '',
    ),
    privacy: AccountPrivacy(
      allowEmailSearch: false,
      allowStrangerMessages: false,
      showOnlineStatus: true,
      readReceiptsEnabled: true,
      notificationPreviewEnabled: true,
    ),
  );

  @override
  Future<AccountMe> updateMe({
    required Uri origin,
    required String accessToken,
    required String displayName,
    required String bio,
    required AccountPrivacy privacy,
  }) async => AccountMe(
    profile: AccountProfile(
      id: 'u1',
      email: 'alice@example.com',
      handle: 'alice',
      displayName: displayName,
      bio: bio,
    ),
    privacy: privacy,
  );

  @override
  Future<DateTime> uploadProfileAvatar({
    required Uri origin,
    required String accessToken,
    required Uint8List bytes,
    required String contentType,
  }) async => DateTime.utc(2026, 8, 8, 9);

  @override
  Future<void> deleteProfileAvatar({
    required Uri origin,
    required String accessToken,
  }) async {}

  @override
  Future<List<AccountDevice>> listDevices({
    required Uri origin,
    required String accessToken,
  }) async => const [];

  @override
  Future<void> revokeDevice({
    required Uri origin,
    required String accessToken,
    required String deviceId,
  }) async {}

  @override
  Future<void> logoutAll({
    required Uri origin,
    required String accessToken,
  }) async {}

  @override
  void close() {}
}

AuthSession _session() => AuthSession(
  user: const AuthUser(
    id: '018f0000-0000-7000-8000-000000000001',
    email: 'alice@example.com',
    handle: 'alice',
    displayName: 'Alice',
  ),
  device: const AuthDevice(
    id: '018f0000-0000-7000-8000-000000000002',
    name: 'DD Android',
    platform: 'ANDROID',
    appVersion: '0.5.0-dev',
  ),
  tokens: AuthTokens(
    accessToken: 'access-token',
    accessExpiresAt: DateTime.utc(2026, 8, 8, 2),
    refreshToken: 'refresh-token',
    refreshExpiresAt: DateTime.utc(2026, 9, 7, 2),
  ),
);
