import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';

Future<Source> createAppSoundSource(Uint8List bytes) async {
  if (!Platform.isWindows) return BytesSource(bytes);

  final digest = sha256.convert(bytes).toString();
  final directory = Directory(
    '${Directory.systemTemp.path}${Platform.pathSeparator}dd_app_sounds',
  );
  if (!await directory.exists()) await directory.create(recursive: true);

  final file = File('${directory.path}${Platform.pathSeparator}$digest.wav');
  if (!await file.exists() || await file.length() != bytes.length) {
    final temp = File('${file.path}.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    if (await file.exists()) await file.delete();
    await temp.rename(file.path);
  }
  return DeviceFileSource(file.path, mimeType: 'audio/wav');
}
