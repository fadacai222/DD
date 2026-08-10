import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:im_client/features/messaging/data/sticker_api_client.dart';

void main() {
  test('lists custom stickers with bearer auth', () async {
    late http.Request captured;
    final client = StickerApiClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'data': {
              'items': [
                {
                  'id': '018f0000-0000-7000-8000-000000000501',
                  'mediaId': '018f0000-0000-7000-8000-000000000502',
                  'mimeType': 'image/webp',
                  'width': 512,
                  'height': 512,
                  'sizeBytes': 1234,
                  'sortOrder': 0,
                  'createdAt': '2026-08-10T07:30:00Z',
                },
              ],
            },
            'requestId': 'req-sticker-list',
          }),
          200,
        );
      }),
    );
    addTearDown(client.close);

    final items = await client.listCustomStickers(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
    );

    expect(captured.url.path, '/api/v1/stickers/custom');
    expect(captured.headers['authorization'], 'Bearer token');
    expect(items.single.asset.mediaId, '018f0000-0000-7000-8000-000000000502');
  });

  test('imports Telegram pack using normalized setName only', () async {
    late http.Request captured;
    final client = StickerApiClient(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'data': {
                'id': '018f0000-0000-7000-8000-000000000503',
                'setName': 'Animals_by_TestBot',
                'title': 'Animals',
                'supportedStickerCount': 1,
                'unsupportedStickerCount': 0,
                'sortOrder': 0,
                'items': [
                  {
                    'id': '018f0000-0000-7000-8000-000000000504',
                    'mediaId': '018f0000-0000-7000-8000-000000000505',
                    'emoji': '🐱',
                    'mimeType': 'image/webp',
                    'width': 512,
                    'height': 512,
                    'sizeBytes': 2048,
                    'sortOrder': 0,
                  },
                ],
                'updatedAt': '2026-08-10T07:30:00Z',
              },
              'requestId': 'req-pack',
            }),
          ),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(client.close);

    final pack = await client.importTelegramPack(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
      setName: 'Animals_by_TestBot',
    );

    expect(captured.url.path, '/api/v1/stickers/packs/telegram');
    expect(jsonDecode(captured.body), {'setName': 'Animals_by_TestBot'});
    expect(
      pack.items.single.asset.mediaId,
      '018f0000-0000-7000-8000-000000000505',
    );
  });

  test('relay-not-configured keeps stable machine code', () async {
    final client = StickerApiClient(
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': {
              'code': 'TELEGRAM_STICKER_RELAY_NOT_CONFIGURED',
              'message':
                  'Telegram sticker relay is not configured on this DD instance',
              'requestId': 'req-no-relay',
            },
          }),
          503,
        ),
      ),
    );
    addTearDown(client.close);

    await expectLater(
      client.importTelegramPack(
        origin: Uri.parse('http://127.0.0.1:18473'),
        accessToken: 'token',
        setName: 'Animals_by_TestBot',
      ),
      throwsA(
        isA<StickerApiException>().having(
          (error) => error.code,
          'code',
          'TELEGRAM_STICKER_RELAY_NOT_CONFIGURED',
        ),
      ),
    );
  });
}
