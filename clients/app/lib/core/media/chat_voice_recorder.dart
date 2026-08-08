import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

const int maxChatVoiceDurationMs = 10 * 60 * 1000;
const int minChatVoiceDurationMs = 250;

final class RecordedChatVoice {
  const RecordedChatVoice({
    required this.bytes,
    required this.durationMs,
    required this.mimeType,
    required this.fileExtension,
  });

  final Uint8List bytes;
  final int durationMs;
  final String mimeType;
  final String fileExtension;
}

final class ChatVoiceRecorder {
  ChatVoiceRecorder({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;
  final StreamController<double> _amplitudes = StreamController<double>.broadcast();
  BytesBuilder? _encoded;
  StreamSubscription<Uint8List>? _subscription;
  StreamSubscription<Amplitude>? _amplitudeSubscription;
  Completer<void>? _streamDone;
  DateTime? _startedAt;
  AudioEncoder _encoder = AudioEncoder.aacLc;
  int _sampleRate = 48000;
  int _channels = 1;
  bool _recording = false;

  bool get isRecording => _recording;
  Stream<double> get amplitudes => _amplitudes.stream;

  Future<void> start() async {
    if (_recording) return;
    if (!await _recorder.hasPermission()) {
      throw const FormatException('没有麦克风权限，无法录制语音。');
    }

    // AAC-LC streaming is supported by record on Android/iOS/Windows/macOS and
    // gives dramatically smaller files than raw PCM while retaining excellent
    // speech quality. Opus would be preferable for voice-only compression, but
    // this record backend does not provide Opus streaming on Windows; choosing
    // AAC here keeps one interoperable format across DD desktop + Android.
    _encoder = await _recorder.isEncoderSupported(AudioEncoder.aacLc)
        ? AudioEncoder.aacLc
        : AudioEncoder.pcm16bits;
    _sampleRate = _encoder == AudioEncoder.aacLc ? 48000 : 32000;
    _channels = 1;
    _encoded = BytesBuilder(copy: false);
    _streamDone = Completer<void>();
    await _recorder.setOnConfigChanged((config) {
      if (config.sampleRate > 0) _sampleRate = config.sampleRate;
      if (config.numChannels > 0) _channels = config.numChannels;
    });

    final stream = await _recorder.startStream(
      RecordConfig(
        encoder: _encoder,
        bitRate: 96000,
        sampleRate: _sampleRate,
        numChannels: 1,
        autoGain: true,
        echoCancel: true,
        noiseSuppress: true,
        streamBufferSize: 4096,
      ),
    );
    _subscription = stream.listen(
      (chunk) => _encoded?.add(chunk),
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
    _amplitudeSubscription = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 80))
        .listen((amplitude) {
          if (_amplitudes.isClosed) return;
          final normalized = ((amplitude.current + 60) / 60).clamp(0.0, 1.0);
          _amplitudes.add(normalized);
        });
    _startedAt = DateTime.now();
    _recording = true;
  }

  Future<RecordedChatVoice> stop() async {
    if (!_recording || _startedAt == null || _encoded == null) {
      throw const FormatException('当前没有正在录制的语音。');
    }
    final startedAt = _startedAt!;
    await _recorder.stop();
    await _awaitStreamClosed();
    final durationMs = DateTime.now().difference(startedAt).inMilliseconds.clamp(
      0,
      maxChatVoiceDurationMs,
    );
    final encoded = _encoded!.takeBytes();
    final encoder = _encoder;
    final sampleRate = _sampleRate;
    final channels = _channels;
    await _stopAmplitude();
    _resetSession();
    if (durationMs < minChatVoiceDurationMs || encoded.isEmpty) {
      throw const FormatException('语音时间太短。');
    }
    if (encoder == AudioEncoder.aacLc) {
      return RecordedChatVoice(
        bytes: encoded,
        durationMs: durationMs,
        mimeType: 'audio/aac',
        fileExtension: 'aac',
      );
    }
    return RecordedChatVoice(
      bytes: wrapPcm16AsWav(
        encoded,
        sampleRate: sampleRate,
        channels: channels,
      ),
      durationMs: durationMs,
      mimeType: 'audio/wav',
      fileExtension: 'wav',
    );
  }

  Future<void> cancel() async {
    if (_recording) {
      await _recorder.cancel();
      await _awaitStreamClosed();
    }
    await _stopAmplitude();
    _resetSession();
  }

  Future<void> _stopAmplitude() async {
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
    if (!_amplitudes.isClosed) _amplitudes.add(0);
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
    _encoded = null;
    _subscription = null;
    _streamDone = null;
  }

  Future<void> dispose() async {
    try {
      await cancel();
    } finally {
      await _amplitudes.close();
      await _recorder.dispose();
    }
  }
}

Uint8List wrapPcm16AsWav(
  Uint8List pcm, {
  required int sampleRate,
  required int channels,
}) {
  final safeRate = sampleRate > 0 ? sampleRate : 32000;
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
