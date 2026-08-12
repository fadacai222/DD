import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/auth/data/auth_api_client.dart';
import 'package:im_client/features/auth/domain/auth_session.dart';
import 'package:im_client/features/groups/domain/group_models.dart';
import 'package:im_client/features/qrcode/data/qr_api_client.dart';
import 'package:im_client/features/qrcode/presentation/qr_scanner_page.dart';

void main() {
  testWidgets('Windows scanner uses explicit manual payload fallback', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final gateway = _FakeQrGateway();

    await tester.pumpWidget(
      MaterialApp(
        home: QrScannerPage(
          origin: Uri.parse('https://chat.example.invalid'),
          accessToken: 'token',
          onUnauthorized: () async => 'token',
          gateway: gateway,
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('dd-mobile-scanner')), findsNothing);
    expect(find.byKey(const Key('qr-scan-manual-input')), findsOneWidget);
    expect(find.text('当前桌面平台不启用摄像头扫码'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('qr-scan-manual-input')),
      'dd://qr/v1/user?instance=https%3A%2F%2Fchat.example.invalid&userId=018f0000-0000-7000-8000-000000000001',
    );
    await tester.tap(find.byKey(const Key('qr-scan-manual-submit')));
    await tester.pumpAndSettle();

    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('expired group QR shows an actionable expiry message', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final gateway = _FakeQrGateway(
      redeemError: const QrApiException(
        statusCode: 410,
        code: 'QR_EXPIRED',
        message: 'expired',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: QrScannerPage(
          origin: Uri.parse('https://chat.example.invalid'),
          accessToken: 'token',
          onUnauthorized: () async => 'token',
          gateway: gateway,
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('qr-scan-manual-input')),
      'dd://qr/v1/group?instance=https%3A%2F%2Fchat.example.invalid&nonce=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    );
    await tester.tap(find.byKey(const Key('qr-scan-manual-submit')));
    await tester.pump();

    expect(find.text('这个二维码已经过期，请重新生成。'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('revoked group QR maps QR_NOT_FOUND to invalid credential', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final gateway = _FakeQrGateway(
      redeemError: const QrApiException(
        statusCode: 404,
        code: 'QR_NOT_FOUND',
        message: 'not found',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: QrScannerPage(
          origin: Uri.parse('https://chat.example.invalid'),
          accessToken: 'token',
          onUnauthorized: () async => 'token',
          gateway: gateway,
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('qr-scan-manual-input')),
      'dd://qr/v1/group?instance=https%3A%2F%2Fchat.example.invalid&nonce=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    );
    await tester.tap(find.byKey(const Key('qr-scan-manual-submit')));
    await tester.pump();

    expect(find.text('二维码凭证不存在或已经失效。'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('login QR scans and confirms the presented device', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final gateway = _FakeQrGateway(supportLogin: true);

    await tester.pumpWidget(
      MaterialApp(
        home: QrScannerPage(
          origin: Uri.parse('https://chat.example.invalid'),
          accessToken: 'token',
          onUnauthorized: () async => 'token',
          gateway: gateway,
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('qr-scan-manual-input')),
      'dd://qr/v1/login?instance=https%3A%2F%2Fchat.example.invalid&nonce=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    );
    await tester.tap(find.byKey(const Key('qr-scan-manual-submit')));
    await tester.pumpAndSettle();

    expect(find.text('确认登录 DD？'), findsOneWidget);
    await tester.tap(find.text('确认登录'));
    await tester.pumpAndSettle();

    expect(gateway.scanCalls, 1);
    expect(gateway.confirmCalls, 1);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('foreign-instance payload is rejected before server action', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final gateway = _FakeQrGateway();

    await tester.pumpWidget(
      MaterialApp(
        home: QrScannerPage(
          origin: Uri.parse('https://chat.example.invalid'),
          accessToken: 'token',
          onUnauthorized: () async => 'token',
          gateway: gateway,
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('qr-scan-manual-input')),
      'dd://qr/v1/group?instance=https%3A%2F%2Fother.example.invalid&nonce=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    );
    await tester.tap(find.byKey(const Key('qr-scan-manual-submit')));
    await tester.pump();

    expect(find.textContaining('属于 other.example.invalid'), findsOneWidget);
    expect(gateway.redeemCalls, 0);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });
}

final class _FakeQrGateway implements QrGateway {
  _FakeQrGateway({this.redeemError, this.supportLogin = false});

  final QrApiException? redeemError;
  final bool supportLogin;
  int redeemCalls = 0;
  int scanCalls = 0;
  int confirmCalls = 0;

  @override
  Future<GroupInfo> redeemGroupInvite({
    required Uri origin,
    required String accessToken,
    required String nonce,
  }) async {
    redeemCalls++;
    final error = redeemError;
    if (error != null) throw error;
    throw UnimplementedError();
  }

  @override
  Future<QrLoginState> scanLogin({
    required Uri origin,
    required String accessToken,
    required String nonce,
  }) async {
    scanCalls++;
    if (!supportLogin) throw UnimplementedError();
    return QrLoginState(
      status: 'SCANNED',
      device: const AuthDeviceInput(
        name: 'DD Windows',
        platform: 'WINDOWS',
        appVersion: '1.0.0',
      ),
      expiresAt: DateTime.utc(2026, 8, 13),
    );
  }

  @override
  Future<QrLoginState> confirmLogin({
    required Uri origin,
    required String accessToken,
    required String nonce,
    required bool approved,
  }) async {
    confirmCalls++;
    if (!supportLogin) throw UnimplementedError();
    return QrLoginState(
      status: approved ? 'CONFIRMED' : 'REJECTED',
      device: const AuthDeviceInput(
        name: 'DD Windows',
        platform: 'WINDOWS',
        appVersion: '1.0.0',
      ),
      expiresAt: DateTime.utc(2026, 8, 13),
    );
  }

  @override
  Future<GroupQrInviteData> createGroupInvite({
    required Uri origin,
    required String accessToken,
    required String groupId,
    int expiresInSeconds = 86400,
    int? maxUses,
  }) => throw UnimplementedError();

  @override
  Future<QrLoginState> createLogin({
    required Uri origin,
    required AuthDeviceInput device,
  }) => throw UnimplementedError();

  @override
  Future<AuthSession> consumeLogin({
    required Uri origin,
    required String nonce,
  }) => throw UnimplementedError();

  @override
  Future<QrLoginState> loginStatus({
    required Uri origin,
    required String nonce,
  }) => throw UnimplementedError();

  @override
  Future<QrPayloadData> myQr({
    required Uri origin,
    required String accessToken,
  }) => throw UnimplementedError();

  @override
  Future<void> revokeGroupInvite({
    required Uri origin,
    required String accessToken,
    required String inviteId,
  }) => throw UnimplementedError();

  @override
  void close() {}
}
