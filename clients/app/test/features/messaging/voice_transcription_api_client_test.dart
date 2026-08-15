import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:im_client/features/messaging/data/messaging_api_client.dart';
import 'package:im_client/features/messaging/data/voice_transcription_api_client.dart';

void main() {
  test('manual request uses formal message transcription endpoint and parses 202', () async {
    late http.Request captured;
    final client = VoiceTranscriptionApiClient(
      httpClient: MockClient((request) async {
        captured = request;
        return _response(202, {
          'id': 't1',
          'messageId': 'm1',
          'status': 'PENDING',
          'retryable': false,
          'attempts': 0,
        });
      }),
    );

    final result = await client.request(
      origin: Uri.parse('https://api.example.test'),
      accessToken: 'token',
      messageId: 'm1',
    );
    expect(captured.method, 'POST');
    expect(captured.url.path, '/api/v1/messages/m1/transcription');
    expect(captured.headers['Authorization'], 'Bearer token');
    expect(result.status, VoiceTranscriptionStatus.pending);
  });

  test('completed status exposes transcript and model metadata', () async {
    final client = VoiceTranscriptionApiClient(
      httpClient: MockClient((request) async => _response(200, {
        'id': 't1',
        'messageId': 'm1',
        'status': 'COMPLETED',
        'transcript': '你好',
        'language': 'zh',
        'model': 'whisper-large-v3',
        'retryable': false,
        'attempts': 1,
      })),
    );
    final result = await client.get(
      origin: Uri.parse('https://api.example.test'),
      accessToken: 'token',
      messageId: 'm1',
    );
    expect(result.isTerminal, isTrue);
    expect(result.transcript, '你好');
    expect(result.model, 'whisper-large-v3');
  });

  test('provider unavailable remains a structured API error', () async {
    final client = VoiceTranscriptionApiClient(
      httpClient: MockClient((request) async => http.Response(
        jsonEncode({
          'error': {
            'code': 'VOICE_TRANSCRIPTION_UNAVAILABLE',
            'message': 'provider unavailable',
          },
        }),
        503,
        headers: {'content-type': 'application/json'},
      )),
    );
    expect(
      () => client.request(
        origin: Uri.parse('https://api.example.test'),
        accessToken: 'token',
        messageId: 'm1',
      ),
      throwsA(
        isA<MessagingApiException>().having(
          (error) => error.code,
          'code',
          'VOICE_TRANSCRIPTION_UNAVAILABLE',
        ),
      ),
    );
  });

  test('auto preference is persisted through the server preference API only', () async {
    late http.Request captured;
    final client = VoiceTranscriptionApiClient(
      httpClient: MockClient((request) async {
        captured = request;
        return _response(200, {
          'autoTranscribeEnabled': true,
          'providerAvailable': true,
        });
      }),
    );
    final preferences = await client.updatePreferences(
      origin: Uri.parse('https://api.example.test'),
      accessToken: 'token',
      autoTranscribeEnabled: true,
    );
    expect(captured.method, 'PATCH');
    expect(captured.url.path, '/api/v1/voice-transcription/preferences');
    expect(jsonDecode(captured.body), {
      'autoTranscribeEnabled': true,
    });
    expect(preferences.autoTranscribeEnabled, isTrue);
    expect(preferences.providerAvailable, isTrue);
  });
}

http.Response _response(int status, Map<String, Object?> data) => http.Response(
  jsonEncode({'data': data}),
  status,
  headers: {'content-type': 'application/json'},
);
