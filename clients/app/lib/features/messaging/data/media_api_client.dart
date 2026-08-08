import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../auth/data/auth_api_client.dart' show normalizeAuthOrigin;
import '../../auth/data/auth_http_client.dart';
import 'messaging_api_client.dart';

final class MediaUploadGrant {
  const MediaUploadGrant({
    required this.uploadId,
    required this.mediaId,
    required this.uploadUrl,
    required this.expiresAt,
    required this.requiredHeaders,
  });

  final String uploadId;
  final String mediaId;
  final Uri uploadUrl;
  final DateTime expiresAt;
  final Map<String, String> requiredHeaders;
}

final class MediaDownloadGrant {
  const MediaDownloadGrant({required this.url, required this.expiresAt});

  final Uri url;
  final DateTime expiresAt;
}

final class MediaApiClient {
  MediaApiClient({http.Client? httpClient})
    : _client = httpClient ?? createAuthHttpClient();

  final http.Client _client;

  Future<MediaUploadGrant> uploadChatImage({
    required Uri origin,
    required String accessToken,
    required Uint8List bytes,
    required String fileName,
  }) => uploadMedia(
    origin: origin,
    accessToken: accessToken,
    bytes: bytes,
    fileName: fileName,
    mimeType: 'image/jpeg',
    purpose: 'CHAT_IMAGE',
  );

  Future<MediaUploadGrant> uploadMedia({
    required Uri origin,
    required String accessToken,
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
    required String purpose,
  }) async {
    if (bytes.isEmpty) throw const FormatException('媒体文件为空。');
    final grant = await createUpload(
      origin: origin,
      accessToken: accessToken,
      fileName: fileName,
      size: bytes.length,
      mimeType: mimeType,
      sha256Hex: sha256.convert(bytes).toString(),
      purpose: purpose,
    );
    final response = await _client.put(
      grant.uploadUrl,
      headers: grant.requiredHeaders,
      body: bytes,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MessagingApiException(
        statusCode: response.statusCode,
        code: 'MEDIA_STORAGE_UPLOAD_FAILED',
        message: '媒体上传失败（对象存储返回 ${response.statusCode}）。',
      );
    }
    await completeUpload(
      origin: origin,
      accessToken: accessToken,
      uploadId: grant.uploadId,
    );
    return grant;
  }

  Future<MediaUploadGrant> createUpload({
    required Uri origin,
    required String accessToken,
    required String fileName,
    required int size,
    required String mimeType,
    required String sha256Hex,
    required String purpose,
  }) async {
    final response = await _client.post(
      normalizeAuthOrigin(origin).resolve('/api/v1/media/uploads'),
      headers: _jsonHeaders(accessToken),
      body: jsonEncode({
        'fileName': fileName,
        'size': size,
        'mimeType': mimeType,
        'sha256': sha256Hex,
        'purpose': purpose,
      }),
    );
    final data = _decodeData(response, const {201});
    final uploadId = data['uploadId'];
    final mediaId = data['mediaId'];
    final uploadUrl = data['uploadUrl'];
    final expiresAt = data['expiresAt'];
    final rawHeaders = data['requiredHeaders'];
    if (uploadId is! String ||
        mediaId is! String ||
        uploadUrl is! String ||
        expiresAt is! String ||
        rawHeaders is! Map) {
      throw const FormatException('媒体上传凭证格式错误。');
    }
    return MediaUploadGrant(
      uploadId: uploadId,
      mediaId: mediaId,
      uploadUrl: Uri.parse(uploadUrl),
      expiresAt: DateTime.parse(expiresAt).toUtc(),
      requiredHeaders: rawHeaders.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      ),
    );
  }

  Future<void> completeUpload({
    required Uri origin,
    required String accessToken,
    required String uploadId,
  }) async {
    final response = await _client.post(
      normalizeAuthOrigin(
        origin,
      ).resolve('/api/v1/media/uploads/$uploadId/complete'),
      headers: _authHeaders(accessToken),
    );
    _decodeData(response, const {200});
  }

  Future<MediaDownloadGrant> createDownloadUrl({
    required Uri origin,
    required String accessToken,
    required String mediaId,
  }) async {
    final response = await _client.post(
      normalizeAuthOrigin(
        origin,
      ).resolve('/api/v1/media/$mediaId/download-url'),
      headers: _authHeaders(accessToken),
    );
    final data = _decodeData(response, const {200});
    final rawUrl = data['downloadUrl'];
    final rawExpiresAt = data['expiresAt'];
    if (rawUrl is! String || rawExpiresAt is! String) {
      throw const FormatException('媒体下载凭证格式错误。');
    }
    return MediaDownloadGrant(
      url: Uri.parse(rawUrl),
      expiresAt: DateTime.parse(rawExpiresAt).toUtc(),
    );
  }

  Map<String, String> _authHeaders(String accessToken) => {
    'Authorization': 'Bearer $accessToken',
    'Accept': 'application/json',
  };

  Map<String, String> _jsonHeaders(String accessToken) => {
    ..._authHeaders(accessToken),
    'Content-Type': 'application/json; charset=utf-8',
  };

  Map<String, dynamic> _decodeData(
    http.Response response,
    Set<int> expected,
  ) {
    dynamic decoded;
    if (response.bodyBytes.isNotEmpty) {
      try {
        decoded = jsonDecode(utf8.decode(response.bodyBytes));
      } catch (_) {
        decoded = null;
      }
    }
    if (!expected.contains(response.statusCode)) {
      final error = decoded is Map ? decoded['error'] : null;
      throw MessagingApiException(
        statusCode: response.statusCode,
        code: error is Map && error['code'] is String
            ? error['code'] as String
            : 'MEDIA_REQUEST_FAILED',
        message: error is Map && error['message'] is String
            ? error['message'] as String
            : '媒体请求失败（HTTP ${response.statusCode}）。',
        requestId: error is Map && error['requestId'] is String
            ? error['requestId'] as String
            : null,
      );
    }
    final data = decoded is Map ? decoded['data'] : null;
    if (data is! Map<String, dynamic>) {
      throw const FormatException('媒体 API 返回格式错误。');
    }
    return data;
  }

  void close() => _client.close();
}
