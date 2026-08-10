import 'dart:async';
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

final class MediaObjectInfo {
  const MediaObjectInfo({
    required this.id,
    required this.originalName,
    required this.mimeType,
    required this.sizeBytes,
    required this.purpose,
    required this.status,
  });

  factory MediaObjectInfo.fromJson(Map<String, dynamic> json) => MediaObjectInfo(
    id: json['id'] as String? ?? '',
    originalName: json['originalName'] as String? ?? '',
    mimeType: json['mimeType'] as String? ?? '',
    sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
    purpose: json['purpose'] as String? ?? '',
    status: json['status'] as String? ?? '',
  );

  final String id;
  final String originalName;
  final String mimeType;
  final int sizeBytes;
  final String purpose;
  final String status;

  bool get isVideo => purpose == 'MOMENT_VIDEO' || mimeType.startsWith('video/');
}

final class MediaUploadCancellation {
  bool _cancelled = false;
  final Set<void Function()> _abortListeners = <void Function()>{};

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in _abortListeners.toList(growable: false)) {
      listener();
    }
    _abortListeners.clear();
  }

  void _attach(void Function() listener) {
    if (_cancelled) {
      listener();
      return;
    }
    _abortListeners.add(listener);
  }

  void _detach(void Function() listener) => _abortListeners.remove(listener);
}

final class MediaUploadCancelled implements Exception {
  const MediaUploadCancelled();

  @override
  String toString() => '媒体上传已取消。';
}

final class MediaDownloadCancellation {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

final class MediaDownloadCancelled implements Exception {
  const MediaDownloadCancelled();

  @override
  String toString() => '媒体下载已取消。';
}

final class MediaApiClient {
  MediaApiClient({
    http.Client? httpClient,
    http.Client Function()? uploadClientFactory,
  }) : _client = httpClient ?? createAuthHttpClient(),
       _uploadClientFactory = uploadClientFactory ?? http.Client.new;

  static const _apiTimeout = Duration(seconds: 30);
  static const _uploadResponseTimeout = Duration(hours: 2);
  static const _maximumUploadAttempts = 2;

  final http.Client _client;
  final http.Client Function() _uploadClientFactory;

  Future<MediaUploadGrant> uploadChatImage({
    required Uri origin,
    required String accessToken,
    required Uint8List bytes,
    required String fileName,
    void Function(int sentBytes, int totalBytes)? onProgress,
    MediaUploadCancellation? cancellation,
  }) => uploadMedia(
    origin: origin,
    accessToken: accessToken,
    bytes: bytes,
    fileName: fileName,
    mimeType: 'image/jpeg',
    purpose: 'CHAT_IMAGE',
    onProgress: onProgress,
    cancellation: cancellation,
  );

  Future<MediaUploadGrant> uploadMedia({
    required Uri origin,
    required String accessToken,
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
    required String purpose,
    void Function(int sentBytes, int totalBytes)? onProgress,
    MediaUploadCancellation? cancellation,
  }) async {
    if (bytes.isEmpty) throw const FormatException('媒体文件为空。');
    return uploadStream(
      origin: origin,
      accessToken: accessToken,
      streamFactory: () => Stream<List<int>>.value(bytes),
      size: bytes.length,
      fileName: fileName,
      mimeType: mimeType,
      purpose: purpose,
      onProgress: onProgress,
      cancellation: cancellation,
    );
  }

  Future<MediaUploadGrant> uploadStream({
    required Uri origin,
    required String accessToken,
    required Stream<List<int>> Function() streamFactory,
    required int size,
    required String fileName,
    required String mimeType,
    required String purpose,
    void Function(int sentBytes, int totalBytes)? onProgress,
    MediaUploadCancellation? cancellation,
  }) async {
    if (size <= 0) throw const FormatException('媒体文件为空。');
    _throwIfCancelled(cancellation);

    final digest = await sha256.bind(streamFactory()).first;
    _throwIfCancelled(cancellation);
    Object? lastError;
    StackTrace? lastStackTrace;

    for (var attempt = 0; attempt < _maximumUploadAttempts; attempt++) {
      _throwIfCancelled(cancellation);
      try {
        final grant = await createUpload(
          origin: origin,
          accessToken: accessToken,
          fileName: fileName,
          size: size,
          mimeType: mimeType,
          sha256Hex: digest.toString(),
          purpose: purpose,
        ).timeout(_apiTimeout);
        await _putUpload(
          grant: grant,
          streamFactory: streamFactory,
          size: size,
          cancellation: cancellation,
          onProgress: onProgress,
        );
        await _completeWithRetry(
          origin: origin,
          accessToken: accessToken,
          uploadId: grant.uploadId,
          cancellation: cancellation,
        );
        onProgress?.call(size, size);
        return grant;
      } catch (error, stackTrace) {
        if (cancellation?.isCancelled == true || error is MediaUploadCancelled) {
          throw const MediaUploadCancelled();
        }
        lastError = error;
        lastStackTrace = stackTrace;
        if (attempt + 1 >= _maximumUploadAttempts || !_isRetryableUploadError(error)) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        onProgress?.call(0, size);
        await Future<void>.delayed(const Duration(milliseconds: 280));
      }
    }
    Error.throwWithStackTrace(lastError!, lastStackTrace!);
  }

  Future<void> _putUpload({
    required MediaUploadGrant grant,
    required Stream<List<int>> Function() streamFactory,
    required int size,
    required MediaUploadCancellation? cancellation,
    void Function(int sentBytes, int totalBytes)? onProgress,
  }) async {
    _throwIfCancelled(cancellation);
    final uploadClient = _uploadClientFactory();
    void abort() => uploadClient.close();
    cancellation?._attach(abort);
    final request = http.StreamedRequest('PUT', grant.uploadUrl)
      ..headers.addAll(grant.requiredHeaders)
      ..contentLength = size;
    final responseFuture = uploadClient
        .send(request)
        .timeout(_uploadResponseTimeout);
    responseFuture.ignore();
    try {
      var sentBytes = 0;
      await for (final chunk in streamFactory()) {
        _throwIfCancelled(cancellation);
        request.sink.add(chunk);
        sentBytes += chunk.length;
        onProgress?.call(sentBytes.clamp(0, size), size);
      }
      await request.sink.close();
      _throwIfCancelled(cancellation);
      final response = await responseFuture;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw MessagingApiException(
          statusCode: response.statusCode,
          code: 'MEDIA_STORAGE_UPLOAD_FAILED',
          message: '媒体上传失败（对象存储返回 ${response.statusCode}）。',
        );
      }
      await response.stream.drain<void>();
    } catch (error, stackTrace) {
      uploadClient.close();
      responseFuture.ignore();
      try {
        await request.sink.close();
      } catch (_) {}
      if (cancellation?.isCancelled == true) {
        throw const MediaUploadCancelled();
      }
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      cancellation?._detach(abort);
      uploadClient.close();
    }
  }

  Future<void> _completeWithRetry({
    required Uri origin,
    required String accessToken,
    required String uploadId,
    required MediaUploadCancellation? cancellation,
  }) async {
    Object? lastError;
    StackTrace? lastStackTrace;
    for (var attempt = 0; attempt < _maximumUploadAttempts; attempt++) {
      _throwIfCancelled(cancellation);
      try {
        await completeUpload(
          origin: origin,
          accessToken: accessToken,
          uploadId: uploadId,
        ).timeout(_apiTimeout);
        return;
      } catch (error, stackTrace) {
        if (cancellation?.isCancelled == true || error is MediaUploadCancelled) {
          throw const MediaUploadCancelled();
        }
        lastError = error;
        lastStackTrace = stackTrace;
        if (attempt + 1 >= _maximumUploadAttempts || !_isRetryableUploadError(error)) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        await Future<void>.delayed(const Duration(milliseconds: 220));
      }
    }
    Error.throwWithStackTrace(lastError!, lastStackTrace!);
  }

  bool _isRetryableUploadError(Object error) {
    if (error is TimeoutException || error is http.ClientException) return true;
    if (error is MessagingApiException) {
      return error.statusCode == 408 ||
          error.statusCode == 429 ||
          error.statusCode >= 500;
    }
    return false;
  }

  void _throwIfCancelled(MediaUploadCancellation? cancellation) {
    if (cancellation?.isCancelled == true) throw const MediaUploadCancelled();
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

  Future<Uint8List> downloadMedia({
    required Uri url,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    MediaDownloadCancellation? cancellation,
  }) async {
    if (cancellation?.isCancelled == true) throw const MediaDownloadCancelled();
    final request = http.Request('GET', url);
    final response = await _client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MessagingApiException(
        statusCode: response.statusCode,
        code: 'MEDIA_STORAGE_DOWNLOAD_FAILED',
        message: '媒体下载失败（对象存储返回 ${response.statusCode}）。',
      );
    }
    final total = response.contentLength;
    final builder = BytesBuilder(copy: false);
    var received = 0;
    await for (final chunk in response.stream) {
      if (cancellation?.isCancelled == true) {
        throw const MediaDownloadCancelled();
      }
      builder.add(chunk);
      received += chunk.length;
      onProgress?.call(received, total);
    }
    onProgress?.call(received, total ?? received);
    return builder.takeBytes();
  }

  Future<MediaObjectInfo> getMedia({
    required Uri origin,
    required String accessToken,
    required String mediaId,
  }) async {
    final response = await _client.get(
      normalizeAuthOrigin(origin).resolve('/api/v1/media/$mediaId'),
      headers: _authHeaders(accessToken),
    );
    return MediaObjectInfo.fromJson(_decodeData(response, const {200}));
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

  Map<String, dynamic> _decodeData(http.Response response, Set<int> expected) {
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
