import 'dart:typed_data';

import 'media_api_client.dart';
import 'media_download_grant_cache.dart';
import 'messaging_api_client.dart';

Future<Uint8List> downloadMediaWithGrantRefresh({
  required String mediaId,
  required MediaDownloadGrantCache grants,
  required Future<MediaDownloadGrant> Function() grantLoader,
  required Future<Uint8List> Function(Uri url) downloader,
}) async {
  var refreshed = false;
  while (true) {
    final grant = await grants.resolve(mediaId, loader: grantLoader);
    try {
      return await downloader(grant.url);
    } on MessagingApiException catch (error) {
      if (refreshed || !_isRefreshableGrantFailure(error.statusCode)) rethrow;
      refreshed = true;
      grants.clear(mediaId);
    }
  }
}

bool _isRefreshableGrantFailure(int statusCode) =>
    statusCode == 401 || statusCode == 403 || statusCode == 410;
