import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/auth/data/auth_api_client.dart';
import 'package:im_client/features/auth/domain/auth_session.dart';
import 'package:im_client/features/groups/domain/group_models.dart';
import 'package:im_client/features/qrcode/data/qr_api_client.dart';
import 'package:im_client/features/qrcode/presentation/qr_login_page.dart';

void main() {
  testWidgets('desktop QR login renders challenge and returns consumed session', (
    tester,
  ) async {
    final gateway = _LoginQrGateway();
    AuthSession? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  result = await Navigator.of(context).push<AuthSession>(
                    MaterialPageRoute<AuthSession>(
                      builder: (_) => QrLoginPage(
                        origin: Uri.parse('https://chat.example.invalid'),
                        gateway: gateway,
                      ),
                    ),
                  );
                },
                child: const Text('打开扫码登录'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开扫码登录'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dd-qr-image')), findsOneWidget);
    expect(find.textContaining('打开手机 DD'), findsOneWidget);

    gateway.status = 'CONFIRMED';
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(gateway.consumeCalls, 1);
    expect(result?.user.displayName, 'Alice');
    expect(find.text('打开扫码登录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

final class _LoginQrGateway implements QrGateway {
  static const nonce = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
  String status = 'PENDING';
  int consumeCalls = 0;

  final AuthDeviceInput device = const AuthDeviceInput(
    name: 'DD Windows',
    platform: 'WINDOWS',
    appVersion: '1.0.0',
  );

  @override
  Future<QrLoginState> createLogin({
    required Uri origin,
    required AuthDeviceInput device,
  }) async => QrLoginState(
    status: 'PENDING',
    device: this.device,
    nonce: nonce,
    payload:
        'dd://qr/v1/login?instance=https%3A%2F%2Fchat.example.invalid&nonce=$nonce',
    expiresAt: DateTime.utc(2026, 8, 10, 12, 2),
  );

  @override
  Future<QrLoginState> loginStatus({
    required Uri origin,
    required String nonce,
  }) async => QrLoginState(
    status: status,
    device: device,
    expiresAt: DateTime.utc(2026, 8, 10, 12, 2),
    scannedAt: status == 'PENDING' ? null : DateTime.utc(2026, 8, 10, 12, 0, 5),
    confirmedAt: status == 'CONFIRMED'
        ? DateTime.utc(2026, 8, 10, 12, 0, 8)
        : null,
  );

  @override
  Future<AuthSession> consumeLogin({
    required Uri origin,
    required String nonce,
  }) async {
    consumeCalls++;
    return AuthSession.fromJson({
      'user': {
        'id': '018f0000-0000-7000-8000-000000000001',
        'email': 'alice@example.invalid',
        'handle': 'alice',
        'displayName': 'Alice',
      },
      'device': {
        'id': '018f0000-0000-7000-8000-000000000020',
        'name': 'DD Windows',
        'platform': 'WINDOWS',
        'appVersion': '1.0.0',
      },
      'tokens': {
        'accessToken': 'access',
        'accessExpiresAt': '2026-08-10T12:15:00Z',
        'refreshToken': 'refresh',
        'refreshExpiresAt': '2026-09-09T12:00:00Z',
      },
    });
  }

  @override
  Future<QrLoginState> scanLogin({
    required Uri origin,
    required String accessToken,
    required String nonce,
  }) => throw UnimplementedError();

  @override
  Future<QrLoginState> confirmLogin({
    required Uri origin,
    required String accessToken,
    required String nonce,
    required bool approved,
  }) => throw UnimplementedError();

  @override
  Future<GroupQrInviteData> createGroupInvite({
    required Uri origin,
    required String accessToken,
    required String groupId,
    int expiresInSeconds = 86400,
    int? maxUses,
  }) => throw UnimplementedError();

  @override
  Future<QrPayloadData> myQr({
    required Uri origin,
    required String accessToken,
  }) => throw UnimplementedError();

  @override
  Future<GroupInfo> redeemGroupInvite({
    required Uri origin,
    required String accessToken,
    required String nonce,
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
