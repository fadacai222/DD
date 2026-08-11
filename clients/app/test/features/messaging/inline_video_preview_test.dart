import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/messaging/presentation/widgets/inline_video_preview.dart';

void main() {
  testWidgets('inline video stays poster-only until user starts playback', (
    tester,
  ) async {
    var sourceCalls = 0;
    var fullCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 240,
            height: 180,
            child: InlineVideoPreview(
              playbackId: 'video-1',
              posterBytes: _png,
              declaredDuration: const Duration(seconds: 27),
              sourceResolver: () async {
                sourceCalls++;
                return Uri.parse('https://example.invalid/video.mp4');
              },
              onOpenFull: () => fullCalls++,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(sourceCalls, 0);
    expect(find.text('0:27'), findsOneWidget);
    expect(
      find.byKey(const Key('inline-video-toggle-video-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('inline-video-progress-video-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('inline-video-mute-video-1')),
      findsOneWidget,
    );
    expect(fullCalls, 0);
  });
}

final Uint8List _png = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x04, 0x00, 0x00, 0x00, 0xB5, 0x1C, 0x0C,
  0x02, 0x00, 0x00, 0x00, 0x0B, 0x49, 0x44, 0x41,
  0x54, 0x78, 0xDA, 0x63, 0x64, 0xF8, 0x0F, 0x00,
  0x01, 0x05, 0x01, 0x01, 0x27, 0x18, 0xE3, 0x66,
  0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
  0xAE, 0x42, 0x60, 0x82,
]);
