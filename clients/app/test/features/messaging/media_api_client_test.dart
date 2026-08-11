import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:im_client/features/messaging/data/media_api_client.dart';

void main() {
  test('uploadStream hashes, streams, reports progress and completes', () async {
    final chunks = <List<int>>[utf8.encode('hello '), utf8.encode('world')];
    final progress = <int>[];
    var createCalls = 0;
    var putCalls = 0;
    var completeCalls = 0;

    final client = MockClient((request) async {
      if (request.method == 'POST' &&
          request.url.path == '/api/v1/media/uploads') {
        createCalls++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['size'], 11);
        expect(body['purpose'], 'CHAT_FILE');
        expect(
          body['sha256'],
          'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9',
        );
        return http.Response(
          jsonEncode({
            'data': {
              'uploadId': '00000000-0000-0000-0000-000000000111',
              'mediaId': '00000000-0000-0000-0000-000000000222',
              'uploadUrl': 'https://storage.invalid/object',
              'expiresAt': '2026-08-08T12:00:00Z',
              'requiredHeaders': {
                'Content-Type': 'application/octet-stream',
                'x-amz-meta-dd-sha256':
                    'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9',
              },
            },
            'requestId': 'req-create',
          }),
          201,
        );
      }
      if (request.method == 'POST' && request.url.path.endsWith('/complete')) {
        completeCalls++;
        return http.Response(
          jsonEncode({
            'data': {
              'media': {'id': '00000000-0000-0000-0000-000000000222'},
            },
            'requestId': 'req-complete',
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    });
    final storageClient = MockClient((request) async {
      expect(request.method, 'PUT');
      expect(request.url.host, 'storage.invalid');
      putCalls++;
      expect(
        request.headers['x-amz-meta-dd-sha256'],
        'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9',
      );
      expect(request.bodyBytes, utf8.encode('hello world'));
      return http.Response('', 200);
    });

    final api = MediaApiClient(
      httpClient: client,
      uploadClientFactory: () => storageClient,
    );
    final result = await api.uploadStream(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
      streamFactory: () => Stream<List<int>>.fromIterable(chunks),
      size: 11,
      fileName: 'hello.bin',
      mimeType: 'application/octet-stream',
      purpose: 'CHAT_FILE',
      onProgress: (sent, _) => progress.add(sent),
    );

    expect(result.mediaId, '00000000-0000-0000-0000-000000000222');
    expect(createCalls, 1);
    expect(putCalls, 1);
    expect(completeCalls, 1);
    expect(progress, containsAllInOrder(<int>[6, 11]));
    api.close();
  });

  test('uploadStream retries storage failure with a fresh reservation', () async {
    var createCalls = 0;
    var completeCalls = 0;
    var cancelCalls = 0;
    var storageCalls = 0;
    final apiClient = MockClient((request) async {
      if (request.url.path == '/api/v1/media/uploads') {
        createCalls++;
        return http.Response(
          jsonEncode({
            'data': {
              'uploadId': '00000000-0000-0000-0000-${createCalls.toString().padLeft(12, '0')}',
              'mediaId': '10000000-0000-0000-0000-${createCalls.toString().padLeft(12, '0')}',
              'uploadUrl': 'https://storage.invalid/object-$createCalls',
              'expiresAt': '2026-08-08T12:00:00Z',
              'requiredHeaders': {'Content-Type': 'application/octet-stream'},
            },
            'requestId': 'req-create-$createCalls',
          }),
          201,
        );
      }
      if (request.method == 'DELETE' &&
          request.url.path.startsWith('/api/v1/media/uploads/')) {
        cancelCalls++;
        return http.Response('', 204);
      }
      if (request.url.path.endsWith('/complete')) {
        completeCalls++;
        return http.Response(
          jsonEncode({
            'data': {
              'media': {'id': '10000000-0000-0000-0000-000000000002'},
            },
            'requestId': 'req-complete',
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    });
    final api = MediaApiClient(
      httpClient: apiClient,
      uploadClientFactory: () => MockClient((request) async {
        storageCalls++;
        return http.Response('', storageCalls == 1 ? 503 : 200);
      }),
    );

    final result = await api.uploadStream(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
      streamFactory: () => Stream<List<int>>.value(<int>[1, 2, 3]),
      size: 3,
      fileName: 'retry.bin',
      mimeType: 'application/octet-stream',
      purpose: 'CHAT_FILE',
    );

    expect(createCalls, 2);
    expect(storageCalls, 2);
    expect(cancelCalls, 1);
    expect(completeCalls, 1);
    expect(result.uploadUrl.path, '/object-2');
    api.close();
  });

  test('upload cancellation closes transport and releases reservation', () async {
    var completeCalls = 0;
    var cancelCalls = 0;
    final apiClient = MockClient((request) async {
      if (request.url.path == '/api/v1/media/uploads') {
        return http.Response(
          jsonEncode({
            'data': {
              'uploadId': '00000000-0000-0000-0000-000000000333',
              'mediaId': '00000000-0000-0000-0000-000000000444',
              'uploadUrl': 'https://storage.invalid/cancel',
              'expiresAt': '2026-08-08T12:00:00Z',
              'requiredHeaders': {'Content-Type': 'application/octet-stream'},
            },
            'requestId': 'req-cancel-create',
          }),
          201,
        );
      }
      if (request.method == 'DELETE' &&
          request.url.path.startsWith('/api/v1/media/uploads/')) {
        cancelCalls++;
        return http.Response('', 204);
      }
      if (request.url.path.endsWith('/complete')) {
        completeCalls++;
        return http.Response('{}', 500);
      }
      return http.Response('not found', 404);
    });
    final transport = _AbortAwareClient();
    final cancellation = MediaUploadCancellation();
    final api = MediaApiClient(
      httpClient: apiClient,
      uploadClientFactory: () => transport,
    );

    await expectLater(
      api.uploadStream(
        origin: Uri.parse('http://127.0.0.1:18473'),
        accessToken: 'token',
        streamFactory: () => Stream<List<int>>.fromIterable(const [
          <int>[1, 2],
          <int>[3, 4],
        ]),
        size: 4,
        fileName: 'cancel-active.bin',
        mimeType: 'application/octet-stream',
        purpose: 'CHAT_FILE',
        cancellation: cancellation,
        onProgress: (sent, _) {
          if (sent >= 2) cancellation.cancel();
        },
      ),
      throwsA(isA<MediaUploadCancelled>()),
    );
    expect(transport.closed, isTrue);
    expect(completeCalls, 0);
    expect(cancelCalls, 1);
    api.close();
  });

  test('downloadMedia streams bytes and reports progress', () async {
    final client = MediaApiClient(
      httpClient: MockClient.streaming((request, bodyStream) async {
        expect(request.method, 'GET');
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable(const [
            <int>[1, 2],
            <int>[3, 4, 5],
          ]),
          200,
          contentLength: 5,
        );
      }),
    );
    final progress = <int>[];
    final bytes = await client.downloadMedia(
      url: Uri.parse('https://storage.example.test/file'),
      onProgress: (received, total) {
        expect(total, 5);
        progress.add(received);
      },
    );
    expect(bytes, Uint8List.fromList(const [1, 2, 3, 4, 5]));
    expect(progress, containsAllInOrder(const [2, 5]));
    client.close();
  });

  test('downloadMedia active cancellation cancels storage stream', () async {
    var streamCancelled = false;
    final listened = Completer<void>();
    late final StreamController<List<int>> stream;
    stream = StreamController<List<int>>(
      onListen: () => listened.complete(),
      onCancel: () => streamCancelled = true,
    );
    final cancellation = MediaDownloadCancellation();
    final client = MediaApiClient(
      httpClient: MockClient.streaming((request, bodyStream) async {
        return http.StreamedResponse(stream.stream, 200, contentLength: 10);
      }),
    );

    final download = client.downloadMedia(
      url: Uri.parse('https://storage.example.test/file'),
      cancellation: cancellation,
    );
    await listened.future;
    stream.add(const <int>[1, 2, 3]);
    cancellation.cancel();

    await expectLater(download, throwsA(isA<MediaDownloadCancelled>()));
    expect(streamCancelled, isTrue);
    await stream.close();
    client.close();
  });

  test('downloadMedia honors cancellation before request', () async {
    final cancellation = MediaDownloadCancellation()..cancel();
    final client = MediaApiClient(
      httpClient: MockClient((_) async => http.Response('', 200)),
    );
    await expectLater(
      client.downloadMedia(
        url: Uri.parse('https://storage.example.test/file'),
        cancellation: cancellation,
      ),
      throwsA(isA<MediaDownloadCancelled>()),
    );
    client.close();
  });

  test('uploadStream cancellation stops before upload reservation', () async {
    final cancellation = MediaUploadCancellation()..cancel();
    final client = MockClient((_) async => http.Response('unexpected', 500));
    final api = MediaApiClient(httpClient: client);

    await expectLater(
      api.uploadStream(
        origin: Uri.parse('http://127.0.0.1:18473'),
        accessToken: 'token',
        streamFactory: () => Stream<List<int>>.value(<int>[1, 2, 3]),
        size: 3,
        fileName: 'cancel.bin',
        mimeType: 'application/octet-stream',
        purpose: 'CHAT_FILE',
        cancellation: cancellation,
      ),
      throwsA(isA<MediaUploadCancelled>()),
    );
    api.close();
  });
}

final class _AbortAwareClient extends http.BaseClient {
  final Completer<http.StreamedResponse> _response =
      Completer<http.StreamedResponse>();
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.finalize().listen(
      (_) {},
      onDone: () {
        if (!closed && !_response.isCompleted) {
          _response.complete(http.StreamedResponse(const Stream.empty(), 200));
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!_response.isCompleted) {
          _response.completeError(error, stackTrace);
        }
      },
      cancelOnError: true,
    );
    return _response.future;
  }

  @override
  void close() {
    closed = true;
    if (!_response.isCompleted) {
      _response.completeError(
        http.ClientException('storage upload aborted by cancellation'),
      );
    }
  }
}
