import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/auth/data/auth_api_client.dart';
import 'package:im_client/features/auth/domain/account_management.dart';
import 'package:im_client/features/auth/domain/auth_session.dart';
import 'package:im_client/features/auth/presentation/account_management_page.dart';

void main() {
  testWidgets('desktop page is scoped to privacy and devices', (tester) async {
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

    expect(find.text('隐私与设备'), findsWidgets);
    expect(find.text('登录设备'), findsWidgets);
    expect(find.text('外观'), findsNothing);
    expect(find.text('聊天背景'), findsNothing);
    expect(find.text('媒体与缓存'), findsNothing);
    expect(find.text('性能'), findsNothing);
    expect(find.text('传输中心'), findsNothing);
  });

  testWidgets('mobile privacy page no longer duplicates outer Me settings', (
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

    expect(find.text('隐私'), findsOneWidget);
    expect(find.text('设备'), findsOneWidget);
    expect(find.text('外观'), findsNothing);
    expect(find.text('聊天背景'), findsNothing);
    expect(find.text('媒体与缓存'), findsNothing);
    expect(find.text('性能'), findsNothing);
    expect(find.text('传输中心'), findsNothing);
  });

  testWidgets(
    'revoked device history can be cleared without touching active devices',
    (tester) async {
      final gateway = _AccountGateway()
        ..devices = [
          AccountDevice(
            id: 'd1',
            name: 'Windows',
            platform: 'WINDOWS',
            appVersion: 'dev',
            createdAt: DateTime.utc(2026, 8, 9),
            lastSeenAt: DateTime.utc(2026, 8, 11),
            current: true,
            revoked: false,
          ),
          AccountDevice(
            id: 'd2',
            name: 'Android',
            platform: 'ANDROID',
            appVersion: 'dev',
            createdAt: DateTime.utc(2026, 8, 8),
            lastSeenAt: DateTime.utc(2026, 8, 10),
            current: false,
            revoked: false,
          ),
          AccountDevice(
            id: 'd3',
            name: 'Old Web',
            platform: 'WEB',
            appVersion: 'dev',
            createdAt: DateTime.utc(2026, 8, 1),
            lastSeenAt: DateTime.utc(2026, 8, 2),
            current: false,
            revoked: true,
          ),
        ];
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

      final clear = find.byKey(const Key('account-clear-revoked-devices'));
      expect(clear, findsOneWidget);
      expect(find.text('Old Web'), findsOneWidget);
      expect(find.text('Windows（当前设备）'), findsOneWidget);
      expect(find.text('Android'), findsOneWidget);

      await tester.ensureVisible(clear);
      await tester.pumpAndSettle();
      await tester.tap(clear);
      await tester.pumpAndSettle();
      expect(find.text('清理已退出设备？'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('account-confirm-clear-revoked-devices')),
      );
      await tester.pumpAndSettle();

      expect(gateway.clearRevokedCalls, 1);
      expect(find.text('Old Web'), findsNothing);
      expect(find.text('Windows（当前设备）'), findsOneWidget);
      expect(find.text('Android'), findsOneWidget);
      await tester.fling(find.byType(ListView), const Offset(0, 800), 1200);
      await tester.pumpAndSettle();
      expect(find.text('已清理 1 条已退出设备记录。'), findsOneWidget);
      expect(
        find.byKey(const Key('account-clear-revoked-devices')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'successful current-device revoke runs authoritative push abandon before exit',
    (tester) async {
      var authoritativeAbandonCalls = 0;
      final gateway = _AccountGateway()
        ..devices = [
          AccountDevice(
            id: 'd1',
            name: 'Windows',
            platform: 'WINDOWS',
            appVersion: 'dev',
            createdAt: DateTime.utc(2026, 8, 9),
            lastSeenAt: DateTime.utc(2026, 8, 13),
            current: true,
            revoked: false,
          ),
        ];
      await tester.pumpWidget(
        MaterialApp(
          home: AccountManagementPage(
            gateway: gateway,
            origin: Uri.parse('http://127.0.0.1:18473'),
            session: _session(),
            onCurrentDeviceAuthoritativelyRevoked: () async {
              authoritativeAbandonCalls++;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, '退出'));
      await tester.pumpAndSettle();

      expect(gateway.revokeDeviceCalls, 1);
      expect(authoritativeAbandonCalls, 1);
    },
  );

  testWidgets('logoutAll success authoritatively abandons current push lease once', (
    tester,
  ) async {
    var authoritativeAbandonCalls = 0;
    final gateway = _AccountGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: AccountManagementPage(
          gateway: gateway,
          origin: Uri.parse('http://127.0.0.1:18473'),
          session: _session(),
          onCurrentDeviceAuthoritativelyRevoked: () async {
            authoritativeAbandonCalls++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, '退出全部设备'));
    await tester.pumpAndSettle();

    expect(gateway.logoutAllCalls, 1);
    expect(authoritativeAbandonCalls, 1);
  });

  testWidgets('logoutAll API failure never abandons current push lease', (
    tester,
  ) async {
    var authoritativeAbandonCalls = 0;
    final gateway = _AccountGateway()
      ..logoutAllError = const AuthApiException(
        statusCode: 503,
        code: 'TEMPORARY',
        message: 'temporary failure',
      );
    await tester.pumpWidget(
      MaterialApp(
        home: AccountManagementPage(
          gateway: gateway,
          origin: Uri.parse('http://127.0.0.1:18473'),
          session: _session(),
          onCurrentDeviceAuthoritativelyRevoked: () async {
            authoritativeAbandonCalls++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, '退出全部设备'));
    await tester.pumpAndSettle();

    expect(gateway.logoutAllCalls, 1);
    expect(authoritativeAbandonCalls, 0);
    expect(find.textContaining('操作失败'), findsOneWidget);
  });

  testWidgets('remote-device revoke never abandons current push lease', (
    tester,
  ) async {
    var authoritativeAbandonCalls = 0;
    final gateway = _AccountGateway()
      ..devices = [
        AccountDevice(
          id: 'd2',
          name: 'Android',
          platform: 'ANDROID',
          appVersion: 'dev',
          createdAt: DateTime.utc(2026, 8, 9),
          lastSeenAt: DateTime.utc(2026, 8, 13),
          current: false,
          revoked: false,
        ),
      ];
    await tester.pumpWidget(
      MaterialApp(
        home: AccountManagementPage(
          gateway: gateway,
          origin: Uri.parse('http://127.0.0.1:18473'),
          session: _session(),
          onCurrentDeviceAuthoritativelyRevoked: () async {
            authoritativeAbandonCalls++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, '远程退出'));
    await tester.pumpAndSettle();

    expect(gateway.revokeDeviceCalls, 1);
    expect(authoritativeAbandonCalls, 0);
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
  List<AccountDevice> devices = const [];
  int clearRevokedCalls = 0;
  int revokeDeviceCalls = 0;
  int logoutAllCalls = 0;
  Object? revokeDeviceError;
  Object? logoutAllError;

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
  }) async => List<AccountDevice>.from(devices);

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
  }) async {
    revokeDeviceCalls++;
    final error = revokeDeviceError;
    if (error != null) throw error;
  }
  @override
  Future<int> clearRevokedDevices({
    required Uri origin,
    required String accessToken,
  }) async {
    clearRevokedCalls++;
    final count = devices.where((device) => device.revoked).length;
    devices = devices
        .where((device) => !device.revoked)
        .toList(growable: false);
    return count;
  }

  @override
  Future<void> logoutAll({
    required Uri origin,
    required String accessToken,
  }) async {
    logoutAllCalls++;
    final error = logoutAllError;
    if (error != null) throw error;
  }
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
