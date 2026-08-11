import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android chat video preview is visible-autoplay, muted and looping', () {
    final previewSource = File(
      'lib/features/messaging/presentation/widgets/inline_video_preview.dart',
    ).readAsStringSync();

    expect(
      previewSource,
      contains('defaultTargetPlatform == TargetPlatform.android'),
    );
    expect(previewSource, contains('widget.autoPlayWhenVisible ??'));
    expect(previewSource, contains('widget.openFullOnTap ??'));
    expect(previewSource, contains('startMuted: true, looping: true'));
    expect(
      previewSource,
      contains('setPlaylistMode(PlaylistMode.single)'),
    );
  });

  test('Android fullscreen keeps DD controls and supports back-to-exit', () {
    final source = File(
      'lib/features/messaging/presentation/video_viewer_page.dart',
    ).readAsStringSync();

    expect(source, contains('SystemUiMode.immersiveSticky'));
    expect(source, contains('SystemUiMode.edgeToEdge'));
    expect(source, contains('canPop: !_fullscreen'));
    expect(source, contains("Key('video-viewer-close')"));
    expect(
      source,
      contains('video-viewer-fullscreen-exit-persistent'),
    );
    expect(source, contains('if (_android) {'));
  });
}
