import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../auth/data/auth_api_client.dart' show normalizeAuthOrigin;
import '../../auth/data/auth_http_client.dart';
import '../domain/sticker_models.dart';

abstract interface class StickerGateway {
  Future<List<CustomStickerItem>> listCustomStickers({
    required Uri origin,
    required String accessToken,
  });

  Future<CustomStickerItem> createCustomSticker({
    required Uri origin,
    required String accessToken,
    required String mediaId,
    required int width,
    required int height,
  });

  Future<void> deleteCustomStickers({
    required Uri origin,
    required String accessToken,
    required List<String> stickerIds,
  });

  Future<void> reorderCustomStickers({
    required Uri origin,
    required String accessToken,
    required List<String> stickerIds,
  });

  Future<List<StickerPackItemGroup>> listStickerPacks({
    required Uri origin,
    required String accessToken,
  });

  Future<StickerPackItemGroup> importTelegramPack({
    required Uri origin,
    required String accessToken,
    required String setName,
  });

  Future<void> removeStickerPack({
    required Uri origin,
    required String accessToken,
    required String packId,
  });

  void close();
}

final class StickerApiException implements Exception {
  const StickerApiException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.requestId,
  });

  final int statusCode;
  final String code;
  final String message;
  final String? requestId;

  @override
  String toString() => '$message${requestId == null ? '' : ' · $requestId'}';
}

final class StickerApiClient implements StickerGateway {
  StickerApiClient({http.Client? httpClient})
    : _client = httpClient ?? createAuthHttpClient();

  static const Duration _requestTimeout = Duration(seconds: 15);
  final http.Client _client;

  @override
  Future<List<CustomStickerItem>> listCustomStickers({
    required Uri origin,
    required String accessToken,
  }) async {
    final data = await _requestData(
      origin: origin,
      accessToken: accessToken,
      path: '/api/v1/stickers/custom',
      expectedStatuses: const {200},
    );
    return _decodeItems(data, CustomStickerItem.fromJson);
  }

  @override
  Future<CustomStickerItem> createCustomSticker({
    required Uri origin,
    required String accessToken,
    required String mediaId,
    required int width,
    required int height,
  }) async {
    final data = await _requestData(
      origin: origin,
      accessToken: accessToken,
      path: '/api/v1/stickers/custom',
      method: 'POST',
      body: {'mediaId': mediaId, 'width': width, 'height': height},
      expectedStatuses: const {201},
    );
    return CustomStickerItem.fromJson(data);
  }

  @override
  Future<void> deleteCustomStickers({
    required Uri origin,
    required String accessToken,
    required List<String> stickerIds,
  }) async {
    await _requestData(
      origin: origin,
      accessToken: accessToken,
      path: '/api/v1/stickers/custom',
      method: 'DELETE',
      body: {'stickerIds': stickerIds},
      expectedStatuses: const {200},
    );
  }

  @override
  Future<void> reorderCustomStickers({
    required Uri origin,
    required String accessToken,
    required List<String> stickerIds,
  }) async {
    await _requestData(
      origin: origin,
      accessToken: accessToken,
      path: '/api/v1/stickers/custom/order',
      method: 'PUT',
      body: {'stickerIds': stickerIds},
      expectedStatuses: const {200},
    );
  }

  @override
  Future<List<StickerPackItemGroup>> listStickerPacks({
    required Uri origin,
    required String accessToken,
  }) async {
    final data = await _requestData(
      origin: origin,
      accessToken: accessToken,
      path: '/api/v1/stickers/packs',
      expectedStatuses: const {200},
    );
    return _decodeItems(data, StickerPackItemGroup.fromJson);
  }

  @override
  Future<StickerPackItemGroup> importTelegramPack({
    required Uri origin,
    required String accessToken,
    required String setName,
  }) async {
    final data = await _requestData(
      origin: origin,
      accessToken: accessToken,
      path: '/api/v1/stickers/packs/telegram',
      method: 'POST',
      body: {'setName': setName},
      expectedStatuses: const {200},
    );
    return StickerPackItemGroup.fromJson(data);
  }

  @override
  Future<void> removeStickerPack({
    required Uri origin,
    required String accessToken,
    required String packId,
  }) async {
    await _requestData(
      origin: origin,
      accessToken: accessToken,
      path: '/api/v1/stickers/packs/${Uri.encodeComponent(packId)}',
      method: 'DELETE',
      expectedStatuses: const {200},
    );
  }

  Future<Map<String, dynamic>> _requestData({
    required Uri origin,
    required String accessToken,
    required String path,
    required Set<int> expectedStatuses,
    String method = 'GET',
    Map<String, dynamic>? body,
  }) async {
    final url = normalizeAuthOrigin(origin).resolve(path);
    final headers = <String, String>{
      'Accept': 'application/json',
      'Authorization': 'Bearer $accessToken',
      if (body != null) 'Content-Type': 'application/json',
    };
    late http.Response response;
    try {
      switch (method) {
        case 'POST':
          response = await _client
              .post(url, headers: headers, body: jsonEncode(body))
              .timeout(_requestTimeout);
        case 'PUT':
          response = await _client
              .put(url, headers: headers, body: jsonEncode(body))
              .timeout(_requestTimeout);
        case 'DELETE':
          final request = http.Request('DELETE', url)..headers.addAll(headers);
          if (body != null) request.body = jsonEncode(body);
          final streamed = await _client.send(request).timeout(_requestTimeout);
          response = await http.Response.fromStream(
            streamed,
          ).timeout(_requestTimeout);
        default:
          response = await _client
              .get(url, headers: headers)
              .timeout(_requestTimeout);
      }
    } on TimeoutException {
      throw const StickerApiException(
        statusCode: 0,
        code: 'STICKER_REQUEST_TIMEOUT',
        message: '表情服务请求超时。',
      );
    } on http.ClientException {
      throw const StickerApiException(
        statusCode: 0,
        code: 'STICKER_NETWORK_ERROR',
        message: '无法连接表情服务。',
      );
    }
    return _decodeData(response, expectedStatuses);
  }

  Map<String, dynamic> _decodeData(
    http.Response response,
    Set<int> expectedStatuses,
  ) {
    Map<String, dynamic>? body;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) body = decoded;
    } catch (_) {}
    if (!expectedStatuses.contains(response.statusCode)) {
      final error = body?['error'];
      if (error is Map) {
        throw StickerApiException(
          statusCode: response.statusCode,
          code: error['code']?.toString() ?? 'STICKER_REQUEST_FAILED',
          message: error['message']?.toString() ?? '表情服务请求失败。',
          requestId: error['requestId']?.toString(),
        );
      }
      throw StickerApiException(
        statusCode: response.statusCode,
        code: 'STICKER_REQUEST_FAILED',
        message: '表情服务请求失败（HTTP ${response.statusCode}）。',
      );
    }
    final data = body?['data'];
    if (data is! Map) throw const FormatException('表情服务响应格式错误。');
    return data.map((key, value) => MapEntry(key.toString(), value));
  }

  List<T> _decodeItems<T>(
    Map<String, dynamic> data,
    T Function(Map<String, dynamic>) decoder,
  ) {
    final rawItems = data['items'];
    if (rawItems is! List) throw const FormatException('表情列表格式错误。');
    return rawItems
        .whereType<Map>()
        .map(
          (item) => decoder(
            item.map((key, value) => MapEntry(key.toString(), value)),
          ),
        )
        .toList(growable: false);
  }

  @override
  void close() => _client.close();
}
