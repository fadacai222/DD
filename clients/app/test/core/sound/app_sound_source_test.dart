import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/sound/app_sound_service.dart';
import 'package:im_client/core/sound/app_sound_source.dart';

void main() {
  test('Windows materializes DD WAV cues before playback', () async {
    final bytes = Uint8List.fromList(AppToneFactory.messageNotification);
    final source = await createAppSoundSource(bytes);

    if (Platform.isWindows) {
      expect(source, isA<DeviceFileSource>());
      final path = (source as DeviceFileSource).path;
      expect(path.toLowerCase().endsWith('.wav'), isTrue);
      expect(await File(path).readAsBytes(), bytes);
    } else {
      expect(source, isA<BytesSource>());
    }
  });
}
