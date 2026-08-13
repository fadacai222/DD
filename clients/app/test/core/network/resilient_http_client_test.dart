import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:im_client/core/network/resilient_http_client.dart';

void main() {
  test('retries one transient GET failure with an equivalent request', () async {
    final inner = _SequencedClient(<Object>[
      http.ClientException('Connection closed before full header was received'),
      http.Response('{"ok":true}', 200),
    ]);
    final client = ResilientHttpClient(
      inner,
      retryDelay: Duration.zero,
    );
    addTearDown(client.close);

    final response = await client.get(
      Uri.parse('https://api.85746.pro/api/v1/conversations?limit=100'),
      headers: const <String, String>{'Authorization': 'Bearer token'},
    );

    expect(response.statusCode, 200);
    expect(inner.requests, hasLength(2));
    expect(inner.requests[0].method, 'GET');
    expect(inner.requests[1].method, 'GET');
    expect(inner.requests[1].url, inner.requests[0].url);
    expect(inner.requests[1].headers['Authorization'], 'Bearer token');
  });

  test('does not automatically retry a POST after transport failure', () async {
    final inner = _SequencedClient(<Object>[
      http.ClientException('Connection closed before full header was received'),
      http.Response('{"unexpected":true}', 200),
    ]);
    final client = ResilientHttpClient(
      inner,
      retryDelay: Duration.zero,
    );
    addTearDown(client.close);

    await expectLater(
      client.post(
        Uri.parse('https://api.85746.pro/api/v1/auth/login'),
        body: '{}',
      ),
      throwsA(isA<http.ClientException>()),
    );
    expect(inner.requests, hasLength(1));
  });
}

final class _SequencedClient extends http.BaseClient {
  _SequencedClient(this._outcomes);

  final List<Object> _outcomes;
  final List<http.BaseRequest> requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    if (_outcomes.isEmpty) throw StateError('no fake response left');
    final outcome = _outcomes.removeAt(0);
    if (outcome is Exception) throw outcome;
    final response = outcome as http.Response;
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }
}
