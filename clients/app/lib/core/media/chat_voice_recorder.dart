import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

const int maxChatVoiceDurationMs = 10 * 60 * 1000;
const int minChatVoiceDurationMs = 250;

final class RecordedChatVoice {
  const RecordedChatVoice({required this.bytes, required this.durationMs});

  final Uint8List bytes;
  final int durationMs;
}

final class ChatVoiceRecorder {
  ChatVoiceRecorder({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;
  BytesBuilder? _pcm;
  StreamSubscription<Uint8List>? _subscription;
  Completer<void>? _streamDone;
  DateTime? _startedAt;
  int _sampleRate = 16000;
  int _channels = 1;
  bool _recording = false;

  bool get isRecording => _recording;

  Future<void> start() async {
    if (_recording) return;
    if (!await _recorder.hasPermission()) {
      throw const FormatException('没有麦克风权限，无法录制语音。');
    }

    _sampleRate = 16000;
    _channels = 1;
    _pcm = BytesBuilder(copy: false);
    _streamDone = Completer<void>();
    await _recorder.setOnConfigChanged((config) {
      if (config.sampleRate > 0) _sampleRate = config.sampleRate;
      if (config.numChannels > 0) _channels = config.numChannels;
    });

    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        autoGain: true,
        echoCancel: true,
        noiseSuppress: true,
        streamBufferSize: 4096,
      ),
    );
    _subscription = stream.listen(
      (chunk) => _pcm?.add(chunk),
      onError: (Object error, StackTrace stackTrace) {
        final done = _streamDone;
        if (done != null && !done.isCompleted) {
          done.completeError(error, stackTrace);
        }
      },
      onDone: () {
        final done = _streamDone;
        if (done != null && !done.isCompleted) done.complete();
      },
      cancelOnError: false,
    );
    _startedAt = DateTime.now();
    _recording = true;
  }

  Future<RecordedChatVoice> stop() async {
    if (!_recording || _startedAt == null || _pcm == null) {
      throw const FormatException('当前没有正在录制的语音。');
    }
    final startedAt = _startedAt!;
    await _recorder.stop();
    await _awaitStreamClosed();
    final durationMs = DateTime.now().difference(startedAt).inMilliseconds.clamp(
      0,
      maxChatVoiceDurationMs,
    );
    final pcm = _pcm!.takeBytes();
    _resetSession();
    if (durationMs < minChatVoiceDurationMs || pcm.isEmpty) {
      throw const FormatException('语音时间太短。');
    }
    return RecordedChatVoice(
      bytes: wrapPcm16AsWav(
        pcm,
        sampleRate: _sampleRate,
        channels: _channels,
      ),
      durationMs: durationMs,
    );
  }

  Future<void> cancel() async {
    if (_recording) {
      await _recorder.cancel();
      await _awaitStreamClosed();
    }
    _resetSession();
  }

  Future<void> _awaitStreamClosed() async {
    final done = _streamDone;
    if (done == null) return;
    try {
      await done.future.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      await _subscription?.cancel();
    }
  }

  void _resetSession() {
    _recording = false;
    _startedAt = null;
    _pcm = null;
    _subscription = null;
    _streamDone = null;
  }

  Future<void> dispose() async {
    try {
      await cancel();
    } finally {
      await _recorder.dispose();
    }
  }
}

Uint8List wrapPcm16AsWav(
  Uint8List pcm, {
  required int sampleRate,
  required int channels,
}) {
  final safeRate = sampleRate > 0 ? sampleRate : 16000;
  final safeChannels = channels.clamp(1, 2);
  final header = ByteData(44);
  void ascii(int offset, String value) {
    for (var index = 0; index < value.length; index++) {
      header.setUint8(offset + index, value.codeUnitAt(index));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + pcm.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, safeChannels, Endian.little);
  header.setUint32(24, safeRate, Endian.little);
  header.setUint32(28, safeRate * safeChannels * 2, Endian.little);
  header.setUint16(32, safeChannels * 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, pcm.length, Endian.little);

  final output = Uint8List(44 + pcm.length);
  output.setRange(0, 44, header.buffer.asUint8List());
  output.setRange(44, output.length, pcm);
  return output;
}
