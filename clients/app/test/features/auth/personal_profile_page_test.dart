import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/auth/data/auth_api_client.dart';
import 'package:im_client/features/auth/domain/account_management.dart';
import 'package:im_client/features/auth/domain/auth_session.dart';
import 'package:im_client/features/auth/presentation/personal_profile_page.dart';

void main() {
  testWidgets('nickname DDID and bio are edited only from personal profile', (
    tester,
  ) async {
    final gateway = _ProfileGateway();
    AccountMe? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: PersonalProfilePage(
          gateway: gateway,
          origin: Uri.parse('http://127.0.0.1:18473'),
          session: _session(),
          avatarRevision: 0,
          onViewAvatar: () async {},
          onChangeAvatar: () async {},
          onRemoveAvatar: () async {},
          onProfileChanged: (value) async => changed = value,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('alice'), findsOneWidget);
    expect(find.text('bio'), findsOneWidget);

    await tester.tap(find.byKey(const Key('profile-edit-display-name')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('profile-edit-field')),
      'Alice New',
    );
    await tester.tap(find.byKey(const Key('profile-edit-save')));
    await tester.pumpAndSettle();

    expect(gateway.lastDisplayName, 'Alice New');
    expect(find.text('Alice New'), findsOneWidget);
    expect(changed?.profile.displayName, 'Alice New');

    await tester.tap(find.byKey(const Key('profile-edit-ddid')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('profile-edit-field')),
      'alice_new',
    );
    await tester.tap(find.byKey(const Key('profile-edit-save')));
    await tester.pumpAndSettle();

    expect(gateway.lastHandle, 'alice_new');
    expect(find.text('alice_new'), findsOneWidget);

    await tester.tap(find.byKey(const Key('profile-edit-bio')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('profile-edit-field')),
      'new bio',
    );
    await tester.tap(find.byKey(const Key('profile-edit-save')));
    await tester.pumpAndSettle();

    expect(gateway.lastBio, 'new bio');
    expect(find.text('new bio'), findsOneWidget);
  });

  testWidgets('email change requires a verification code', (tester) async {
    final gateway = _ProfileGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: PersonalProfilePage(
          gateway: gateway,
          origin: Uri.parse('http://127.0.0.1:18473'),
          session: _session(),
          avatarRevision: 0,
          onViewAvatar: () async {},
          onChangeAvatar: () async {},
          onRemoveAvatar: () async {},
          onProfileChanged: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('profile-edit-email')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('profile-email-field')),
      'new@example.com',
    );
    await tester.tap(find.byKey(const Key('profile-email-send-code')));
    await tester.pumpAndSettle();

    expect(gateway.sentCodeEmail, 'new@example.com');
    expect(find.byKey(const Key('profile-email-code-field')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('profile-email-code-field')),
      '123456',
    );
    await tester.tap(find.byKey(const Key('profile-email-confirm')));
    await tester.pumpAndSettle();

    expect(gateway.changedEmail, 'new@example.com');
    expect(gateway.changedCode, '123456');
    expect(find.text('new@example.com'), findsOneWidget);
  });

  testWidgets('failed profile save does not replace visible values', (
    tester,
  ) async {
    final gateway = _ProfileGateway()..failUpdate = true;
    await tester.pumpWidget(
      MaterialApp(
        home: PersonalProfilePage(
          gateway: gateway,
          origin: Uri.parse('http://127.0.0.1:18473'),
          session: _session(),
          avatarRevision: 0,
          onViewAvatar: () async {},
          onChangeAvatar: () async {},
          onRemoveAvatar: () async {},
          onProfileChanged: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('profile-edit-display-name')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('profile-edit-field')),
      'Should Not Stick',
    );
    await tester.tap(find.byKey(const Key('profile-edit-save')));
    await tester.pumpAndSettle();

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Should Not Stick'), findsNothing);
    expect(find.textContaining('保存失败'), findsOneWidget);
  });
}

final class _ProfileGateway implements AuthGateway {
  AccountMe me = _me();
  String lastHandle = '';
  String lastDisplayName = '';
  String lastBio = '';
  String sentCodeEmail = '';
  String changedEmail = '';
  String changedCode = '';
  bool failUpdate = false;

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
    if (failUpdate) throw Exception('network down');
    lastHandle = handle;
    lastDisplayName = displayName;
    lastBio = bio;
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
  }) async => DateTime.utc(2026, 8, 10);
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
    accessExpiresAt: DateTime.utc(2026, 8, 10, 1),
    refreshToken: 'refresh',
    refreshExpiresAt: DateTime.utc(2026, 9, 10),
  ),
);
