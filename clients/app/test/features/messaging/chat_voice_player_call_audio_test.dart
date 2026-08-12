import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/messaging/data/chat_voice_player.dart';

void main() {
  test('voice playback refuses to start while a call owns the audio session', () async {
    final player = ChatVoicePlayer(callActive: () => true);
    addTearDown(player.dispose);

    await expectLater(
      player.play(
        bytes: Uint8List.fromList([1, 2, 3]),
        namespace: 'test',
        mediaId: 'voice-1',
        mimeType: 'audio/aac',
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('通话'),
        ),
      ),
    );
  });

  test('voice resume also refuses while a call becomes active', () async {
    var callActive = false;
    final player = ChatVoicePlayer(callActive: () => callActive);
    addTearDown(player.dispose);

    callActive = true;
    await expectLater(player.resume(), throwsStateError);
  });
}
