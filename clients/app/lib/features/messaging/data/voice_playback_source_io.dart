import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';

import 'voice_media_format.dart';

Future<Source> createVoicePlaybackSource({
  required Uint8List bytes,
  required String namespace,
  required String mediaId,
  String? mimeType,
}) async {
  final format = detectVoiceMediaFormat(bytes, declaredMimeType: mimeType);
  if (!Platform.isWindows) {
    return BytesSource(bytes, mimeType: format.mimeType);
  }

  final extension = format.extension;
  final key = sha256.convert('$namespace:$mediaId'.codeUnits).toString();
  final directory = Directory(
    '${Directory.systemTemp.path}${Platform.pathSeparator}dd_voice_playback',
  );
  if (!await directory.exists()) await directory.create(recursive: true);
  final file = File(
    '${directory.path}${Platform.pathSeparator}$key.$extension',
  );
  if (!await file.exists() || await file.length() != bytes.length) {
    final temp = File('${file.path}.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    if (await file.exists()) await file.delete();
    await temp.rename(file.path);
  }
  return DeviceFileSource(file.path, mimeType: format.mimeType);
}
