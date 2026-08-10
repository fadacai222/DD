import 'package:http/http.dart' as http;

import 'media_api_client.dart';

final class ResumableDownloadResult {
  const ResumableDownloadResult({
    required this.path,
    required this.totalBytes,
    required this.resumedBytes,
  });

  final String path;
  final int totalBytes;
  final int resumedBytes;
}

final class ResumableMediaDownloader {
  ResumableMediaDownloader({http.Client Function()? clientFactory});

  Future<ResumableDownloadResult> download({
    required Future<Uri> Function() resolveUrl,
    required String destinationPath,
    int? expectedBytes,
    MediaDownloadCancellation? cancellation,
    void Function(int received, int? total)? onProgress,
    int maximumAttempts = 3,
  }) => throw UnsupportedError('当前平台不支持文件路径级断点续传。');
}
