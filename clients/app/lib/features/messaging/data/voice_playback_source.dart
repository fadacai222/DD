import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart' show Source;

import 'voice_playback_source_stub.dart'
    if (dart.library.io) 'voice_playback_source_io.dart' as legacy_source;

sealed class VoicePlaybackSource {
  const VoicePlaybackSource({this.mimeType});
  final String? mimeType;
}

final class LocalVoicePlaybackSource extends VoicePlaybackSource {
  const LocalVoicePlaybackSource(this.path, {super.mimeType});
  final String path;
}

final class RemoteVoicePlaybackSource extends VoicePlaybackSource {
  const RemoteVoicePlaybackSource(this.url, {super.mimeType});
  final Uri url;
}

Future<Source> createVoicePlaybackSource({
  required Uint8List bytes,
  required String namespace,
  required String mediaId,
  String? mimeType,
}) => legacy_source.createVoicePlaybackSource(
  bytes: bytes,
  namespace: namespace,
  mediaId: mediaId,
  mimeType: mimeType,
);

final class BytesVoicePlaybackSource extends VoicePlaybackSource {
  const BytesVoicePlaybackSource(
    this.bytes, {
    required this.namespace,
    required this.mediaId,
    super.mimeType,
  });

  final Uint8List bytes;
  final String namespace;
  final String mediaId;
}
