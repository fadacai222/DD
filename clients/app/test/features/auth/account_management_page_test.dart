import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/auth/data/auth_api_client.dart';
import 'package:im_client/features/auth/domain/account_management.dart';
import 'package:im_client/features/auth/domain/auth_session.dart';
import 'package:im_client/features/auth/presentation/account_management_page.dart';

void main() {
  testWidgets('desktop general settings exposes explicit appearance choices', (
    tester,
  ) async {
    final gateway = _AccountGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: AccountManagementPage(
          gateway: gateway,
          origin: Uri.parse('http://127.0.0.1:18473'),
          session: _session(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('通用').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-theme-mode')), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-theme-mode')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('theme-mode-system')), findsOneWidget);
    expect(find.byKey(const Key('theme-mode-light')), findsOneWidget);
    expect(find.byKey(const Key('theme-mode-dark')), findsOneWidget);
  });

  testWidgets('mobile settings keeps appearance entry directly discoverable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final gateway = _AccountGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: AccountManagementPage(
          gateway: gateway,
          origin: Uri.parse('http://127.0.0.1:18473'),
          session: _session(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings-theme-mode')), findsOneWidget);
    expect(find.text('外观'), findsOneWidget);
  });

  testWidgets('account settings no longer exposes profile editing fields', (
    tester,
  ) async {
    final gateway = _AccountGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: AccountManagementPage(
          gateway: gateway,
          origin: Uri.parse('http://127.0.0.1:18473'),
          session: _session(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('account-display-name')), findsNothing);
    expect(find.byKey(const Key('account-ddid')), findsNothing);
    expect(find.byKey(const Key('account-email')), findsNothing);
    expect(find.byKey(const Key('account-bio')), findsNothing);
    expect(find.text('允许陌生人消息'), findsNothing);
    expect(find.text('保存资料'), findsNothing);
    expect(find.text('保存设置'), findsNothing);
    expect(find.text('保存通知设置'), findsNothing);
    expect(find.text('登录设备'), findsWidgets);
  });
}

final class _AccountGateway implements AuthGateway {
  int updateCalls = 0;
  String lastHandle = '';
  String lastDisplayName = '';
  String sentCodeEmail = '';
  String changedEmail = '';
  String changedCode = '';
  AccountMe me = _me();

  @override
  Future<AccountMe> getMe({
    required Uri origin,
    required String accessToken,
  }) async => me;

  @override
  Future<AccountMe> updateMe({
    required Uri origin,
    required String accessToken,
    required String handle,
    required String displayName,
    required String bio,
    required AccountPrivacy privacy,
  }) async {
    updateCalls++;
    lastHandle = handle;
    lastDisplayName = displayName;
    me = AccountMe(
      profile: AccountProfile(
        id: me.profile.id,
        email: me.profile.email,
        handle: handle,
        displayName: displayName,
        bio: bio,
      ),
      privacy: privacy,
    );
    return me;
  }

  @override
  Future<void> sendEmailChangeCode({
    required Uri origin,
    required String accessToken,
    required String email,
  }) async => sentCodeEmail = email;

  @override
  Future<AccountMe> changeEmail({
    required Uri origin,
    required String accessToken,
    required String email,
    required String code,
  }) async {
    changedEmail = email;
    changedCode = code;
    me = AccountMe(
      profile: AccountProfile(
        id: me.profile.id,
        email: email,
        handle: me.profile.handle,
        displayName: me.profile.displayName,
        bio: me.profile.bio,
      ),
      privacy: me.privacy,
    );
    return me;
  }

  @override
  Future<List<AccountDevice>> listDevices({
    required Uri origin,
    required String accessToken,
  }) async => const [];

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
  }) => throw UnimplementedError();
  @override
  Future<AuthSession> login({
    required Uri origin,
    required String email,
    required String password,
    required AuthDeviceInput device,
  }) => throw UnimplementedError();
  @override
  Future<AuthSession> refresh({
    required Uri origin,
    required String refreshToken,
  }) => throw UnimplementedError();
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
  Future<DateTime> uploadProfileAvatar({
    required Uri origin,
    required String accessToken,
    required Uint8List bytes,
    required String contentType,
  }) async => DateTime.utc(2026, 8, 9);
  @override
  Future<void> deleteProfileAvatar({
    required Uri origin,
    required String accessToken,
  }) async {}
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

AccountMe _me() => const AccountMe(
  profile: AccountProfile(
    id: 'u1',
    email: 'alice@example.com',
    handle: 'alice',
    displayName: 'Alice',
    bio: 'bio',
  ),
  privacy: AccountPrivacy(
    allowEmailSearch: false,
    allowStrangerMessages: false,
    showOnlineStatus: true,
    readReceiptsEnabled: true,
    notificationPreviewEnabled: true,
  ),
);

AuthSession _session() => AuthSession(
  user: const AuthUser(
    id: 'u1',
    email: 'alice@example.com',
    handle: 'alice',
    displayName: 'Alice',
  ),
  device: const AuthDevice(
    id: 'd1',
    name: 'Windows',
    platform: 'WINDOWS',
    appVersion: 'dev',
  ),
  tokens: AuthTokens(
    accessToken: 'access',
    accessExpiresAt: DateTime.utc(2026, 8, 10),
    refreshToken: 'refresh',
    refreshExpiresAt: DateTime.utc(2026, 9, 10),
  ),
);
