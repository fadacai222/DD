import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/security/dd_secure_storage.dart';
import 'package:im_client/features/auth/data/auth_api_client.dart';
import 'package:im_client/features/auth/data/auth_session_vault.dart';
import 'package:im_client/features/auth/domain/auth_session.dart';
import 'package:im_client/features/auth/presentation/auth_boot_page.dart';
import 'package:im_client/theme/app_theme.dart';

void main() {
  testWidgets(
    'valid stored session never builds login while refresh is pending',
    (tester) async {
      final storage = _MemorySecureStore();
      final vault = AuthSessionVault(storage: storage);
      await vault.save(
        origin: Uri.parse('http://127.0.0.1:18473'),
        refreshToken: 'stored-refresh',
      );
      final refresh = Completer<AuthSession>();
      final gateway = _BootGateway(onRefresh: () => refresh.future);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: AuthBootPage(
            gateway: gateway,
            vault: vault,
            authenticatedBuilder: (_, session, origin) =>
                const SizedBox(key: Key('boot-authenticated-shell')),
            unauthenticatedBuilder: (_, origin) =>
                const SizedBox(key: Key('boot-login-page')),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('auth-boot-screen')), findsOneWidget);
      expect(find.byKey(const Key('boot-login-page')), findsNothing);
      expect(find.byKey(const Key('boot-authenticated-shell')), findsNothing);

      refresh.complete(_session(refreshToken: 'rotated-refresh'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('auth-boot-screen')), findsNothing);
      expect(find.byKey(const Key('boot-login-page')), findsNothing);
      expect(find.byKey(const Key('boot-authenticated-shell')), findsOneWidget);
      expect((await vault.read())?.refreshToken, 'rotated-refresh');
    },
  );

  testWidgets('empty vault goes to login only after boot decision', (
    tester,
  ) async {
    final vault = AuthSessionVault(storage: _MemorySecureStore());
    final gateway = _BootGateway(
      onRefresh: () async => throw StateError('refresh must not be called'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: AuthBootPage(
          gateway: gateway,
          vault: vault,
          authenticatedBuilder: (_, session, origin) =>
              const SizedBox(key: Key('boot-authenticated-shell')),
          unauthenticatedBuilder: (_, origin) =>
              const SizedBox(key: Key('boot-login-page')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('boot-login-page')), findsOneWidget);
    expect(gateway.refreshCalls, 0);
  });

  testWidgets('401 clears stored session and enters login', (tester) async {
    final storage = _MemorySecureStore();
    final vault = AuthSessionVault(storage: storage);
    await vault.save(
      origin: Uri.parse('http://127.0.0.1:18473'),
      refreshToken: 'revoked-refresh',
    );
    final gateway = _BootGateway(
      onRefresh: () async => throw const AuthApiException(
        statusCode: 401,
        code: 'SESSION_EXPIRED',
        message: 'Session is no longer valid',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: AuthBootPage(
          gateway: gateway,
          vault: vault,
          authenticatedBuilder: (_, session, origin) =>
              const SizedBox(key: Key('boot-authenticated-shell')),
          unauthenticatedBuilder: (_, origin) =>
              const SizedBox(key: Key('boot-login-page')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('boot-login-page')), findsOneWidget);
    expect(await vault.read(), isNull);
  });

  testWidgets('transient refresh error keeps boot screen and stored session', (
    tester,
  ) async {
    final storage = _MemorySecureStore();
    final vault = AuthSessionVault(storage: storage);
    await vault.save(
      origin: Uri.parse('http://127.0.0.1:18473'),
      refreshToken: 'keep-refresh',
    );
    final gateway = _BootGateway(
      onRefresh: () async => throw const AuthApiException(
        statusCode: 503,
        code: 'AUTH_SERVICE_UNAVAILABLE',
        message: 'Authentication service unavailable',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: AuthBootPage(
          gateway: gateway,
          vault: vault,
          authenticatedBuilder: (_, session, origin) =>
              const SizedBox(key: Key('boot-authenticated-shell')),
          unauthenticatedBuilder: (_, origin) =>
              const SizedBox(key: Key('boot-login-page')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('auth-boot-screen')), findsOneWidget);
    expect(find.byKey(const Key('auth-boot-retry')), findsOneWidget);
    expect(find.byKey(const Key('boot-login-page')), findsNothing);
    expect((await vault.read())?.refreshToken, 'keep-refresh');
  });
}

AuthSession _session({required String refreshToken}) {
  final now = DateTime.now().toUtc();
  return AuthSession(
    user: const AuthUser(
      id: 'user-a',
      email: 'alice@example.com',
      handle: 'alice',
      displayName: 'Alice',
    ),
    device: const AuthDevice(
      id: 'device-a',
      name: 'DD Windows',
      platform: 'WINDOWS',
      appVersion: 'test',
    ),
    tokens: AuthTokens(
      accessToken: 'access-token',
      accessExpiresAt: now.add(const Duration(minutes: 10)),
      refreshToken: refreshToken,
      refreshExpiresAt: now.add(const Duration(days: 30)),
    ),
  );
}

final class _BootGateway implements AuthGateway {
  _BootGateway({required this.onRefresh});

  final Future<AuthSession> Function() onRefresh;
  int refreshCalls = 0;

  @override
  Future<AuthSession> refresh({
    required Uri origin,
    required String refreshToken,
  }) {
    refreshCalls++;
    return onRefresh();
  }

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _MemorySecureStore implements SecureKeyValueStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}
