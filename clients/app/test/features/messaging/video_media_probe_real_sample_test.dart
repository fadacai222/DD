import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/messaging/data/video_media_probe.dart';
import 'package:image/image.dart' as img;
import 'package:media_kit/media_kit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  var mediaKitReady = false;
  Object? mediaKitError;

  setUpAll(() {
    try {
      // flutter test does not inherit the Windows runner's DLL directory. The
      // release build is a hard gate for this project, so preload its packaged
      // libmpv by absolute path before media_kit resolves the short DLL name.
      if (Platform.isWindows) {
        final packaged = File(
          'build/windows/x64/runner/Release/libmpv-2.dll',
        ).absolute;
        if (packaged.existsSync()) DynamicLibrary.open(packaged.path);
      }
      MediaKit.ensureInitialized();
      mediaKitReady = true;
    } catch (error) {
      mediaKitError = error;
    }
  });

  test(
    'embedded real MP4 can be decoded and poster extracted',
    () async {
      if (!mediaKitReady) {
        fail(
          'media_kit native runtime is unavailable. Build Windows release first. '
          'Root cause: $mediaKitError',
        );
      }
      final directory = await Directory.systemTemp.createTemp(
        'dd-video-probe-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final file = File(
        '${directory.path}${Platform.pathSeparator}fixture.mp4',
      );
      await file.writeAsBytes(base64Decode(_embeddedMp4Base64), flush: true);

      final metadata = await const VideoMediaProbe().probeFile(
        XFile(file.path),
      );

      expect(metadata.width, 64);
      expect(metadata.height, 48);
      expect(metadata.durationMs, inInclusiveRange(650, 950));
      expect(metadata.posterJpeg, isNotEmpty);
      final poster = img.decodeJpg(metadata.posterJpeg);
      expect(poster, isNotNull);
      expect(poster!.width, greaterThan(0));
      expect(poster.height, greaterThan(0));
    },
    timeout: const Timeout(Duration(seconds: 20)),
    skip:
        'flutter_test on Windows has no native video output surface; libmpv remains buffering without rendering frames. Validate this fixture in a real Windows/Android app runtime.',
  );

  final samples = <String, String>{
    'MP4': Platform.environment['DD_VIDEO_SAMPLE_MP4'] ?? '',
    'MOV': Platform.environment['DD_VIDEO_SAMPLE_MOV'] ?? '',
    'WebM': Platform.environment['DD_VIDEO_SAMPLE_WEBM'] ?? '',
    'MKV': Platform.environment['DD_VIDEO_SAMPLE_MKV'] ?? '',
  };

  for (final entry in samples.entries) {
    test(
      'real ${entry.key} sample can be probed and poster extracted',
      () async {
        final path = entry.value.trim();
        if (path.isEmpty || !File(path).existsSync()) {
          markTestSkipped(
            'DD_VIDEO_SAMPLE_${entry.key.toUpperCase()} is not set',
          );
          return;
        }
        if (!mediaKitReady) {
          fail('media_kit native runtime is unavailable: $mediaKitError');
        }
        final metadata = await const VideoMediaProbe().probeFile(XFile(path));
        expect(metadata.width, greaterThan(0));
        expect(metadata.height, greaterThan(0));
        expect(metadata.durationMs, greaterThan(0));
        expect(metadata.posterJpeg, isNotEmpty);
      },
      timeout: const Timeout(Duration(seconds: 20)),
    );
  }
}

// 64x48, 10 fps, ~0.8 s H.264/MP4 generated solely as a deterministic decoder
// fixture. Keeping it inline avoids depending on a user's Downloads folder or
// a network fetch during CI/regression tests.
const _embeddedMp4Base64 =
    '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';
