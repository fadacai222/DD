import 'dart:typed_data';

final class VoiceMediaFormat {
  const VoiceMediaFormat({required this.mimeType, required this.extension});

  final String mimeType;
  final String extension;
}

VoiceMediaFormat detectVoiceMediaFormat(
  Uint8List bytes, {
  String? declaredMimeType,
}) {
  if (_ascii(bytes, 0, 'RIFF') && _ascii(bytes, 8, 'WAVE')) {
    return const VoiceMediaFormat(mimeType: 'audio/wav', extension: 'wav');
  }
  if (_ascii(bytes, 0, 'OggS')) {
    return const VoiceMediaFormat(mimeType: 'audio/ogg', extension: 'ogg');
  }
  if (_ascii(bytes, 0, 'ID3')) {
    return const VoiceMediaFormat(mimeType: 'audio/mpeg', extension: 'mp3');
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xF6) == 0xF0) {
    return const VoiceMediaFormat(mimeType: 'audio/aac', extension: 'aac');
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) {
    return const VoiceMediaFormat(mimeType: 'audio/mpeg', extension: 'mp3');
  }
  if (_ascii(bytes, 4, 'ftyp')) {
    return const VoiceMediaFormat(mimeType: 'audio/mp4', extension: 'm4a');
  }

  return switch ((declaredMimeType ?? '').trim().toLowerCase()) {
    'audio/aac' || 'audio/aacp' => const VoiceMediaFormat(
      mimeType: 'audio/aac',
      extension: 'aac',
    ),
    'audio/wav' || 'audio/x-wav' || 'audio/wave' => const VoiceMediaFormat(
      mimeType: 'audio/wav',
      extension: 'wav',
    ),
    'audio/mpeg' || 'audio/mp3' => const VoiceMediaFormat(
      mimeType: 'audio/mpeg',
      extension: 'mp3',
    ),
    'audio/mp4' || 'audio/m4a' || 'audio/x-m4a' => const VoiceMediaFormat(
      mimeType: 'audio/mp4',
      extension: 'm4a',
    ),
    'audio/ogg' || 'application/ogg' => const VoiceMediaFormat(
      mimeType: 'audio/ogg',
      extension: 'ogg',
    ),
    _ => const VoiceMediaFormat(
      mimeType: 'application/octet-stream',
      extension: 'audio',
    ),
  };
}

bool _ascii(Uint8List bytes, int offset, String value) {
  if (offset < 0 || bytes.length < offset + value.length) return false;
  for (var index = 0; index < value.length; index++) {
    if (bytes[offset + index] != value.codeUnitAt(index)) return false;
  }
  return true;
}
