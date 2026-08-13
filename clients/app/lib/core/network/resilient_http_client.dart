import 'dart:async';

import 'package:http/http.dart' as http;

/// Retries a single transport failure only for requests that are safe to replay.
///
/// Native mobile networks and reverse proxies can close an idle keep-alive
/// connection before the next response header arrives. Replaying a GET/HEAD/
/// OPTIONS request once is safe; mutating requests are deliberately never
/// retried here because the server may already have processed them.
final class ResilientHttpClient extends http.BaseClient {
  ResilientHttpClient(
    this._inner, {
    this.retryDelay = const Duration(milliseconds: 150),
  });

  final http.Client _inner;
  final Duration retryDelay;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final retry = _cloneSafeRequest(request);
    try {
      return await _inner.send(request);
    } on http.ClientException {
      if (retry == null) rethrow;
      if (retryDelay > Duration.zero) await Future<void>.delayed(retryDelay);
      return _inner.send(retry);
    }
  }

  http.Request? _cloneSafeRequest(http.BaseRequest request) {
    if (request is! http.Request || !_isSafeMethod(request.method)) return null;
    final clone = http.Request(request.method, request.url)
      ..followRedirects = request.followRedirects
      ..maxRedirects = request.maxRedirects
      ..persistentConnection = request.persistentConnection
      ..headers.addAll(request.headers)
      ..bodyBytes = request.bodyBytes;
    return clone;
  }

  bool _isSafeMethod(String method) {
    switch (method.toUpperCase()) {
      case 'GET':
      case 'HEAD':
      case 'OPTIONS':
        return true;
      default:
        return false;
    }
  }

  @override
  void close() => _inner.close();
}
