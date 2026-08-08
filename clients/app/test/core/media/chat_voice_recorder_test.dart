import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/media/chat_voice_recorder.dart';

void main() {
  test('wrapPcm16AsWav writes a valid mono PCM WAV header', () {
    final pcm = Uint8List.fromList(<int>[0, 0, 255, 127, 0, 128, 0, 0]);
    final wav = wrapPcm16AsWav(pcm, sampleRate: 16000, channels: 1);
    final header = ByteData.sublistView(wav);

    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(String.fromCharCodes(wav.sublist(12, 16)), 'fmt ');
    expect(String.fromCharCodes(wav.sublist(36, 40)), 'data');
    expect(header.getUint16(20, Endian.little), 1);
    expect(header.getUint16(22, Endian.little), 1);
    expect(header.getUint32(24, Endian.little), 16000);
    expect(header.getUint16(34, Endian.little), 16);
    expect(header.getUint32(40, Endian.little), pcm.length);
    expect(wav.sublist(44), pcm);
  });

  test('wrapPcm16AsWav keeps stereo byte rate and block alignment coherent', () {
    final pcm = Uint8List(16);
    final wav = wrapPcm16AsWav(pcm, sampleRate: 48000, channels: 2);
    final header = ByteData.sublistView(wav);

    expect(header.getUint16(22, Endian.little), 2);
    expect(header.getUint32(24, Endian.little), 48000);
    expect(header.getUint32(28, Endian.little), 192000);
    expect(header.getUint16(32, Endian.little), 4);
    expect(header.getUint32(4, Endian.little), 36 + pcm.length);
  });
}
