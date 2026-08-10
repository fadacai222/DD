import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/messaging/data/voice_playback_source.dart';

void main() {
  test(
    'Windows materializes cached voice bytes as a device file source',
    () async {
      final source = await createVoicePlaybackSource(
        bytes: Uint8List.fromList(<int>[0x41, 0x41, 0x43, 0x00]),
        namespace: 'user-a',
        mediaId: 'media-a',
        mimeType: 'audio/aac',
      );

      if (Platform.isWindows) {
        expect(source, isA<DeviceFileSource>());
        final path = (source as DeviceFileSource).path;
        expect(path.toLowerCase().endsWith('.aac'), isTrue);
        expect(await File(path).readAsBytes(), <int>[0x41, 0x41, 0x43, 0x00]);
      } else {
        expect(source, isA<BytesSource>());
      }
    },
  );
}
