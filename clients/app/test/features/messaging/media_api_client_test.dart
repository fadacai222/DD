import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:im_client/features/messaging/data/media_api_client.dart';

void main() {
  test('uploadStream hashes, streams, reports progress and completes', () async {
    final chunks = <List<int>>[
      utf8.encode('hello '),
      utf8.encode('world'),
    ];
    final progress = <int>[];
    var createCalls = 0;
    var putCalls = 0;
    var completeCalls = 0;

    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/api/v1/media/uploads') {
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
              'requiredHeaders': {'Content-Type': 'application/octet-stream'},
            },
            'requestId': 'req-create',
          }),
          201,
        );
      }
      if (request.method == 'PUT' && request.url.host == 'storage.invalid') {
        putCalls++;
        expect(request.bodyBytes, utf8.encode('hello world'));
        return http.Response('', 200);
      }
      if (request.method == 'POST' && request.url.path.endsWith('/complete')) {
        completeCalls++;
        return http.Response(
          jsonEncode({
            'data': {
              'media': {
                'id': '00000000-0000-0000-0000-000000000222',
              },
            },
            'requestId': 'req-complete',
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    });

    final api = MediaApiClient(httpClient: client);
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
