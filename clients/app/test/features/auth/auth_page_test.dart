import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:im_client/core/security/dd_secure_storage.dart';
import 'package:im_client/features/auth/data/auth_api_client.dart';
import 'package:im_client/features/auth/data/auth_session_vault.dart';
import 'package:im_client/features/auth/data/login_history_store.dart';
import 'package:im_client/features/auth/domain/account_management.dart';
import 'package:im_client/features/auth/domain/auth_session.dart';
import 'package:im_client/features/auth/presentation/auth_page.dart';
import 'package:im_client/features/push/application/push_registration_service.dart';

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

  testWidgets('registration code send starts a 60 second resend cooldown', (
    tester,
  ) async {
    final gateway = _FakeAuthGateway();
    await tester.pumpWidget(MaterialApp(home: AuthPage(gateway: gateway)));
    await tester.pumpAndSettle();

    final sendButton = find.byKey(const Key('auth-send-code'));
    expect(find.text('发送验证码'), findsOneWidget);
    expect(tester.widget<FilledButton>(sendButton).onPressed, isNotNull);

    await tester.tap(sendButton);
    await tester.pumpAndSettle();

    expect(gateway.sendRegistrationCodeCount, 1);
    expect(tester.widget<FilledButton>(sendButton).onPressed, isNull);
    expect(
      tester.widget<TextField>(find.byKey(const Key('auth-email'))).enabled,
      isTrue,
    );
    expect(find.text('60 秒后重试'), findsOneWidget);
    expect(find.text('验证码发送成功，收不到就去邮箱垃圾箱看看'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('59 秒后重试'), findsOneWidget);

    await tester.tap(find.widgetWithText(Tab, '登录'));
    await tester.pump();
    await tester.tap(find.widgetWithText(Tab, '注册'));
    await tester.pump();
    expect(find.text('59 秒后重试'), findsOneWidget);

    await tester.pump(const Duration(seconds: 59));
    expect(find.text('发送验证码'), findsOneWidget);
    expect(tester.widget<FilledButton>(sendButton).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed registration code send does not start cooldown', (
    tester,
  ) async {
    final gateway = _FakeAuthGateway()
      ..sendRegistrationCodeError = const AuthApiException(
        statusCode: 429,
        code: 'RATE_LIMITED',
        message: 'rate limited',
      );
    await tester.pumpWidget(MaterialApp(home: AuthPage(gateway: gateway)));
    await tester.pumpAndSettle();

    final sendButton = find.byKey(const Key('auth-send-code'));
    await tester.tap(sendButton);
    await tester.pumpAndSettle();

    expect(gateway.sendRegistrationCodeCount, 1);
    expect(find.text('发送验证码'), findsOneWidget);
    expect(tester.widget<FilledButton>(sendButton).onPressed, isNotNull);
    expect(find.textContaining('秒后重试'), findsNothing);
    expect(find.text('验证码发送太频繁，请稍后再试。'), findsOneWidget);
  });

  testWidgets('registration code cooldown timer is cancelled on dispose', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: AuthPage(gateway: _FakeAuthGateway())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('auth-send-code')));
    await tester.pumpAndSettle();
    expect(find.text('60 秒后重试'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 61));

    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'registration uses DDID wording and login history pre-fills account',
    (tester) async {
      final history = _MemoryLoginHistory([
        LoginHistoryEntry(
          origin: Uri.parse('http://127.0.0.1:18473'),
          userId: 'history-user',
          email: 'history@example.com',
          ddid: 'history_01',
          displayName: '历史用户',
          lastUsedAt: DateTime.utc(2026, 8, 9, 6),
        ),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: AuthPage(gateway: _FakeAuthGateway(), historyStore: history),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('DDID'), findsOneWidget);
      expect(find.text('账号短号'), findsNothing);

      await tester.tap(find.widgetWithText(Tab, '登录'));
      await tester.pumpAndSettle();
      expect(find.text('历史登录'), findsOneWidget);
      expect(find.text('历史用户'), findsOneWidget);
      expect(find.textContaining('DDID：history_01'), findsOneWidget);

      await tester.tap(find.byKey(const Key('login-history-history-user')));
      await tester.pump();
      final email = tester.widget<TextField>(
        find.byKey(const Key('auth-email')),
      );
      expect(email.controller?.text, 'history@example.com');
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('auth-password')))
            .focusNode
            ?.hasFocus,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('transient restore failure preserves stored refresh session', (
    tester,
  ) async {
    final origin = Uri.parse('https://api.85746.pro');
    final vault = AuthSessionVault(storage: _MemorySecureStore());
    await vault.save(origin: origin, refreshToken: 'refresh-preserved');
    final gateway = _SwitchAuthGateway()
      ..refreshHandler = (_) async => throw http.ClientException(
        'Connection closed before full header was received',
      );

    await tester.pumpWidget(
      MaterialApp(
        home: AuthPage(
          gateway: gateway,
          vault: vault,
          initialOrigin: origin,
          restoreSession: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect((await vault.read())?.refreshToken, 'refresh-preserved');
    expect(find.textContaining('网络'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('A release failure never consumes B stored refresh token', (
    tester,
  ) async {
    final origin = Uri.parse('http://127.0.0.1:18473');
    final storage = _MemorySecureStore();
    final vault = AuthSessionVault(storage: storage);
    await vault.saveAccount(
      origin: origin,
      userId: 'user-b',
      refreshToken: 'refresh-b-old',
    );
    final gateway = _SwitchAuthGateway()
      ..refreshHandler = (refreshToken) async => _sessionFor(
        userId: 'user-b',
        displayName: 'User B',
        deviceId: 'device-b',
        accessToken: 'access-b-new',
        refreshToken: 'refresh-b-new',
      );
    final push = _FakePushAccountLeaseController()
      ..releaseError = StateError('endpoint delete failed');
    final history = _MemoryLoginHistory([
      LoginHistoryEntry(
        origin: origin,
        userId: 'user-b',
        email: 'b@example.com',
        ddid: 'user_b',
        displayName: 'User B',
        lastUsedAt: DateTime.utc(2026, 8, 13),
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: AuthPage(
          gateway: gateway,
          historyStore: history,
          vault: vault,
          initialSession: _sessionFor(
            userId: 'user-a',
            displayName: 'User A',
            deviceId: 'device-a',
            accessToken: 'access-a',
            refreshToken: 'refresh-a',
          ),
          initialOrigin: origin,
          restoreSession: false,
          pushAccountLeaseController: push,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await _openAccountManagerAndSelect(tester, 'user-b');

    expect(push.releaseCalls, 1);
    expect(gateway.refreshTokens, isEmpty);
    expect(
      (await vault.readAccount(origin: origin, userId: 'user-b'))?.refreshToken,
      'refresh-b-old',
    );
    expect(find.text('User A'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('B refresh failure restores A push and keeps A session active', (
    tester,
  ) async {
    final origin = Uri.parse('http://127.0.0.1:18473');
    final storage = _MemorySecureStore();
    final vault = AuthSessionVault(storage: storage);
    await vault.saveAccount(
      origin: origin,
      userId: 'user-b',
      refreshToken: 'refresh-b-old',
    );
    final gateway = _SwitchAuthGateway()
      ..refreshHandler = (refreshToken) async => throw const AuthApiException(
        statusCode: 503,
        code: 'TEMPORARY',
        message: 'temporary failure',
      );
    final push = _FakePushAccountLeaseController();
    final history = _MemoryLoginHistory([
      LoginHistoryEntry(
        origin: origin,
        userId: 'user-b',
        email: 'b@example.com',
        ddid: 'user_b',
        displayName: 'User B',
        lastUsedAt: DateTime.utc(2026, 8, 13),
      ),
    ]);
    final sessionA = _sessionFor(
      userId: 'user-a',
      displayName: 'User A',
      deviceId: 'device-a',
      accessToken: 'access-a',
      refreshToken: 'refresh-a',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: AuthPage(
          gateway: gateway,
          historyStore: history,
          vault: vault,
          initialSession: sessionA,
          initialOrigin: origin,
          restoreSession: false,
          pushAccountLeaseController: push,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await _openAccountManagerAndSelect(tester, 'user-b');

    expect(gateway.refreshTokens, <String>['refresh-b-old']);
    expect(push.releaseCalls, 1);
    expect(push.starts, hasLength(1));
    expect(push.starts.single.userId, 'user-a');
    expect(push.starts.single.accessToken, 'access-a');
    expect(find.text('User A'), findsWidgets);
    expect(
      (await vault.readAccount(origin: origin, userId: 'user-b'))?.refreshToken,
      'refresh-b-old',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('successful B refresh persists rotated token before switching UI', (
    tester,
  ) async {
    final origin = Uri.parse('http://127.0.0.1:18473');
    final storage = _MemorySecureStore();
    final vault = AuthSessionVault(storage: storage);
    await vault.saveAccount(
      origin: origin,
      userId: 'user-b',
      refreshToken: 'refresh-b-old',
    );
    final gateway = _SwitchAuthGateway()
      ..refreshHandler = (refreshToken) async => _sessionFor(
        userId: 'user-b',
        displayName: 'User B',
        deviceId: 'device-b',
        accessToken: 'access-b-new',
        refreshToken: 'refresh-b-new',
      );
    final push = _FakePushAccountLeaseController();
    final history = _MemoryLoginHistory([
      LoginHistoryEntry(
        origin: origin,
        userId: 'user-b',
        email: 'b@example.com',
        ddid: 'user_b',
        displayName: 'User B',
        lastUsedAt: DateTime.utc(2026, 8, 13),
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: AuthPage(
          gateway: gateway,
          historyStore: history,
          vault: vault,
          initialSession: _sessionFor(
            userId: 'user-a',
            displayName: 'User A',
            deviceId: 'device-a',
            accessToken: 'access-a',
            refreshToken: 'refresh-a',
          ),
          initialOrigin: origin,
          restoreSession: false,
          pushAccountLeaseController: push,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await _openAccountManagerAndSelect(tester, 'user-b');

    expect(gateway.refreshTokens, <String>['refresh-b-old']);
    expect(
      (await vault.readAccount(origin: origin, userId: 'user-b'))?.refreshToken,
      'refresh-b-new',
    );
    expect((await vault.read())?.refreshToken, 'refresh-b-new');
    expect(find.byKey(const ValueKey('user-b-device-b')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('late A refresh success cannot replace B and only persists A account token', (
    tester,
  ) async {
    final originA = Uri.parse('http://127.0.0.1:18473');
    final originB = Uri.parse('http://127.0.0.1:28473');
    final storage = _MemorySecureStore();
    final vault = AuthSessionVault(storage: storage);
    await vault.save(origin: originA, refreshToken: 'refresh-a-old');
    await vault.saveAccount(
      origin: originA,
      userId: 'user-a',
      refreshToken: 'refresh-a-old',
    );
    await vault.saveAccount(
      origin: originB,
      userId: 'user-b',
      refreshToken: 'refresh-b-old',
    );
    final lateA = Completer<AuthSession>();
    final gateway = _SwitchAuthGateway()
      ..refreshHandler = (refreshToken) {
        if (refreshToken == 'refresh-a-old') return lateA.future;
        if (refreshToken == 'refresh-b-old') {
          return Future<AuthSession>.value(
            _sessionFor(
              userId: 'user-b',
              displayName: 'User B',
              deviceId: 'device-b',
              accessToken: 'access-b-new',
              refreshToken: 'refresh-b-new',
            ),
          );
        }
        throw StateError('unexpected refresh token $refreshToken');
      };
    final push = _FakePushAccountLeaseController();
    final history = _MemoryLoginHistory([
      LoginHistoryEntry(
        origin: originB,
        userId: 'user-b',
        email: 'b@example.com',
        ddid: 'user_b',
        displayName: 'User B',
        lastUsedAt: DateTime.utc(2026, 8, 13),
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: AuthPage(
          gateway: gateway,
          historyStore: history,
          vault: vault,
          initialSession: _sessionFor(
            userId: 'user-a',
            displayName: 'User A',
            deviceId: 'device-a',
            accessToken: 'access-a-old',
            refreshToken: 'refresh-a-old',
            accessExpiresAt: DateTime.now().toUtc().add(
              const Duration(seconds: 1),
            ),
          ),
          initialOrigin: originA,
          restoreSession: false,
          pushAccountLeaseController: push,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(gateway.refreshTokens, <String>['refresh-a-old']);

    await _openAccountManagerAndSelect(tester, 'user-b');
    expect(find.byKey(const ValueKey('user-b-device-b')), findsOneWidget);
    expect(gateway.refreshTokens, <String>['refresh-a-old', 'refresh-b-old']);

    lateA.complete(
      _sessionFor(
        userId: 'user-a',
        displayName: 'User A',
        deviceId: 'device-a',
        accessToken: 'access-a-new',
        refreshToken: 'refresh-a-new',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('user-b-device-b')), findsOneWidget);
    expect(push.abandonCalls, 0);
    expect((await vault.read())?.origin.origin, originB.origin);
    expect((await vault.read())?.refreshToken, 'refresh-b-new');
    expect(
      (await vault.readAccount(origin: originA, userId: 'user-a'))?.refreshToken,
      'refresh-a-new',
    );
    expect(
      (await vault.readAccount(origin: originB, userId: 'user-b'))?.refreshToken,
      'refresh-b-new',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('late A refresh 401 cannot clear or abandon active B session', (
    tester,
  ) async {
    final originA = Uri.parse('http://127.0.0.1:18473');
    final originB = Uri.parse('http://127.0.0.1:28473');
    final storage = _MemorySecureStore();
    final vault = AuthSessionVault(storage: storage);
    await vault.save(origin: originA, refreshToken: 'refresh-a-old');
    await vault.saveAccount(
      origin: originA,
      userId: 'user-a',
      refreshToken: 'refresh-a-old',
    );
    await vault.saveAccount(
      origin: originB,
      userId: 'user-b',
      refreshToken: 'refresh-b-old',
    );
    final lateA = Completer<AuthSession>();
    final gateway = _SwitchAuthGateway()
      ..refreshHandler = (refreshToken) {
        if (refreshToken == 'refresh-a-old') return lateA.future;
        if (refreshToken == 'refresh-b-old') {
          return Future<AuthSession>.value(
            _sessionFor(
              userId: 'user-b',
              displayName: 'User B',
              deviceId: 'device-b',
              accessToken: 'access-b-new',
              refreshToken: 'refresh-b-new',
            ),
          );
        }
        throw StateError('unexpected refresh token $refreshToken');
      };
    final push = _FakePushAccountLeaseController();
    final history = _MemoryLoginHistory([
      LoginHistoryEntry(
        origin: originB,
        userId: 'user-b',
        email: 'b@example.com',
        ddid: 'user_b',
        displayName: 'User B',
        lastUsedAt: DateTime.utc(2026, 8, 13),
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: AuthPage(
          gateway: gateway,
          historyStore: history,
          vault: vault,
          initialSession: _sessionFor(
            userId: 'user-a',
            displayName: 'User A',
            deviceId: 'device-a',
            accessToken: 'access-a-old',
            refreshToken: 'refresh-a-old',
            accessExpiresAt: DateTime.now().toUtc().add(
              const Duration(seconds: 1),
            ),
          ),
          initialOrigin: originA,
          restoreSession: false,
          pushAccountLeaseController: push,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    await _openAccountManagerAndSelect(tester, 'user-b');
    expect(find.byKey(const ValueKey('user-b-device-b')), findsOneWidget);

    lateA.completeError(
      const AuthApiException(
        statusCode: 401,
        code: 'SESSION_EXPIRED',
        message: 'Session is no longer valid',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('user-b-device-b')), findsOneWidget);
    expect(push.abandonCalls, 0);
    expect((await vault.read())?.origin.origin, originB.origin);
    expect((await vault.read())?.refreshToken, 'refresh-b-new');
    expect(
      (await vault.readAccount(origin: originB, userId: 'user-b'))?.refreshToken,
      'refresh-b-new',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('account transition blocks a new A timer refresh while endpoint release waits', (
    tester,
  ) async {
    final origin = Uri.parse('http://127.0.0.1:18473');
    final storage = _MemorySecureStore();
    final vault = AuthSessionVault(storage: storage);
    await vault.saveAccount(
      origin: origin,
      userId: 'user-b',
      refreshToken: 'refresh-b-old',
    );
    final releaseCompleter = Completer<void>();
    final push = _FakePushAccountLeaseController()
      ..releaseCompleter = releaseCompleter;
    final gateway = _SwitchAuthGateway()
      ..refreshHandler = (refreshToken) async {
        if (refreshToken == 'refresh-a-old') {
          return _sessionFor(
            userId: 'user-a',
            displayName: 'User A',
            deviceId: 'device-a',
            accessToken: 'access-a-new',
            refreshToken: 'refresh-a-new',
          );
        }
        return _sessionFor(
          userId: 'user-b',
          displayName: 'User B',
          deviceId: 'device-b',
          accessToken: 'access-b-new',
          refreshToken: 'refresh-b-new',
        );
      };
    final history = _MemoryLoginHistory([
      LoginHistoryEntry(
        origin: origin,
        userId: 'user-b',
        email: 'b@example.com',
        ddid: 'user_b',
        displayName: 'User B',
        lastUsedAt: DateTime.utc(2026, 8, 13),
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: AuthPage(
          gateway: gateway,
          historyStore: history,
          vault: vault,
          initialSession: _sessionFor(
            userId: 'user-a',
            displayName: 'User A',
            deviceId: 'device-a',
            accessToken: 'access-a-old',
            refreshToken: 'refresh-a-old',
            accessExpiresAt: DateTime.now().toUtc().add(
              const Duration(seconds: 1),
            ),
          ),
          initialOrigin: origin,
          restoreSession: false,
          pushAccountLeaseController: push,
        ),
      ),
    );
    await tester.pump();
    await _openAccountManagerAndSelect(tester, 'user-b');
    expect(push.releaseCalls, 1);

    await tester.pump(const Duration(seconds: 6));
    expect(gateway.refreshTokens, isEmpty);

    releaseCompleter.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(gateway.refreshTokens, <String>['refresh-b-old']);
    expect(find.byKey(const ValueKey('user-b-device-b')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('A release failure restores A refresh scheduling without consuming B', (
    tester,
  ) async {
    final origin = Uri.parse('http://127.0.0.1:18473');
    final storage = _MemorySecureStore();
    final vault = AuthSessionVault(storage: storage);
    await vault.saveAccount(
      origin: origin,
      userId: 'user-b',
      refreshToken: 'refresh-b-old',
    );
    final gateway = _SwitchAuthGateway()
      ..refreshHandler = (refreshToken) async {
        if (refreshToken != 'refresh-a-old') {
          throw StateError('B refresh must not be consumed');
        }
        return _sessionFor(
          userId: 'user-a',
          displayName: 'User A',
          deviceId: 'device-a',
          accessToken: 'access-a-new',
          refreshToken: 'refresh-a-new',
        );
      };
    final push = _FakePushAccountLeaseController()
      ..releaseError = StateError('endpoint delete failed');
    final history = _MemoryLoginHistory([
      LoginHistoryEntry(
        origin: origin,
        userId: 'user-b',
        email: 'b@example.com',
        ddid: 'user_b',
        displayName: 'User B',
        lastUsedAt: DateTime.utc(2026, 8, 13),
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: AuthPage(
          gateway: gateway,
          historyStore: history,
          vault: vault,
          initialSession: _sessionFor(
            userId: 'user-a',
            displayName: 'User A',
            deviceId: 'device-a',
            accessToken: 'access-a-old',
            refreshToken: 'refresh-a-old',
            accessExpiresAt: DateTime.now().toUtc().add(
              const Duration(seconds: 1),
            ),
          ),
          initialOrigin: origin,
          restoreSession: false,
          pushAccountLeaseController: push,
        ),
      ),
    );
    await tester.pump();
    await _openAccountManagerAndSelect(tester, 'user-b');
    expect(gateway.refreshTokens, isEmpty);

    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(gateway.refreshTokens, <String>['refresh-a-old']);
    expect(find.text('User A'), findsWidgets);
    expect(
      (await vault.readAccount(origin: origin, userId: 'user-b'))?.refreshToken,
      'refresh-b-old',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('failed endpoint delete plus successful revoke authoritatively abandons lease', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(881, 657);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final origin = Uri.parse('http://127.0.0.1:18473');
    final gateway = _SwitchAuthGateway();
    final push = _FakePushAccountLeaseController()
      ..releaseError = StateError('endpoint delete failed');

    await tester.pumpWidget(
      MaterialApp(
        home: AuthPage(
          gateway: gateway,
          vault: AuthSessionVault(storage: _MemorySecureStore()),
          initialSession: _sessionFor(
            userId: 'user-a',
            displayName: 'User A',
            deviceId: 'device-a',
            accessToken: 'access-a',
            refreshToken: 'refresh-a',
          ),
          initialOrigin: origin,
          restoreSession: false,
          pushAccountLeaseController: push,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('shell-rail-me')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final logout = find.byKey(const Key('shell-logout'));
    await tester.ensureVisible(logout);
    await tester.pump();
    await tester.tap(logout);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(push.releaseCalls, 1);
    expect(gateway.revokedDeviceIds, <String>['device-a']);
    expect(push.abandonCalls, 1);
    expect(find.byKey(const Key('auth-email')), findsOneWidget);
  });

  testWidgets('logout ordinary access-token 401 preserves auth and push cleanup ownership', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(881, 657);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final origin = Uri.parse('http://127.0.0.1:18473');
    final storage = _MemorySecureStore();
    final vault = AuthSessionVault(storage: storage);
    await vault.save(origin: origin, refreshToken: 'refresh-a');
    await vault.saveAccount(
      origin: origin,
      userId: 'user-a',
      refreshToken: 'refresh-a',
    );
    final gateway = _SwitchAuthGateway()
      ..revokeDeviceError = const AuthApiException(
        statusCode: 401,
        code: 'UNAUTHORIZED',
        message: 'Valid access token is required',
      );
    final push = _FakePushAccountLeaseController()
      ..releaseError = StateError('endpoint delete unauthorized');

    await tester.pumpWidget(
      MaterialApp(
        home: AuthPage(
          gateway: gateway,
          vault: vault,
          initialSession: _sessionFor(
            userId: 'user-a',
            displayName: 'User A',
            deviceId: 'device-a',
            accessToken: 'access-a',
            refreshToken: 'refresh-a',
          ),
          initialOrigin: origin,
          restoreSession: false,
          pushAccountLeaseController: push,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('shell-rail-me')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final logout = find.byKey(const Key('shell-logout'));
    await tester.ensureVisible(logout);
    await tester.pump();
    await tester.tap(logout);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(push.releaseCalls, 1);
    expect(gateway.revokedDeviceIds, <String>['device-a']);
    expect(push.abandonCalls, 0);
    expect(find.byKey(const ValueKey('user-a-device-a')), findsOneWidget);
    expect(find.byKey(const Key('auth-email')), findsNothing);
    expect(find.textContaining('无法确认本设备已安全退出'), findsOneWidget);
    expect((await vault.read())?.refreshToken, 'refresh-a');
    expect(
      (await vault.readAccount(origin: origin, userId: 'user-a'))?.refreshToken,
      'refresh-a',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('logout network revoke failure preserves current session and vault when endpoint release failed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(881, 657);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final origin = Uri.parse('http://127.0.0.1:18473');
    final storage = _MemorySecureStore();
    final vault = AuthSessionVault(storage: storage);
    await vault.save(origin: origin, refreshToken: 'refresh-a');
    await vault.saveAccount(
      origin: origin,
      userId: 'user-a',
      refreshToken: 'refresh-a',
    );
    final gateway = _SwitchAuthGateway()
      ..revokeDeviceError = StateError('network timeout');
    final push = _FakePushAccountLeaseController()
      ..releaseError = StateError('endpoint delete timeout');

    await tester.pumpWidget(
      MaterialApp(
        home: AuthPage(
          gateway: gateway,
          vault: vault,
          initialSession: _sessionFor(
            userId: 'user-a',
            displayName: 'User A',
            deviceId: 'device-a',
            accessToken: 'access-a',
            refreshToken: 'refresh-a',
          ),
          initialOrigin: origin,
          restoreSession: false,
          pushAccountLeaseController: push,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('shell-rail-me')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final logout = find.byKey(const Key('shell-logout'));
    await tester.ensureVisible(logout);
    await tester.pump();
    await tester.tap(logout);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(push.releaseCalls, 1);
    expect(push.abandonCalls, 0);
    expect(find.byKey(const ValueKey('user-a-device-a')), findsOneWidget);
    expect((await vault.read())?.refreshToken, 'refresh-a');
    expect(
      (await vault.readAccount(origin: origin, userId: 'user-a'))?.refreshToken,
      'refresh-a',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('in-flight refresh 401 during failed logout cannot delete the current A credential', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(881, 657);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final origin = Uri.parse('http://127.0.0.1:18473');
    final storage = _MemorySecureStore();
    final vault = AuthSessionVault(storage: storage);
    await vault.save(origin: origin, refreshToken: 'refresh-a');
    await vault.saveAccount(
      origin: origin,
      userId: 'user-a',
      refreshToken: 'refresh-a',
    );
    final refreshCompleter = Completer<AuthSession>();
    final releaseCompleter = Completer<void>();
    final gateway = _SwitchAuthGateway()
      ..refreshHandler = (_) {
        return refreshCompleter.future;
      }
      ..revokeDeviceError = const AuthApiException(
        statusCode: 401,
        code: 'UNAUTHORIZED',
        message: 'Valid access token is required',
      );
    final push = _FakePushAccountLeaseController()
      ..releaseCompleter = releaseCompleter;

    await tester.pumpWidget(
      MaterialApp(
        home: AuthPage(
          gateway: gateway,
          vault: vault,
          initialSession: _sessionFor(
            userId: 'user-a',
            displayName: 'User A',
            deviceId: 'device-a',
            accessToken: 'access-a',
            refreshToken: 'refresh-a',
            accessExpiresAt: DateTime.now().toUtc().add(
              const Duration(seconds: 1),
            ),
          ),
          initialOrigin: origin,
          restoreSession: false,
          pushAccountLeaseController: push,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(gateway.refreshTokens, <String>['refresh-a']);

    await tester.tap(find.byKey(const Key('shell-rail-me')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final logout = find.byKey(const Key('shell-logout'));
    await tester.ensureVisible(logout);
    await tester.pump();
    await tester.tap(logout);
    await tester.pump();
    expect(push.releaseCalls, 1);

    refreshCompleter.completeError(
      const AuthApiException(
        statusCode: 401,
        code: 'SESSION_EXPIRED',
        message: 'Session is no longer valid',
      ),
    );
    await tester.pump();
    push.releaseError = StateError('endpoint delete failed');
    releaseCompleter.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('user-a-device-a')), findsOneWidget);
    expect((await vault.read())?.refreshToken, 'refresh-a');
    expect(
      (await vault.readAccount(origin: origin, userId: 'user-a'))?.refreshToken,
      'refresh-a',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('successful endpoint release permits local logout even when revoke API fails', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(881, 657);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final origin = Uri.parse('http://127.0.0.1:18473');
    final storage = _MemorySecureStore();
    final vault = AuthSessionVault(storage: storage);
    await vault.save(origin: origin, refreshToken: 'refresh-a');
    await vault.saveAccount(
      origin: origin,
      userId: 'user-a',
      refreshToken: 'refresh-a',
    );
    final gateway = _SwitchAuthGateway()
      ..revokeDeviceError = StateError('network timeout');
    final push = _FakePushAccountLeaseController();

    await tester.pumpWidget(
      MaterialApp(
        home: AuthPage(
          gateway: gateway,
          vault: vault,
          initialSession: _sessionFor(
            userId: 'user-a',
            displayName: 'User A',
            deviceId: 'device-a',
            accessToken: 'access-a',
            refreshToken: 'refresh-a',
          ),
          initialOrigin: origin,
          restoreSession: false,
          pushAccountLeaseController: push,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('shell-rail-me')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final logout = find.byKey(const Key('shell-logout'));
    await tester.ensureVisible(logout);
    await tester.pump();
    await tester.tap(logout);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(push.releaseCalls, 1);
    expect(push.abandonCalls, 0);
    expect(find.byKey(const Key('auth-email')), findsOneWidget);
    expect(await vault.read(), isNull);
    expect(await vault.readAccount(origin: origin, userId: 'user-a'), isNull);
  });

  testWidgets('failed logout cannot be followed by a B switch while stale A lease remains', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(881, 657);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final origin = Uri.parse('http://127.0.0.1:18473');
    final storage = _MemorySecureStore();
    final vault = AuthSessionVault(storage: storage);
    await vault.save(origin: origin, refreshToken: 'refresh-a');
    await vault.saveAccount(
      origin: origin,
      userId: 'user-a',
      refreshToken: 'refresh-a',
    );
    await vault.saveAccount(
      origin: origin,
      userId: 'user-b',
      refreshToken: 'refresh-b-old',
    );
    final gateway = _SwitchAuthGateway()
      ..revokeDeviceError = const AuthApiException(
        statusCode: 401,
        code: 'UNAUTHORIZED',
        message: 'Valid access token is required',
      )
      ..refreshHandler = (refreshToken) async => _sessionFor(
        userId: 'user-b',
        displayName: 'User B',
        deviceId: 'device-b',
        accessToken: 'access-b-new',
        refreshToken: 'refresh-b-new',
      );
    final push = _FakePushAccountLeaseController()
      ..releaseError = StateError('stale A endpoint cannot be deleted');
    final history = _MemoryLoginHistory([
      LoginHistoryEntry(
        origin: origin,
        userId: 'user-b',
        email: 'b@example.com',
        ddid: 'user_b',
        displayName: 'User B',
        lastUsedAt: DateTime.utc(2026, 8, 13),
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: AuthPage(
          gateway: gateway,
          historyStore: history,
          vault: vault,
          initialSession: _sessionFor(
            userId: 'user-a',
            displayName: 'User A',
            deviceId: 'device-a',
            accessToken: 'access-a',
            refreshToken: 'refresh-a',
          ),
          initialOrigin: origin,
          restoreSession: false,
          pushAccountLeaseController: push,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('shell-rail-me')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final logout = find.byKey(const Key('shell-logout'));
    await tester.ensureVisible(logout);
    await tester.pump();
    await tester.tap(logout);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('user-a-device-a')), findsOneWidget);
    await _openAccountManagerAndSelect(tester, 'user-b');

    expect(push.releaseCalls, 2);
    expect(gateway.refreshTokens, isEmpty);
    expect(find.byKey(const ValueKey('user-a-device-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('user-b-device-b')), findsNothing);
    expect(
      (await vault.readAccount(origin: origin, userId: 'user-b'))?.refreshToken,
      'refresh-b-old',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('logout explicit DEVICE_SESSION_REVOKED may authoritatively abandon push lease', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(881, 657);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final origin = Uri.parse('http://127.0.0.1:18473');
    final gateway = _SwitchAuthGateway()
      ..revokeDeviceError = const AuthApiException(
        statusCode: 401,
        code: 'DEVICE_SESSION_REVOKED',
        message: 'Device session has been revoked',
      );
    final push = _FakePushAccountLeaseController()
      ..releaseError = StateError('endpoint delete unauthorized');

    await tester.pumpWidget(
      MaterialApp(
        home: AuthPage(
          gateway: gateway,
          vault: AuthSessionVault(storage: _MemorySecureStore()),
          initialSession: _sessionFor(
            userId: 'user-a',
            displayName: 'User A',
            deviceId: 'device-a',
            accessToken: 'access-a',
            refreshToken: 'refresh-a',
          ),
          initialOrigin: origin,
          restoreSession: false,
          pushAccountLeaseController: push,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('shell-rail-me')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final logout = find.byKey(const Key('shell-logout'));
    await tester.ensureVisible(logout);
    await tester.pump();
    await tester.tap(logout);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(push.abandonCalls, 1);
    expect(find.byKey(const Key('auth-email')), findsOneWidget);
  });

  testWidgets('SESSION_EXPIRED can clear local auth after endpoint delete succeeds', (
    tester,
  ) async {
    final origin = Uri.parse('http://127.0.0.1:18473');
    final storage = _MemorySecureStore();
    final vault = AuthSessionVault(storage: storage);
    await vault.save(origin: origin, refreshToken: 'refresh-a');
    await vault.saveAccount(
      origin: origin,
      userId: 'user-a',
      refreshToken: 'refresh-a',
    );
    final gateway = _SwitchAuthGateway()
      ..refreshHandler = (refreshToken) async {
        throw const AuthApiException(
          statusCode: 401,
          code: 'SESSION_EXPIRED',
          message: 'Session is no longer valid',
        );
      }
      ..revokeDeviceError = StateError('revoke network unavailable');
    final push = _FakePushAccountLeaseController();

    await tester.pumpWidget(
      MaterialApp(
        home: AuthPage(
          gateway: gateway,
          vault: vault,
          initialSession: _sessionFor(
            userId: 'user-a',
            displayName: 'User A',
            deviceId: 'device-a',
            accessToken: 'access-a',
            refreshToken: 'refresh-a',
            accessExpiresAt: DateTime.now().toUtc().add(
              const Duration(seconds: 1),
            ),
          ),
          initialOrigin: origin,
          restoreSession: false,
          pushAccountLeaseController: push,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();

    expect(gateway.refreshTokens, <String>['refresh-a']);
    expect(push.releaseCalls, 1);
    expect(push.abandonCalls, 0);
    expect(find.byKey(const Key('auth-email')), findsOneWidget);
    expect(await vault.read(), isNull);
    expect(await vault.readAccount(origin: origin, userId: 'user-a'), isNull);
  });

  testWidgets('SESSION_EXPIRED preserves auth ownership when endpoint delete and revoke are unconfirmed', (
    tester,
  ) async {
    final origin = Uri.parse('http://127.0.0.1:18473');
    final storage = _MemorySecureStore();
    final vault = AuthSessionVault(storage: storage);
    await vault.save(origin: origin, refreshToken: 'refresh-a');
    await vault.saveAccount(
      origin: origin,
      userId: 'user-a',
      refreshToken: 'refresh-a',
    );
    final gateway = _SwitchAuthGateway()
      ..refreshHandler = (refreshToken) async {
        throw const AuthApiException(
          statusCode: 401,
          code: 'SESSION_EXPIRED',
          message: 'Session is no longer valid',
        );
      }
      ..revokeDeviceError = const AuthApiException(
        statusCode: 401,
        code: 'UNAUTHORIZED',
        message: 'Valid access token is required',
      );
    final push = _FakePushAccountLeaseController()
      ..releaseError = StateError('endpoint delete unauthorized');

    await tester.pumpWidget(
      MaterialApp(
        home: AuthPage(
          gateway: gateway,
          vault: vault,
          initialSession: _sessionFor(
            userId: 'user-a',
            displayName: 'User A',
            deviceId: 'device-a',
            accessToken: 'access-a',
            refreshToken: 'refresh-a',
            accessExpiresAt: DateTime.now().toUtc().add(
              const Duration(seconds: 1),
            ),
          ),
          initialOrigin: origin,
          restoreSession: false,
          pushAccountLeaseController: push,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();

    expect(gateway.refreshTokens, <String>['refresh-a']);
    expect(push.releaseCalls, 1);
    expect(push.abandonCalls, 0);
    expect(find.byKey(const ValueKey('user-a-device-a')), findsOneWidget);
    expect(find.byKey(const Key('auth-email')), findsNothing);
    expect(find.textContaining('Push 清理尚未完成'), findsOneWidget);
    expect((await vault.read())?.refreshToken, 'refresh-a');
    expect(
      (await vault.readAccount(origin: origin, userId: 'user-a'))?.refreshToken,
      'refresh-a',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('SESSION_EXPIRED may finish after failed endpoint delete when revoke succeeds', (
    tester,
  ) async {
    final origin = Uri.parse('http://127.0.0.1:18473');
    final gateway = _SwitchAuthGateway()
      ..refreshHandler = (refreshToken) async => throw const AuthApiException(
        statusCode: 401,
        code: 'SESSION_EXPIRED',
        message: 'Session is no longer valid',
      );
    final push = _FakePushAccountLeaseController()
      ..releaseError = StateError('endpoint delete unauthorized');

    await tester.pumpWidget(
      MaterialApp(
        home: AuthPage(
          gateway: gateway,
          vault: AuthSessionVault(storage: _MemorySecureStore()),
          initialSession: _sessionFor(
            userId: 'user-a',
            displayName: 'User A',
            deviceId: 'device-a',
            accessToken: 'access-a',
            refreshToken: 'refresh-a',
            accessExpiresAt: DateTime.now().toUtc().add(
              const Duration(seconds: 1),
            ),
          ),
          initialOrigin: origin,
          restoreSession: false,
          pushAccountLeaseController: push,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();

    expect(gateway.refreshTokens, <String>['refresh-a']);
    expect(push.releaseCalls, 1);
    expect(gateway.revokedDeviceIds, <String>['device-a']);
    expect(push.abandonCalls, 1);
    expect(find.byKey(const Key('auth-email')), findsOneWidget);
  });

  testWidgets('explicit DEVICE_SESSION_REVOKED refresh may authoritatively abandon push lease', (
    tester,
  ) async {
    final origin = Uri.parse('http://127.0.0.1:18473');
    final gateway = _SwitchAuthGateway()
      ..refreshHandler = (refreshToken) async => throw const AuthApiException(
        statusCode: 401,
        code: 'DEVICE_SESSION_REVOKED',
        message: 'Device session has been revoked',
      );
    final push = _FakePushAccountLeaseController();

    await tester.pumpWidget(
      MaterialApp(
        home: AuthPage(
          gateway: gateway,
          vault: AuthSessionVault(storage: _MemorySecureStore()),
          initialSession: _sessionFor(
            userId: 'user-a',
            displayName: 'User A',
            deviceId: 'device-a',
            accessToken: 'access-a',
            refreshToken: 'refresh-a',
            accessExpiresAt: DateTime.now().toUtc().add(
              const Duration(seconds: 1),
            ),
          ),
          initialOrigin: origin,
          restoreSession: false,
          pushAccountLeaseController: push,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();

    expect(gateway.refreshTokens, <String>['refresh-a']);
    expect(push.abandonCalls, 1);
    expect(find.byKey(const Key('auth-email')), findsOneWidget);
  });

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

Future<void> _openAccountManagerAndSelect(
  WidgetTester tester,
  String userId,
) async {
  await tester.tap(find.byKey(const Key('shell-rail-me')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.byKey(const Key('shell-account-management')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.byKey(Key('account-manager-$userId')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

final class _PushStartCall {
  const _PushStartCall({
    required this.origin,
    required this.accessToken,
    required this.userId,
    required this.deviceId,
  });

  final Uri origin;
  final String accessToken;
  final String userId;
  final String deviceId;
}

final class _FakePushAccountLeaseController
    implements PushAccountLeaseController {
  int releaseCalls = 0;
  int abandonCalls = 0;
  Object? releaseError;
  Completer<void>? releaseCompleter;
  final List<_PushStartCall> starts = <_PushStartCall>[];

  @override
  Future<void> releaseCurrentEndpoint() async {
    releaseCalls++;
    final completer = releaseCompleter;
    if (completer != null) await completer.future;
    final error = releaseError;
    if (error != null) throw error;
  }

  @override
  Future<void> abandonCurrentEndpointLeaseAfterAuthoritativeRevocation() async {
    abandonCalls++;
  }

  @override
  Future<void> start({
    required Uri origin,
    required String accessToken,
    required String userId,
    required String deviceId,
  }) async {
    starts.add(
      _PushStartCall(
        origin: origin,
        accessToken: accessToken,
        userId: userId,
        deviceId: deviceId,
      ),
    );
  }
}

final class _SwitchAuthGateway extends _FakeAuthGateway {
  Future<AuthSession> Function(String refreshToken)? refreshHandler;
  final List<String> refreshTokens = <String>[];
  final List<String> revokedDeviceIds = <String>[];
  Object? revokeDeviceError;

  @override
  Future<AuthSession> refresh({
    required Uri origin,
    required String refreshToken,
  }) async {
    refreshTokens.add(refreshToken);
    final handler = refreshHandler;
    if (handler == null) {
      return super.refresh(origin: origin, refreshToken: refreshToken);
    }
    return handler(refreshToken);
  }

  @override
  Future<void> revokeDevice({
    required Uri origin,
    required String accessToken,
    required String deviceId,
  }) async {
    revokedDeviceIds.add(deviceId);
    final error = revokeDeviceError;
    if (error != null) throw error;
  }
}

final class _MemorySecureStore implements SecureKeyValueStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _FakeAuthGateway implements AuthGateway {
  int registerCount = 0;
  int sendRegistrationCodeCount = 0;
  Object? sendRegistrationCodeError;

  @override
  Future<void> sendRegistrationCode({
    required Uri origin,
    required String email,
  }) async {
    sendRegistrationCodeCount++;
    final error = sendRegistrationCodeError;
    if (error != null) throw error;
  }

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
    required String handle,
    required String displayName,
    required String bio,
    required AccountPrivacy privacy,
  }) async => AccountMe(
    profile: AccountProfile(
      id: 'u1',
      email: 'alice@example.com',
      handle: handle,
      displayName: displayName,
      bio: bio,
    ),
    privacy: privacy,
  );

  @override
  Future<void> sendEmailChangeCode({
    required Uri origin,
    required String accessToken,
    required String email,
  }) async {}

  @override
  Future<AccountMe> changeEmail({
    required Uri origin,
    required String accessToken,
    required String email,
    required String code,
  }) async => AccountMe(
    profile: AccountProfile(
      id: 'u1',
      email: email,
      handle: 'alice',
      displayName: 'Alice',
      bio: '',
    ),
    privacy: const AccountPrivacy(
      allowEmailSearch: false,
      allowStrangerMessages: false,
      showOnlineStatus: true,
      readReceiptsEnabled: true,
      notificationPreviewEnabled: true,
    ),
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
  Future<int> clearRevokedDevices({
    required Uri origin,
    required String accessToken,
  }) async => 0;

  @override
  Future<void> logoutAll({
    required Uri origin,
    required String accessToken,
  }) async {}

  @override
  void close() {}
}

final class _MemoryLoginHistory implements LoginHistoryRepository {
  _MemoryLoginHistory(List<LoginHistoryEntry> initial)
    : entries = List<LoginHistoryEntry>.from(initial);

  List<LoginHistoryEntry> entries;

  @override
  Future<List<LoginHistoryEntry>> list() async => List.unmodifiable(entries);

  @override
  Future<void> upsert(LoginHistoryEntry entry) async {
    entries = [entry, ...entries.where((item) => item.userId != entry.userId)];
  }

  @override
  Future<void> remove(LoginHistoryEntry entry) async {
    entries = entries.where((item) => item.userId != entry.userId).toList();
  }
}

AuthSession _sessionFor({
  required String userId,
  required String displayName,
  required String deviceId,
  required String accessToken,
  required String refreshToken,
  DateTime? accessExpiresAt,
}) => AuthSession(
  user: AuthUser(
    id: userId,
    email: '$userId@example.com',
    handle: userId,
    displayName: displayName,
  ),
  device: AuthDevice(
    id: deviceId,
    name: 'DD Windows',
    platform: 'WINDOWS',
    appVersion: '0.5.0-dev',
  ),
  tokens: AuthTokens(
    accessToken: accessToken,
    accessExpiresAt:
        accessExpiresAt ?? DateTime.now().toUtc().add(const Duration(hours: 1)),
    refreshToken: refreshToken,
    refreshExpiresAt: DateTime.now().toUtc().add(const Duration(days: 30)),
  ),
);

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
