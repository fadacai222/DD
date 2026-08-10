import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/messaging/data/voice_media_format.dart';

void main() {
  test('sniffs WAV before trusting declared MIME', () {
    final bytes = Uint8List.fromList(<int>[
      ...'RIFF'.codeUnits,
      0,
      0,
      0,
      0,
      ...'WAVE'.codeUnits,
    ]);
    final format = detectVoiceMediaFormat(bytes, declaredMimeType: 'audio/aac');
    expect(format.mimeType, 'audio/wav');
    expect(format.extension, 'wav');
  });

  test('sniffs AAC ADTS', () {
    final format = detectVoiceMediaFormat(
      Uint8List.fromList(<int>[0xFF, 0xF1, 0x50, 0x80]),
      declaredMimeType: 'application/octet-stream',
    );
    expect(format.mimeType, 'audio/aac');
    expect(format.extension, 'aac');
  });

  test('uses declared MIME for legacy payloads without a known signature', () {
    final format = detectVoiceMediaFormat(
      Uint8List.fromList(<int>[1, 2, 3, 4]),
      declaredMimeType: 'audio/m4a',
    );
    expect(format.mimeType, 'audio/mp4');
    expect(format.extension, 'm4a');
  });
}
