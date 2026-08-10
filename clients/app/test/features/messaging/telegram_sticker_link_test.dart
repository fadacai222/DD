import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/messaging/domain/telegram_sticker_link.dart';

void main() {
  test('parses official Telegram sticker links and deep links', () {
    expect(
      parseTelegramStickerSetName(
        'https://t.me/addstickers/tmeaddsticss_yang2_yang2_by_fStikBot',
      ),
      'tmeaddsticss_yang2_yang2_by_fStikBot',
    );
    expect(
      parseTelegramStickerSetName('https://telegram.me/addstickers/Animals_01'),
      'Animals_01',
    );
    expect(
      parseTelegramStickerSetName('tg://addstickers?set=Animals_01'),
      'Animals_01',
    );
    expect(parseTelegramStickerSetName('Animals_01'), 'Animals_01');
  });

  test('rejects arbitrary hosts paths and query injection', () {
    for (final value in <String>[
      'http://t.me/addstickers/Animals_01',
      'https://evil.example/addstickers/Animals_01',
      'https://t.me/Animals_01',
      'https://t.me/addstickers/Animals_01?next=http://127.0.0.1',
      'tg://resolve?domain=Animals_01',
      '../Animals_01',
      'bad name',
    ]) {
      expect(
        () => parseTelegramStickerSetName(value),
        throwsA(isA<FormatException>()),
        reason: value,
      );
    }
  });
}
