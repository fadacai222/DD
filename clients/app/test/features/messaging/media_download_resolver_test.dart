import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/messaging/data/media_api_client.dart';
import 'package:im_client/features/messaging/data/media_download_grant_cache.dart';
import 'package:im_client/features/messaging/data/media_download_resolver.dart';
import 'package:im_client/features/messaging/data/messaging_api_client.dart';

void main() {
  test('refreshes an expired signed URL once after storage 403', () async {
    final grants = MediaDownloadGrantCache();
    var grantLoads = 0;
    var downloads = 0;

    final bytes = await downloadMediaWithGrantRefresh(
      mediaId: 'media-a',
      grants: grants,
      grantLoader: () async {
        grantLoads++;
        return MediaDownloadGrant(
          url: Uri.parse('https://example.test/media?grant=$grantLoads'),
          expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
        );
      },
      downloader: (url) async {
        downloads++;
        if (downloads == 1) {
          throw MessagingApiException(
            statusCode: 403,
            code: 'MEDIA_STORAGE_DOWNLOAD_FAILED',
            message: 'expired',
          );
        }
        return Uint8List.fromList(<int>[1, 2, 3]);
      },
    );

    expect(bytes, <int>[1, 2, 3]);
    expect(grantLoads, 2);
    expect(downloads, 2);
  });

  test('does not retry non-auth storage failures', () async {
    final grants = MediaDownloadGrantCache();
    var downloads = 0;

    await expectLater(
      downloadMediaWithGrantRefresh(
        mediaId: 'media-b',
        grants: grants,
        grantLoader: () async => MediaDownloadGrant(
          url: Uri.parse('https://example.test/media'),
          expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
        ),
        downloader: (url) async {
          downloads++;
          throw MessagingApiException(
            statusCode: 500,
            code: 'MEDIA_STORAGE_DOWNLOAD_FAILED',
            message: 'boom',
          );
        },
      ),
      throwsA(isA<MessagingApiException>()),
    );
    expect(downloads, 1);
  });
}
