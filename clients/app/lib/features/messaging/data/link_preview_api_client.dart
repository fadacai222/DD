import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../auth/data/auth_http_client.dart';
import 'messaging_api_client.dart';

final class LinkPreviewData {
  const LinkPreviewData({
    required this.url,
    required this.siteName,
    required this.title,
    required this.description,
  });

  factory LinkPreviewData.fromJson(Map<String, dynamic> json) {
    final uri = Uri.tryParse(json['url'] as String? ?? '');
    final scheme = uri?.scheme.toLowerCase();
    if (uri == null ||
        uri.host.isEmpty ||
        (scheme != 'http' && scheme != 'https')) {
      throw const FormatException('链接预览地址无效。');
    }
    return LinkPreviewData(
      url: uri,
      siteName: (json['siteName'] as String? ?? '').trim(),
      title: (json['title'] as String? ?? '').trim(),
      description: (json['description'] as String? ?? '').trim(),
    );
  }

  final Uri url;
  final String siteName;
  final String title;
  final String description;
}

final class LinkPreviewApiClient {
  LinkPreviewApiClient({http.Client? httpClient})
    : _client = httpClient ?? createAuthHttpClient();

  final http.Client _client;

  Future<LinkPreviewData> getPreview({
    required Uri origin,
    required String accessToken,
    required Uri url,
  }) async {
    final endpoint = origin.resolve('/api/v1/link-preview').replace(
      queryParameters: <String, String>{'url': url.toString()},
    );
    final response = await _client.get(
      endpoint,
      headers: <String, String>{
        'Accept': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
    ).timeout(const Duration(seconds: 7));
    final Object? decoded = response.bodyBytes.isEmpty
        ? null
        : jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      final root = decoded is Map ? decoded : const <Object?, Object?>{};
      final error = root['error'];
      final requestId = root['requestId'];
      throw MessagingApiException(
        statusCode: response.statusCode,
        code: error is Map ? error['code']?.toString() ?? 'LINK_PREVIEW_FAILED' : 'LINK_PREVIEW_FAILED',
        message: error is Map ? error['message']?.toString() ?? '链接预览加载失败。' : '链接预览加载失败。',
        requestId: requestId?.toString(),
      );
    }
    if (decoded is! Map) throw const FormatException('链接预览响应格式错误。');
    final data = decoded['data'];
    if (data is! Map) throw const FormatException('链接预览数据缺失。');
    return LinkPreviewData.fromJson(Map<String, dynamic>.from(data));
  }

  void close() => _client.close();
}
