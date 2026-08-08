import 'dart:convert';

import 'package:http/http.dart' as http;

final class ApiEnvelope<T> {
  const ApiEnvelope({required this.data, required this.requestId});

  final T data;
  final String requestId;
}

final class InstanceFeatures {
  const InstanceFeatures({required this.calls, required this.registrationMode});

  final bool calls;
  final String registrationMode;
}

final class InstanceInfo {
  const InstanceInfo({
    required this.name,
    required this.apiVersion,
    required this.apiBaseUrl,
    required this.realtimeUrl,
    required this.liveKitUrl,
    required this.features,
  });

  factory InstanceInfo.fromJson(Map<String, dynamic> json) {
    final name = _requireString(json, 'name');
    final apiVersion = _requireString(json, 'apiVersion');
    final apiBaseUrl = _requireUri(json, 'apiBaseUrl', const {'http', 'https'});
    final realtimeUrl = _requireUri(json, 'realtimeUrl', const {'ws', 'wss'});
    final liveKitUrl = _requireUri(json, 'liveKitUrl', const {'ws', 'wss'});
    final featuresRaw = json['features'];
    if (featuresRaw is! Map<String, dynamic>) {
      throw const FormatException('features must be an object');
    }
    final calls = featuresRaw['calls'];
    if (calls is! bool) {
      throw const FormatException('features.calls must be a boolean');
    }
    final registrationMode = featuresRaw['registrationMode'];
    if (registrationMode is! String ||
        !const {
          'open',
          'invite',
          'approval',
          'closed',
        }.contains(registrationMode)) {
      throw const FormatException('features.registrationMode is invalid');
    }
    return InstanceInfo(
      name: name,
      apiVersion: apiVersion,
      apiBaseUrl: apiBaseUrl,
      realtimeUrl: realtimeUrl,
      liveKitUrl: liveKitUrl,
      features: InstanceFeatures(
        calls: calls,
        registrationMode: registrationMode,
      ),
    );
  }

  final String name;
  final String apiVersion;
  final Uri apiBaseUrl;
  final Uri realtimeUrl;
  final Uri liveKitUrl;
  final InstanceFeatures features;
}

final class ApiException implements Exception {
  const ApiException({
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
  String toString() {
    final suffix = requestId == null ? '' : ' (requestId: $requestId)';
    return 'ApiException[$statusCode/$code]: $message$suffix';
  }
}

final class ApiClient {
  ApiClient({required Uri origin, http.Client? httpClient})
    : origin = _normalizeOrigin(origin),
      _httpClient = httpClient ?? http.Client();

  final Uri origin;
  final http.Client _httpClient;

  Future<ApiEnvelope<InstanceInfo>> getInstance() async {
    final response = await _httpClient.get(
      origin.resolve('/api/v1/instance'),
      headers: const {'Accept': 'application/json'},
    );
    final body = _decodeObject(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _decodeApiException(response, body);
    }

    final data = body['data'];
    if (data is! Map<String, dynamic>) {
      throw const FormatException('API response data must be an object');
    }
    final requestId = body['requestId'];
    if (requestId is! String || requestId.trim().isEmpty) {
      throw const FormatException('API response requestId is required');
    }
    return ApiEnvelope(data: InstanceInfo.fromJson(data), requestId: requestId);
  }

  void close() => _httpClient.close();

  static ApiException _decodeApiException(
    http.Response response,
    Map<String, dynamic> body,
  ) {
    final error = body['error'];
    String code = 'HTTP_ERROR';
    String message = 'HTTP ${response.statusCode}';
    String? requestId = response.headers['x-request-id'];
    if (error is Map<String, dynamic>) {
      final rawCode = error['code'];
      final rawMessage = error['message'];
      final rawRequestId = error['requestId'];
      if (rawCode is String && rawCode.isNotEmpty) code = rawCode;
      if (rawMessage is String && rawMessage.isNotEmpty) message = rawMessage;
      if (rawRequestId is String && rawRequestId.isNotEmpty) {
        requestId = rawRequestId;
      }
    }
    return ApiException(
      statusCode: response.statusCode,
      code: code,
      message: message,
      requestId: requestId,
    );
  }
}

Uri _normalizeOrigin(Uri uri) {
  if (!uri.isAbsolute ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw ArgumentError.value(uri, 'origin', 'must be an http/https origin');
  }
  return uri.replace(path: '', query: null, fragment: null);
}

Map<String, dynamic> _decodeObject(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('API response must be a JSON object');
  }
  return decoded;
}

String _requireString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value;
}

Uri _requireUri(
  Map<String, dynamic> json,
  String key,
  Set<String> allowedSchemes,
) {
  final value = _requireString(json, key);
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !uri.isAbsolute ||
      uri.host.isEmpty ||
      !allowedSchemes.contains(uri.scheme)) {
    throw FormatException('$key has an invalid URL');
  }
  return uri;
}
