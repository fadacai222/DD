import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

final class CallEndSound {
  const CallEndSound._();

  static Uint8List? _cached;

  static Future<void> play() async {
    final player = AudioPlayer();
    try {
      await player.play(BytesSource(_cached ??= _buildTone()), volume: 0.32);
      await Future<void>.delayed(const Duration(milliseconds: 520));
    } catch (_) {
      // Audio cues are best-effort and must never block call teardown.
    } finally {
      await player.dispose();
    }
  }

  static Uint8List _buildTone() {
    const sampleRate = 22050;
    const durationMs = 320;
    final sampleCount = sampleRate * durationMs ~/ 1000;
    final pcmBytes = sampleCount * 2;
    final data = ByteData(44 + pcmBytes);

    void ascii(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        data.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    data.setUint32(4, 36 + pcmBytes, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, sampleRate, Endian.little);
    data.setUint32(28, sampleRate * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    data.setUint32(40, pcmBytes, Endian.little);

    for (var i = 0; i < sampleCount; i++) {
      final t = i / sampleRate;
      final progress = i / sampleCount;
      final frequency = progress < 0.48 ? 620.0 : 430.0;
      final envelope = math.sin(math.pi * progress).clamp(0.0, 1.0);
      final sample = (math.sin(2 * math.pi * frequency * t) * envelope * 10500)
          .round();
      data.setInt16(44 + i * 2, sample, Endian.little);
    }
    return data.buffer.asUint8List();
  }
}
