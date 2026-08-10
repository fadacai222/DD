import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

import 'voice_media_format.dart';

Future<Source> createVoicePlaybackSource({
  required Uint8List bytes,
  required String namespace,
  required String mediaId,
  String? mimeType,
}) async {
  final format = detectVoiceMediaFormat(bytes, declaredMimeType: mimeType);
  return BytesSource(bytes, mimeType: format.mimeType);
}
