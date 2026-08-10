import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/qrcode/domain/dd_qr_payload.dart';

void main() {
  test('parses instance-bound user qr', () {
    final payload = DdQrPayload.parse(
      'dd://qr/v1/user?instance=https%3A%2F%2Fchat.example.invalid&userId=018f0000-0000-7000-8000-000000000001',
    );
    expect(payload.kind, DdQrKind.user);
    expect(payload.instance, Uri.parse('https://chat.example.invalid'));
    expect(payload.userId, '018f0000-0000-7000-8000-000000000001');
    expect(payload.belongsTo(Uri.parse('https://chat.example.invalid/')), isTrue);
    expect(payload.belongsTo(Uri.parse('https://other.example.invalid')), isFalse);
  });

  test('parses group and login secret nonce', () {
    const nonce = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    final group = DdQrPayload.parse(
      'dd://qr/v1/group?instance=http%3A%2F%2F127.0.0.1%3A18473&nonce=$nonce',
    );
    final login = DdQrPayload.parse(
      'dd://qr/v1/login?instance=http%3A%2F%2F127.0.0.1%3A18473&nonce=$nonce',
    );
    expect(group.kind, DdQrKind.group);
    expect(group.nonce, nonce);
    expect(login.kind, DdQrKind.login);
    expect(login.nonce, nonce);
  });

  test('rejects foreign scheme, missing instance and malformed nonce', () {
    expect(
      () => DdQrPayload.parse('https://example.invalid/qr'),
      throwsFormatException,
    );
    expect(
      () => DdQrPayload.parse(
        'dd://qr/v1/user?userId=018f0000-0000-7000-8000-000000000001',
      ),
      throwsFormatException,
    );
    expect(
      () => DdQrPayload.parse(
        'dd://qr/v1/login?instance=https%3A%2F%2Fchat.example.invalid&nonce=short',
      ),
      throwsFormatException,
    );
  });
}
