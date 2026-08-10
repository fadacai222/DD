import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:image/image.dart' as img;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

final class VideoMediaMetadata {
  const VideoMediaMetadata({
    required this.width,
    required this.height,
    required this.durationMs,
    required this.posterJpeg,
  });

  final int width;
  final int height;
  final int durationMs;
  final Uint8List posterJpeg;
}

final class VideoMediaProbe {
  const VideoMediaProbe();

  Future<VideoMediaMetadata> probe(Uri url) => _probeSource(url.toString());

  Future<VideoMediaMetadata> probeFile(XFile file) async {
    final path = file.path.trim();
    if (path.isEmpty) {
      throw const FormatException('无法读取所选视频的本地路径。');
    }
    return _probeSource(path);
  }

  Future<VideoMediaMetadata> _probeSource(String source) async {
    Player? player;
    try {
      player = Player();
      final videoController = VideoController(player);
      // Subscribe before open. Very short clips can publish their duration and
      // geometry, finish playback, then clear parts of Player.state before a
      // polling loop observes a moment where every field is non-zero at once.
      // Retaining the first valid stream values removes that race, while the
      // state/track polling below remains a fallback for backends that do not
      // publish every stream consistently.
      Duration? observedDuration;
      unawaited(
        player.stream.duration
            .firstWhere((value) => value > Duration.zero)
            .then<void>((value) => observedDuration = value)
            .catchError((_) {}),
      );
      await player.open(Media(source), play: true);
      final duration = await _waitForDuration(
        player,
        observed: () => observedDuration,
      );
      // Native media_kit can parse duration without ever allocating a video
      // output for a bare Player. Player.screenshot() then returns no frame even
      // inside a real Release app. VideoController registers the native output
      // texture; waiting for the first rendered frame makes poster extraction
      // independent from arbitrary seek/sleep timing.
      await videoController.waitUntilFirstFrameRendered.timeout(
        const Duration(seconds: 6),
      );
      final screenshot = await _capturePoster(player, duration);
      await player.pause();
      final poster = _normalizePoster(screenshot);
      return VideoMediaMetadata(
        // The decoded poster is the most reliable display geometry. Some
        // libmpv backends expose duration while width/height remain null until
        // a video surface renders its first frame; gating the entire send flow
        // on those metadata fields was the original false failure.
        width: poster.$2,
        height: poster.$3,
        durationMs: duration.inMilliseconds.clamp(1, 24 * 60 * 60 * 1000),
        posterJpeg: poster.$1,
      );
    } on TimeoutException {
      throw const FormatException('读取视频信息超时，请确认文件可以正常播放。');
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('视频解码器无法读取该文件，请确认客户端已完整更新后重试。');
    } finally {
      if (player != null) {
        try {
          await player.dispose();
        } catch (_) {
          // Disposal must not hide the actionable probe failure.
        }
      }
    }
  }

  Future<Uint8List> _capturePoster(Player player, Duration duration) async {
    final durationMs = duration.inMilliseconds;
    final candidates =
        <int>{
              (durationMs * 0.12).round(),
              (durationMs * 0.35).round(),
              (durationMs * 0.62).round(),
            }
            .map(
              (value) => value.clamp(0, (durationMs - 1).clamp(0, durationMs)),
            )
            .toList(growable: false);

    for (final targetMs in candidates) {
      final target = Duration(milliseconds: targetMs);
      if (target > Duration.zero) await player.seek(target);
      await _waitForDecodedPosition(player, target);

      // Some codecs expose metadata before the first renderable frame, while
      // some hardware decoders need another render tick after a seek. Retry at
      // multiple timestamps and in both formats instead of betting the entire
      // send flow on one fixed 160 ms sleep + one screenshot call.
      for (var attempt = 0; attempt < 2; attempt++) {
        for (final format in const <String>['image/jpeg', 'image/png']) {
          try {
            final screenshot = await player
                .screenshot(format: format)
                .timeout(const Duration(seconds: 3));
            if (screenshot != null && screenshot.isNotEmpty) return screenshot;
          } on TimeoutException {
            // Try another format/frame before declaring the video unusable.
          } catch (_) {
            // A decoder may reject one screenshot format while supporting the
            // other. The outer send flow still gets a clean FormatException if
            // every attempt fails.
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 45));
      }
    }
    throw const FormatException('视频可以读取，但解码器没有输出可用缩略图画面。');
  }

  Future<void> _waitForDecodedPosition(Player player, Duration target) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    final tolerance = const Duration(milliseconds: 140);
    while (DateTime.now().isBefore(deadline)) {
      final state = player.state;
      final positionReady =
          target <= tolerance || state.position + tolerance >= target;
      if (positionReady && !state.buffering) return;
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }

  Future<Duration> _waitForDuration(
    Player player, {
    required Duration? Function() observed,
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      final stateDuration = player.state.duration;
      if (stateDuration > Duration.zero) return stateDuration;
      final streamDuration = observed();
      if (streamDuration != null && streamDuration > Duration.zero) {
        return streamDuration;
      }
      await Future<void>.delayed(const Duration(milliseconds: 35));
    }
    throw TimeoutException('video duration timeout');
  }

  (Uint8List, int, int) _normalizePoster(Uint8List screenshot) {
    final decoded = img.decodeImage(screenshot);
    if (decoded == null) throw const FormatException('无法解析视频缩略图。');
    final sourceWidth = decoded.width;
    final sourceHeight = decoded.height;
    var image = decoded;
    final longEdge = image.width > image.height ? image.width : image.height;
    if (longEdge > 720) {
      final scale = 720 / longEdge;
      image = img.copyResize(
        image,
        width: (image.width * scale).round().clamp(1, 720),
        height: (image.height * scale).round().clamp(1, 720),
        interpolation: img.Interpolation.average,
      );
    }
    return (
      Uint8List.fromList(img.encodeJpg(image, quality: 82)),
      sourceWidth,
      sourceHeight,
    );
  }
}
